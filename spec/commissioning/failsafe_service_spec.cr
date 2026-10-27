require "../spec_helper"
require "../../src/matter/commissioning/failsafe_service"

module Matter::Commissioning
  # The service on its own: no cluster, no wire, just the state machine.
  describe FailsafeService do
    it "holds the protocol lock through a host arm after its prehook" do
      service = FailsafeService.new(RecordingRollbackTarget.new)
      protocol_lock = Mutex.new(:reentrant)
      service.protocol_lock = protocol_lock
      entered = Channel(Nil).new(1)
      resume = Channel(Nil).new(1)
      finished = Channel(Nil).new(1)
      attempting = Channel(Nil).new(1)
      acquired = Channel(Nil).new(1)
      service.on_before_arm_timer = ->(_expiry : UInt16) { entered.send(nil); resume.receive; nil }

      spawn do
        service.arm_timer(60_u16)
        finished.send(nil)
      end
      entered.receive
      spawn do
        attempting.send(nil)
        protocol_lock.synchronize { acquired.send(nil) }
      end
      attempting.receive
      select
      when acquired.receive
        fail "the lease acquired the protocol lock during an unfinished host arm"
      when timeout(50.milliseconds)
      end
      resume.send(nil)
      finished.receive
      select
      when acquired.receive
      when timeout(2.seconds)
        fail "the lease could not acquire the protocol lock after the host arm"
      end
      service.disarm
    end

    describe "#arm" do
      it "rejects an arm before creating a failsafe context" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.on_before_arm = ->(_expiry : UInt16, _fabric : UInt8?, _pase : Bool) {
          raise Matter::ClusterError.new("Participant recovery lease", Matter::InteractionModel::StatusCode::Busy)
        }

        expect_raises(Matter::ClusterError) { service.arm(60_u16, 0_u64, 1_u8, pase_session: false) }
        service.context.should be_nil
        service.armed?.should be_false
      end

      it "rejects device-side timer arming before creating a context" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.on_before_arm_timer = ->(_expiry : UInt16) {
          raise Matter::ClusterError.new("Participant recovery lease", Matter::InteractionModel::StatusCode::Busy)
        }

        expect_raises(Matter::ClusterError) { service.arm_timer(60_u16) }
        service.context.should be_nil
      end

      it "arms a failsafe for a PASE commissioner" do
        service = FailsafeService.new(RecordingRollbackTarget.new)

        outcome = service.arm(60_u16, 100_u64, nil, pase_session: true)

        outcome.ok?.should be_true
        service.armed?.should be_true
        service.admin_fabric_index.should be_nil
        service.disarm
      end

      it "reports the breadcrumb the commissioner moved to" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        breadcrumbs = [] of UInt64
        service.on_breadcrumb_changed = ->(value : UInt64) { breadcrumbs << value }

        service.arm(60_u16, 100_u64, 1_u8, pase_session: false)
        service.complete(1_u8, case_session: true)

        breadcrumbs.should eq([100_u64, 0_u64])
      end

      it "rejects an expiry beyond the cumulative maximum" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.max_cumulative_seconds = 120_u16

        outcome = service.arm(300_u16, 0_u64, 1_u8, pase_session: false)

        outcome.error.should eq(ErrorCode::ValueOutsideRange)
        service.armed?.should be_false
      end

      it "resets per-failsafe state elsewhere when a context is created" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        armed = 0
        service.on_failsafe_armed = -> { armed += 1; nil }

        service.arm(60_u16, 0_u64, 1_u8, pase_session: false)
        service.arm(60_u16, 1_u64, 1_u8, pase_session: false)

        # Only a new context resets, a re-arm continues the same session
        armed.should eq(1)
        service.disarm
      end

      it "blocks a second administrator" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.arm(60_u16, 0_u64, 1_u8, pase_session: false)

        outcome = service.arm(60_u16, 0_u64, 2_u8, pase_session: false)

        outcome.error.should eq(ErrorCode::BusyWithOtherAdmin)
        service.disarm
      end

      it "keeps an armed CASE administrator's fail-safe when a PASE commissioner has an open window" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.arm(60_u16, 4_u64, 1_u8, pase_session: false)
        service.commissioning_window_open = true

        outcome = service.arm(60_u16, 5_u64, nil, pase_session: true)

        outcome.error.should eq(ErrorCode::BusyWithOtherAdmin)
        service.armed?.should be_true
        service.admin_fabric_index.should eq(1_u8)
        service.context.try(&.breadcrumb).should eq(4_u64)
        service.disarm
      end

      it "keeps a PASE commissioner's fail-safe from an unrelated CASE fabric" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.arm(60_u16, 4_u64, nil, pase_session: true)

        outcome = service.arm(60_u16, 7_u64, 1_u8, pase_session: false)

        outcome.error.should eq(ErrorCode::BusyWithOtherAdmin)
        service.context.try(&.associated_fabric_index).should be_nil
        service.context.try(&.breadcrumb).should eq(4_u64)
        service.admin_fabric_index.should be_nil
        service.arm(0_u16, 8_u64, 1_u8, pase_session: false).error.should eq(ErrorCode::BusyWithOtherAdmin)
        service.armed?.should be_true
        service.context.try(&.breadcrumb).should eq(4_u64)

        service.record_added_fabric(3_u8)
        service.admin_fabric_index.should eq(3_u8)
        service.arm(60_u16, 9_u64, 3_u8, pase_session: false).ok?.should be_true
        service.context.try(&.breadcrumb).should eq(9_u64)
        service.disarm
      end

      it "reserves an open commissioning window for PASE while the fail-safe is unarmed" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.commissioning_window_open = true

        service.arm(60_u16, 7_u64, 1_u8, pase_session: false).error.should eq(ErrorCode::BusyWithOtherAdmin)
        service.armed?.should be_false
        service.context.should be_nil
      end

      it "accepts CommissioningComplete from the fabric AddNOC created" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.arm(60_u16, 0_u64, nil, pase_session: true)
        service.record_added_fabric(3_u8)

        service.complete(3_u8, case_session: true).ok?.should be_true
      end

      it "rolls back pending state on a zero expiry" do
        target = RecordingRollbackTarget.new
        service = FailsafeService.new(target)
        breadcrumbs = [] of UInt64
        service.arm(60_u16, 100_u64, 1_u8, pase_session: false)
        service.on_breadcrumb_changed = ->(value : UInt64) { breadcrumbs << value }

        outcome = service.arm(0_u16, 200_u64, 1_u8, pase_session: false)

        outcome.ok?.should be_true
        service.armed?.should be_false
        service.context.should be_nil
        breadcrumbs.should eq([0_u64])
        target.windows_closed.should eq(1)
      end
    end

    describe "#complete" do
      it "requires a CASE session" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.arm(60_u16, 0_u64, nil, pase_session: true)

        outcome = service.complete(nil, case_session: false)

        outcome.error.should eq(ErrorCode::InvalidAuthentication)
        service.disarm
      end

      it "requires an armed failsafe" do
        service = FailsafeService.new(RecordingRollbackTarget.new)

        outcome = service.complete(1_u8, case_session: true)

        outcome.error.should eq(ErrorCode::NoFailSafe)
      end

      it "requires the fabric that armed the failsafe" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.arm(60_u16, 0_u64, 1_u8, pase_session: false)

        outcome = service.complete(2_u8, case_session: true)

        outcome.error.should eq(ErrorCode::InvalidAuthentication)
        service.disarm
      end

      it "requires accepted terms and conditions when they are required" do
        service = FailsafeService.new(RecordingRollbackTarget.new)
        service.terms_conditions_required = true
        service.arm(60_u16, 0_u64, 1_u8, pase_session: false)

        outcome = service.complete(1_u8, case_session: true)
        outcome.error.should eq(ErrorCode::RequiredTCNotAccepted)

        service.terms_conditions_accepted = true
        service.complete(1_u8, case_session: true).ok?.should be_true
      end

      it "closes the commissioning window" do
        target = RecordingRollbackTarget.new
        service = FailsafeService.new(target)
        service.arm(60_u16, 0_u64, 1_u8, pase_session: false)

        service.complete(1_u8, case_session: true).ok?.should be_true

        service.armed?.should be_false
        service.context.should be_nil
        target.windows_closed.should eq(1)
      end
    end

    describe "rollback" do
      it "restores the snapshots through the target when the failsafe expires" do
        target = RecordingRollbackTarget.new
        service = FailsafeService.new(target)
        service.arm(1_u16, 100_u64, 1_u8, pase_session: false)
        service.commissioning_window_open = true
        service.record_regulatory_config(1_u8, "AU")

        service.expire

        service.armed?.should be_false
        service.context.should be_nil
        service.commissioning_window_open?.should be_false
        target.regulatory_config.should eq({1_u8, "AU"})
      end

      it "only snapshots the regulatory config while armed" do
        service = FailsafeService.new(RecordingRollbackTarget.new)

        service.record_regulatory_config(1_u8, "AU")

        service.context.should be_nil
      end
    end

    describe "#arm_timer" do
      it "arms without a commissioner" do
        service = FailsafeService.new(RecordingRollbackTarget.new)

        service.arm_timer(60_u16)

        service.armed?.should be_true
        service.expiry_time.should_not be_nil
        service.disarm
        service.armed?.should be_false
      end
    end
  end
end
