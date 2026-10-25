require "../spec_helper"

private alias Lock = Matter::Cluster::DoorLock

private class TestUnboltingActuator < Lock::UnboltingActuator
  getter calls = [] of Symbol
  property fail_step : Symbol? = nil
  property raise_step : Symbol? = nil

  def unbolt : Bool
    @calls << :unbolt
    raise "bolt jammed" if @raise_step == :unbolt
    @fail_step != :unbolt
  end

  def pull_latch : Bool
    @calls << :pull
    raise "latch jammed" if @raise_step == :pull
    @fail_step != :pull
  end

  def release_latch : Bool
    @calls << :release
    raise "latch stuck" if @raise_step == :release
    @fail_step != :release
  end
end

private def unbolting_lock(actuator : TestUnboltingActuator) : Lock
  build(Lock, feature_map: Lock::Feature::Unbolting,
    unbolting_actuator: actuator)
end

describe Lock do
  describe "Unbolting actuator" do
    it "does not advertise UBOLT by default or without a host actuator" do
      build(Lock).feature_map.unbolting?.should be_false
      expect_raises(ArgumentError) { build(Lock, feature_map: Lock::Feature::Unbolting) }
    end

    it "reaches and releases the latch before reporting the final unlock" do
      actuator = TestUnboltingActuator.new
      lock = unbolting_lock(actuator)
      states = [] of Lock::LockState?
      operations = [] of Lock::LockOperationType
      lock.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attribute : UInt32) {
        states << lock.lock_state if attribute == Lock::ATTR_LOCK_STATE
        nil
      }
      lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
        operations << Lock::Events::LockOperation.from_tlv(data).lock_operation_type if event == Lock::EVENT_LOCK_OPERATION
        nil
      }

      lock.unlock.success?.should be_true

      actuator.calls.should eq([:unbolt, :pull, :release])
      states.should eq([Lock::LockState::Unlocked, Lock::LockState::Unlatched, Lock::LockState::Unlocked])
      operations.should eq([Lock::LockOperationType::Unlatch, Lock::LockOperationType::Unlock])
    end

    it "uses the latch actuator for UnlockWithTimeout and applies its timeout" do
      actuator = TestUnboltingActuator.new
      lock = unbolting_lock(actuator)
      operations = [] of Lock::LockOperationType
      lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
        operations << Lock::Events::LockOperation.from_tlv(data).lock_operation_type if event == Lock::EVENT_LOCK_OPERATION
        nil
      }

      lock.unlock_with_timeout(1_u16).success?.should be_true
      actuator.calls.should eq([:unbolt, :pull, :release])
      operations.should eq([Lock::LockOperationType::Unlatch, Lock::LockOperationType::Unlock])
      lock.lock_state.should eq(Lock::LockState::Unlocked)

      sleep 1.2.seconds
      lock.lock_state.should eq(Lock::LockState::Locked)
    end

    it "reports only an Unlock error when the bolt cannot retract" do
      actuator = TestUnboltingActuator.new
      actuator.fail_step = :unbolt
      lock = unbolting_lock(actuator)
      operations = [] of Lock::LockOperationType
      errors = [] of Lock::LockOperationType
      lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
        operations << Lock::Events::LockOperation.from_tlv(data).lock_operation_type if event == Lock::EVENT_LOCK_OPERATION
        errors << Lock::Events::LockOperationError.from_tlv(data).lock_operation_type if event == Lock::EVENT_LOCK_OPERATION_ERROR
        nil
      }

      lock.unlock.success?.should be_false
      actuator.calls.should eq([:unbolt])
      lock.lock_state.should eq(Lock::LockState::Locked)
      operations.should be_empty
      errors.should eq([Lock::LockOperationType::Unlock])
    end

    [:pull, :release].each do |failed_step|
      it "reports Unlatch failure and an Unlock event when #{failed_step} fails" do
        actuator = TestUnboltingActuator.new
        actuator.fail_step = failed_step
        lock = unbolting_lock(actuator)
        operations = [] of Lock::LockOperationType
        errors = [] of Lock::LockOperationType
        lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
          operations << Lock::Events::LockOperation.from_tlv(data).lock_operation_type if event == Lock::EVENT_LOCK_OPERATION
          errors << Lock::Events::LockOperationError.from_tlv(data).lock_operation_type if event == Lock::EVENT_LOCK_OPERATION_ERROR
          nil
        }

        lock.unlock.success?.should be_false
        lock.lock_state.should eq(failed_step == :pull ? Lock::LockState::Unlocked : Lock::LockState::Unlatched)
        errors.should eq([Lock::LockOperationType::Unlatch])
        operations.should eq(failed_step == :pull ? [Lock::LockOperationType::Unlock] : [Lock::LockOperationType::Unlatch, Lock::LockOperationType::Unlock])
      end
    end

    it "unbolts without pulling the latch" do
      actuator = TestUnboltingActuator.new
      lock = unbolting_lock(actuator)

      lock.unbolt.success?.should be_true
      actuator.calls.should eq([:unbolt])
      lock.lock_state.should eq(Lock::LockState::Unlocked)
    end

    it "keeps Privacy and Locked state when manual bolt retraction raises" do
      actuator = TestUnboltingActuator.new
      actuator.raise_step = :unbolt
      lock = build(Lock, feature_map: Lock::Feature::Unbolting,
        unbolting_actuator: actuator,
        supported_operating_modes: 0xFFE2_u16,
        operating_mode: Lock::OperatingMode::Privacy)

      lock.unlock(source: Lock::OperationSource::Manual).success?.should be_false
      lock.operating_mode.should eq(Lock::OperatingMode::Privacy)
      lock.lock_state.should eq(Lock::LockState::Locked)
    end
  end
end
