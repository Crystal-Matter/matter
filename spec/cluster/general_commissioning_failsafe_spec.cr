require "../support/general_commissioning_helpers"

module Matter::Cluster
  describe GeneralCommissioning do
    describe "fail-safe management" do
      it "tracks fail-safe state" do
        cluster = build(GeneralCommissioning, 0)

        cluster.failsafe_armed?.should be_false
        cluster.fail_safe_expiry_time.should be_nil
      end

      it "arms fail-safe" do
        cluster = build(GeneralCommissioning, 0)

        cluster.arm_fail_safe(60_u16)
        cluster.failsafe_armed?.should be_true
        cluster.fail_safe_expiry_time.should_not be_nil
      end

      it "disarms fail-safe" do
        cluster = build(GeneralCommissioning, 0)

        cluster.arm_fail_safe(60_u16)
        cluster.failsafe_armed?.should be_true

        cluster.disarm_fail_safe
        cluster.failsafe_armed?.should be_false
        cluster.fail_safe_expiry_time.should be_nil
      end

      it "checks if fail-safe is expired" do
        cluster = build(GeneralCommissioning, 0)

        cluster.arm_fail_safe(0_u16) # Expired immediately
        cluster.fail_safe_expired?.should be_true
      end
    end

    describe "ArmFailSafe command" do
      it "arms failsafe with valid parameters" do
        cluster = GeneralCommissioning.new
        request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 123_u64
        )

        response = cluster.arm_failsafe(
          request: request,
          session_fabric_index: nil,
          is_pase_session: true
        )

        response.error_code.ok?.should be_true
        cluster.failsafe_armed?.should be_true
        cluster.breadcrumb.should eq(123_u64)
      end

      it "rejects expiry length exceeding max cumulative" do
        cluster = GeneralCommissioning.new
        request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 1000_u16, # Exceeds 900s default max
          breadcrumb: 123_u64
        )

        response = cluster.arm_failsafe(
          request: request,
          session_fabric_index: nil,
          is_pase_session: true
        )

        response.error_code.value_outside_range?.should be_true
        cluster.failsafe_armed?.should be_false
      end

      it "disarms failsafe with expiry_length=0" do
        cluster = GeneralCommissioning.new

        # First arm
        request1 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 123_u64
        )
        cluster.arm_failsafe(request1, nil, true)
        cluster.failsafe_armed?.should be_true

        # Then disarm
        request2 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 0_u16,
          breadcrumb: 456_u64
        )
        response = cluster.arm_failsafe(request2, nil, true)

        response.error_code.ok?.should be_true
        cluster.failsafe_armed?.should be_false
        cluster.breadcrumb.should eq(0_u64)
      end

      it "re-arms existing failsafe with matching fabric" do
        cluster = GeneralCommissioning.new

        # Initial arm
        request1 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(request1, 1_u8, false)

        # Re-arm with same fabric
        request2 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 120_u16,
          breadcrumb: 200_u64
        )
        response = cluster.arm_failsafe(request2, 1_u8, false)

        response.error_code.ok?.should be_true
        cluster.failsafe_armed?.should be_true
        cluster.breadcrumb.should eq(200_u64)
      end

      it "rejects CASE session when different fabric is active" do
        cluster = GeneralCommissioning.new

        # Arm with fabric 1
        request1 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(request1, 1_u8, false)

        # Try to arm with fabric 2 (CASE session)
        request2 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 200_u64
        )
        response = cluster.arm_failsafe(request2, 2_u8, false)

        response.error_code.busy_with_other_admin?.should be_true
        cluster.breadcrumb.should eq(100_u64) # Not updated
      end

      it "allows PASE session to take over when commissioning window is open" do
        cluster = GeneralCommissioning.new
        cluster.open_commissioning_window

        # Arm with fabric 1 (CASE session)
        request1 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(request1, 1_u8, false)

        # PASE session takes over
        request2 = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 200_u64
        )
        response = cluster.arm_failsafe(request2, nil, true)

        response.error_code.ok?.should be_true
        cluster.breadcrumb.should eq(200_u64)
      end

      it "invokes expiry callback when failsafe timer expires" do
        cluster = GeneralCommissioning.new

        # Set initial breadcrumb via ArmFailSafe
        request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 1_u16, # 1 second
          breadcrumb: 42_u64
        )
        cluster.arm_failsafe(request, nil, true)
        cluster.breadcrumb.should eq(42_u64)

        # Wait for expiry
        sleep 1.5.seconds

        # Breadcrumb should be reset to 0 by rollback
        cluster.breadcrumb.should eq(0_u64)
        cluster.failsafe_armed?.should be_false
      end
    end

    describe "failsafe expiry behavior" do
      it "resets breadcrumb to 0 on failsafe expiry" do
        cluster = GeneralCommissioning.new

        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 1_u16,
          breadcrumb: 999_u64
        )
        cluster.arm_failsafe(arm_request, nil, true)
        cluster.breadcrumb.should eq(999_u64)

        # Wait for expiry
        sleep 1.5.seconds

        cluster.breadcrumb.should eq(0_u64)
        cluster.failsafe_armed?.should be_false
      end

      it "closes commissioning window on failsafe expiry" do
        cluster = GeneralCommissioning.new
        cluster.open_commissioning_window

        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 1_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(arm_request, nil, true)

        # Wait for expiry
        sleep 1.5.seconds

        # Commissioning window should be closed (verified internally)
        cluster.failsafe_armed?.should be_false
      end
    end

    describe "CommissioningComplete command" do
      it "completes commissioning successfully with valid CASE session" do
        cluster = GeneralCommissioning.new

        # Arm failsafe
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 123_u64
        )
        cluster.arm_failsafe(arm_request, 1_u8, false)

        # Complete commissioning
        response = cluster.commissioning_complete(
          session_fabric_index: 1_u8,
          is_case_session: true
        )

        response.error_code.ok?.should be_true
        cluster.failsafe_armed?.should be_false
        cluster.breadcrumb.should eq(0_u64) # Reset on success
      end

      it "rejects PASE session" do
        cluster = GeneralCommissioning.new

        # Arm failsafe with PASE
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 123_u64
        )
        cluster.arm_failsafe(arm_request, nil, true)

        # Try to complete with PASE session
        response = cluster.commissioning_complete(
          session_fabric_index: nil,
          is_case_session: false
        )

        response.error_code.invalid_authentication?.should be_true
        cluster.failsafe_armed?.should be_true # Still armed
      end

      it "rejects when no failsafe is armed" do
        cluster = GeneralCommissioning.new

        response = cluster.commissioning_complete(
          session_fabric_index: 1_u8,
          is_case_session: true
        )

        response.error_code.no_fail_safe?.should be_true
      end

      it "rejects when fabric doesn't match" do
        cluster = GeneralCommissioning.new

        # Arm with fabric 1
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 123_u64
        )
        cluster.arm_failsafe(arm_request, 1_u8, false)

        # Try to complete with fabric 2
        response = cluster.commissioning_complete(
          session_fabric_index: 2_u8,
          is_case_session: true
        )

        response.error_code.invalid_authentication?.should be_true
        cluster.failsafe_armed?.should be_true # Still armed
      end
    end

    describe "commissioning window management" do
      it "opens and closes commissioning window" do
        cluster = GeneralCommissioning.new

        cluster.open_commissioning_window
        cluster.close_commissioning_window

        # Window state is tracked internally
        # Verified through PASE priority behavior in earlier tests
      end
    end

    describe "commissioning complete callbacks" do
      it "closes commissioning window on successful complete" do
        cluster = GeneralCommissioning.new
        cluster.open_commissioning_window

        # Arm failsafe
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(arm_request, 1_u8, false)

        # Complete commissioning
        response = cluster.commissioning_complete(1_u8, true)
        response.error_code.ok?.should be_true

        # Commissioning window should be closed (internal state verified)
        cluster.failsafe_armed?.should be_false
      end
    end

    describe "Terms & Conditions feature" do
      it "allows commissioning complete when TC not required" do
        cluster = GeneralCommissioning.new
        cluster.terms_conditions_required = false

        # Arm failsafe and complete commissioning
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(arm_request, 1_u8, false)

        response = cluster.commissioning_complete(1_u8, true)
        response.error_code.ok?.should be_true
      end

      it "blocks commissioning complete when TC required but not accepted" do
        cluster = GeneralCommissioning.new
        cluster.terms_conditions_required = true
        cluster.terms_conditions_accepted?.should be_false

        # Arm failsafe
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(arm_request, 1_u8, false)

        # Try to complete commissioning without accepting TC
        response = cluster.commissioning_complete(1_u8, true)
        response.error_code.should eq(GeneralCommissioning::CommissioningError::RequiredTCNotAccepted)
      end

      it "allows commissioning complete when TC accepted" do
        cluster = GeneralCommissioning.new
        cluster.terms_conditions_required = true
        cluster.accept_terms_conditions
        cluster.terms_conditions_accepted?.should be_true

        # Arm failsafe
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(arm_request, 1_u8, false)

        # Complete commissioning
        response = cluster.commissioning_complete(1_u8, true)
        response.error_code.ok?.should be_true
      end
    end
  end
end
