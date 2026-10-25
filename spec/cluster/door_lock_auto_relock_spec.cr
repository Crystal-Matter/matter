require "../spec_helper"

private alias AutoLock = Matter::Cluster::DoorLock

describe AutoLock do
  it "reports an automatic LockOperation when a timeout relocks the door" do
    lock = build(AutoLock)
    operations = [] of AutoLock::Events::LockOperation
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
      operations << AutoLock::Events::LockOperation.from_tlv(data) if event == AutoLock::EVENT_LOCK_OPERATION
      nil
    }

    lock.unlock_with_timeout(1_u16).success?.should be_true
    sleep 1.2.seconds

    lock.lock_state.should eq(AutoLock::LockState::Locked)
    operations.map(&.lock_operation_type).should eq([AutoLock::LockOperationType::Unlock, AutoLock::LockOperationType::Lock])
    operations.last.operation_source.should eq(AutoLock::OperationSource::Auto)
    operations.last.fabric_index.should be_nil
    operations.last.source_node.should be_nil
  end

  it "cancels an earlier relock when a later unlock requests no timeout" do
    lock = build(AutoLock)

    lock.unlock_with_timeout(1_u16).success?.should be_true
    lock.unlock_with_timeout(0_u16).success?.should be_true
    sleep 1.2.seconds

    lock.lock_state.should eq(AutoLock::LockState::Unlocked)
  end
end
