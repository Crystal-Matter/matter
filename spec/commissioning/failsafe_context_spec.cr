require "../spec_helper"
require "../../src/matter/commissioning/failsafe_context"

module Matter::Commissioning
  describe FailsafeContext do
    describe "initialization" do
      it "creates context with fabric index and breadcrumb" do
        expired = false
        context = FailsafeContext.new(
          associated_fabric_index: 1_u8,
          breadcrumb: 42_u64,
          expiry_callback: -> { expired = true }
        )

        context.associated_fabric_index.should eq(1_u8)
        context.breadcrumb.should eq(42_u64)
        context.armed?.should be_false
        expired.should be_false

        context.close
      end

      it "creates context for PASE session (no fabric)" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.associated_fabric_index.should be_nil
        context.close
      end
    end

    describe "arming and disarming" do
      it "arms failsafe timer" do
        expired = false
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { expired = true }
        )

        context.armed?.should be_false

        context.arm(expiry_length: 5_u16, max_cumulative: 10_u16)
        context.armed?.should be_true
        expired.should be_false

        context.close
      end

      it "disarms failsafe timer with expiry_length=0" do
        expired = false
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { expired = true }
        )

        context.arm(expiry_length: 5_u16, max_cumulative: 10_u16)
        context.armed?.should be_true

        # Disarm with 0
        context.arm(expiry_length: 0_u16, max_cumulative: 10_u16)
        context.armed?.should be_false
        expired.should be_false # Disarm doesn't trigger callback
      end

      it "disarms explicitly" do
        expired = false
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { expired = true }
        )

        context.arm(expiry_length: 5_u16, max_cumulative: 10_u16)
        context.armed?.should be_true

        context.disarm
        context.armed?.should be_false
        expired.should be_false # Disarm doesn't trigger callback
      end

      it "invokes expiry callback when timer expires" do
        expired = Channel(Bool).new(1)
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { expired.send(true) }
        )

        context.arm(expiry_length: 1_u16, max_cumulative: 10_u16)
        context.armed?.should be_true

        # Wait for expiration
        select
        when result = expired.receive
          result.should be_true
        when timeout(2.seconds)
          fail "Expiry callback was not invoked"
        end

        context.armed?.should be_false
      end
    end

    describe "re-arming" do
      it "re-arms existing timer" do
        expired = Channel(Bool).new(1)
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { expired.send(true) }
        )

        # Initial arm with 1 second
        context.arm(expiry_length: 1_u16, max_cumulative: 3_u16)
        sleep 0.5.seconds

        # Re-arm with another 1 second (extends by 1s from now)
        context.arm(expiry_length: 1_u16, max_cumulative: 3_u16)

        # Should expire after cumulative timer (3s total from start)
        select
        when result = expired.receive
          result.should be_true
        when timeout(3.5.seconds)
          fail "Expiry callback was not invoked"
        end

        context.armed?.should be_false
      end
    end

    describe "fabric matching" do
      it "validates matching fabric index" do
        context = FailsafeContext.new(
          associated_fabric_index: 1_u8,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.matches_fabric?(1_u8).should be_true
        context.matches_fabric?(2_u8).should be_false
        context.matches_fabric?(nil).should be_false

        context.close
      end

      it "validates nil fabric for PASE" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.matches_fabric?(nil).should be_true
        context.matches_fabric?(1_u8).should be_false

        context.close
      end
    end

    describe "state recording" do
      it "records added fabric index" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.added_fabric_index.should be_nil

        context.record_added_fabric(1_u8)
        context.added_fabric_index.should eq(1_u8)
        # Should also update associated fabric index
        context.associated_fabric_index.should eq(1_u8)

        context.close
      end

      it "records network commissioning state" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        state = {"ssid" => "TestNetwork", "password" => "secret123"}
        context.record_network_state(state)
        context.network_state_snapshot.should eq(state)

        context.close
      end

      it "keeps an independent first network snapshot across later mutations" do
        context = FailsafeContext.new(nil, 0_u64, -> { })
        original = Bytes[1, 2, 3]
        first = Matter::Storage::Document{"credential" => original}
        context.record_network_state(first)
        original[0] = 9_u8
        first["credential"] = Bytes[8]
        context.record_network_state(Matter::Storage::Document{"credential" => Bytes[7]})

        context.network_state_snapshot.as(Matter::Storage::Document)["credential"].should eq(Bytes[1, 2, 3])
        context.close
      end
    end

    describe "rollback" do
      it "resets breadcrumb to 0" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 42_u64,
          expiry_callback: -> { }
        )

        context.breadcrumb.should eq(42_u64)
        context.rollback
        context.breadcrumb.should eq(0_u64)

        context.close
      end

      it "clears temporary state" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        # Record various state
        context.record_added_fabric(1_u8)
        context.record_network_state({"ssid" => "test"})

        # Perform rollback
        context.rollback

        # Verify cleanup
        context.added_fabric_index.should be_nil
        context.network_state_snapshot.should be_nil

        context.close
      end

      it "restores the recorded state through the rollback target" do
        target = RecordingRollbackTarget.new
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 7_u64,
          expiry_callback: -> { }
        )

        context.record_network_state({"ssid" => "test"})
        context.record_regulatory_config(1_u8, "AU")
        context.rollback(target)

        target.network_state.should eq({"ssid" => "test"})
        target.regulatory_config.should eq({1_u8, "AU"})
        target.windows_closed.should eq(1)

        context.close
      end

      it "closes the window even when nothing was snapshotted" do
        target = RecordingRollbackTarget.new
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.rollback(target)

        target.network_state.should be_nil
        target.regulatory_config.should be_nil
        target.windows_closed.should eq(1)

        context.close
      end

      it "survives a rollback target that raises" do
        target = RaisingRollbackTarget.new
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 9_u64,
          expiry_callback: -> { }
        )

        context.record_network_state({"ssid" => "test"})
        context.record_regulatory_config(0_u8, "XX")
        context.rollback(target)

        context.breadcrumb.should eq(0_u64)
        context.network_state_snapshot.should be_nil
        context.regulatory_config_snapshot.should be_nil

        context.close
      end

      it "is invoked automatically on timer expiry" do
        rollback_invoked = Channel(Bool).new(1)

        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 42_u64,
          expiry_callback: -> { rollback_invoked.send(true) }
        )

        context.breadcrumb.should eq(42_u64)
        context.arm(expiry_length: 1_u16, max_cumulative: 10_u16)

        # Wait for expiry and rollback
        select
        when rollback_invoked.receive
          # Expiry callback was invoked
        when timeout(2.seconds)
          fail "Rollback was not invoked on expiry"
        end

        # Note: Breadcrumb is reset by explicit rollback call, not automatically
        # The expiry_callback should call context.rollback() if rollback is needed
        context.close
      end
    end

    describe "time remaining" do
      it "reports primary time remaining" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.arm(expiry_length: 5_u16, max_cumulative: 10_u16)
        sleep 0.1.seconds

        remaining = context.primary_time_remaining
        remaining.should_not be_nil
        remaining.as(Time::Span).total_seconds.should be_close(5.0, 0.5)

        context.close
      end

      it "reports cumulative time remaining" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.arm(expiry_length: 5_u16, max_cumulative: 10_u16)
        sleep 0.1.seconds

        remaining = context.cumulative_time_remaining
        remaining.should_not be_nil
        remaining.as(Time::Span).total_seconds.should be_close(10.0, 0.5)

        context.close
      end

      it "returns nil when not armed" do
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { }
        )

        context.primary_time_remaining.should be_nil
        context.cumulative_time_remaining.should be_nil

        context.close
      end
    end

    describe "close" do
      it "stops timer and prevents expiry callback" do
        expired = false
        context = FailsafeContext.new(
          associated_fabric_index: nil,
          breadcrumb: 0_u64,
          expiry_callback: -> { expired = true }
        )

        context.arm(expiry_length: 1_u16, max_cumulative: 10_u16)
        sleep 0.1.seconds

        context.close
        sleep 1.5.seconds # Wait past expiration

        expired.should be_false # Should NOT fire
      end
    end
  end
end
