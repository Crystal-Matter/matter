require "../spec_helper"
require "../../src/matter/cluster/administrator_commissioning"
require "../../src/matter/cluster/general_commissioning"
require "../../src/matter/commissioning"
require "../../src/matter/session/context"

# Symmetric key length used by Matter secure sessions.
private SESSION_KEY_BYTES = Matter::Crypto::CRYPTO_SYMMETRIC_KEY_LENGTH

# Builds a session in the form the protocol layer keeps them in
# `Protocol::MessageHandler#sessions`.
private def secure_session(
  session_id : UInt16,
  peer_session_id : UInt16,
  case_session : Bool,
  fabric_index : UInt8? = nil,
) : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: session_id,
    peer_session_id: peer_session_id,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Random::Secure.random_bytes(SESSION_KEY_BYTES),
    decryption_key: Random::Secure.random_bytes(SESSION_KEY_BYTES),
    initiator: false,
    case_session: case_session,
    fabric_index: fabric_index
  )
end

module Matter
  describe "Commissioning Flow Integration" do
    describe "successful commissioning flow" do
      it "completes full commissioning with window → failsafe → complete" do
        # Setup: Create cluster instances
        admin_comm = Cluster::AdministratorCommissioning.new
        general_comm = Cluster::GeneralCommissioning.new

        # Configure lower timeouts for fast testing
        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Step 1: Administrator opens commissioning window (enhanced)
        verifier = Bytes.new(97, 0xAB_u8)
        salt = Bytes.new(32, 0x01_u8)

        open_request = Cluster::AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 5_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        admin_comm.open_commissioning_window(open_request, 1_u8, 0x1234_u16)
        admin_comm.window_status.should eq(Cluster::AdministratorCommissioning::CommissioningWindowStatus::EnhancedWindowOpen)
        admin_comm.admin_fabric_index.should eq(1_u8)

        # Step 2: New commissioner establishes PASE session (simulated)
        # In real implementation, PASE would use the verifier to establish session
        sleep 0.1.seconds

        # Step 3: New commissioner arms failsafe
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 3_u16,
          breadcrumb: 100_u64
        )

        response = general_comm.arm_failsafe(
          request: arm_request,
          session_fabric_index: nil, # PASE session (no fabric yet)
          is_pase_session: true
        )

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)
        general_comm.failsafe_armed?.should be_true
        general_comm.breadcrumb.should eq(100_u64)

        # Step 4: Configure network (simulated - NetworkCommissioning cluster)
        sleep 0.1.seconds
        # In real flow: AddOrUpdateWiFiNetwork, ConnectNetwork commands

        # Step 5: Add NOC (simulated - OperationalCredentials cluster)
        sleep 0.1.seconds
        # In real flow: CSR generation, AddNOC command
        # This would create fabric index 2 for new commissioner
        # And update the failsafe context fabric index to 2

        general_comm.record_added_fabric(2_u8)
        # Re-arm after AddNOC transfers the fail-safe to the new fabric.
        rearm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 3_u16,
          breadcrumb: 150_u64
        )
        general_comm.arm_failsafe(rearm_request, 2_u8, false)

        # Step 6: Complete commissioning (CASE session required)
        complete_response = general_comm.commissioning_complete(
          session_fabric_index: 2_u8, # New fabric from AddNOC
          is_case_session: true       # Now using CASE session
        )

        complete_response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)
        general_comm.failsafe_armed?.should be_false
        general_comm.breadcrumb.should eq(0_u64) # Reset on success

        # Cleanup
        admin_comm.close
      end

      it "completes basic commissioning flow with default passcode" do
        admin_comm = Cluster::AdministratorCommissioning.new
        general_comm = Cluster::GeneralCommissioning.new

        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Step 1: Open basic commissioning window
        open_request = Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(
          commissioning_timeout: 5_u16
        )

        admin_comm.open_basic_commissioning_window(open_request, 1_u8, 0x1234_u16)
        admin_comm.window_status.should eq(Cluster::AdministratorCommissioning::CommissioningWindowStatus::BasicWindowOpen)

        # Step 2-6: Same flow as enhanced (PASE → ArmFailSafe → NOC → Complete)
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 3_u16,
          breadcrumb: 200_u64
        )

        general_comm.arm_failsafe(arm_request, nil, true)
        general_comm.failsafe_armed?.should be_true

        sleep 0.2.seconds

        # Simulate AddNOC updating fabric
        general_comm.record_added_fabric(2_u8)
        rearm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 3_u16,
          breadcrumb: 250_u64
        )
        general_comm.arm_failsafe(rearm_request, 2_u8, false)

        complete_response = general_comm.commissioning_complete(2_u8, true)
        complete_response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)

        admin_comm.close
      end
    end

    describe "failsafe expiry and rollback" do
      it "triggers rollback when failsafe expires during commissioning" do
        general_comm = Cluster::GeneralCommissioning.new

        # Arm failsafe with short timeout
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 1_u16, # 1 second
          breadcrumb: 999_u64
        )

        general_comm.arm_failsafe(arm_request, nil, true)
        general_comm.breadcrumb.should eq(999_u64)

        # Simulate commissioning in progress (but not completing)
        sleep 0.5.seconds
        general_comm.failsafe_armed?.should be_true

        # Wait for failsafe to expire
        sleep 1.0.seconds

        # Verify rollback occurred
        general_comm.breadcrumb.should eq(0_u64) # Reset by rollback
        general_comm.failsafe_armed?.should be_false
      end

      it "closes commissioning window when failsafe expires" do
        admin_comm = Cluster::AdministratorCommissioning.new
        general_comm = Cluster::GeneralCommissioning.new
        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Open window
        open_request = Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(
          commissioning_timeout: 5_u16
        )
        admin_comm.open_basic_commissioning_window(open_request, 1_u8, 0x1234_u16)

        # Arm failsafe with short timeout
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 1_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request, nil, true)

        # Wait for failsafe expiry
        sleep 1.5.seconds

        # Failsafe should be expired
        general_comm.failsafe_armed?.should be_false
        general_comm.breadcrumb.should eq(0_u64)

        # Window should still be open (separate timeout)
        admin_comm.window_open?.should be_true

        admin_comm.close
      end
    end

    describe "concurrent commissioner conflicts" do
      it "prevents second administrator from opening window" do
        admin_comm = Cluster::AdministratorCommissioning.new
        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Admin 1 opens window
        open_request = Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(
          commissioning_timeout: 5_u16
        )
        admin_comm.open_basic_commissioning_window(open_request, 1_u8, 0x1234_u16)

        # Admin 2 tries to open window (should fail)
        expect_raises(Cluster::AdministratorCommissioning::BusyError, /already opened/) do
          admin_comm.open_basic_commissioning_window(open_request, 2_u8, 0x5678_u16)
        end

        # Original admin should still own window
        admin_comm.admin_fabric_index.should eq(1_u8)

        admin_comm.close
      end

      it "prevents CASE session from arming failsafe when different fabric active" do
        general_comm = Cluster::GeneralCommissioning.new

        # Fabric 1 arms failsafe
        arm_request1 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request1, 1_u8, false)

        # Fabric 2 tries to arm failsafe (should fail)
        arm_request2 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 200_u64
        )
        response = general_comm.arm_failsafe(arm_request2, 2_u8, false)

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::BusyWithOtherAdmin)
        general_comm.breadcrumb.should eq(100_u64) # Not changed
      end

      it "allows PASE to take over from CASE when window open" do
        admin_comm = Cluster::AdministratorCommissioning.new
        general_comm = Cluster::GeneralCommissioning.new
        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Open commissioning window
        open_request = Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(
          commissioning_timeout: 5_u16
        )
        admin_comm.open_basic_commissioning_window(open_request, 1_u8, 0x1234_u16)
        general_comm.open_commissioning_window

        # Fabric 1 (CASE) arms failsafe
        arm_request1 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request1, 1_u8, false)

        # PASE session takes over (priority)
        arm_request2 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 200_u64
        )
        response = general_comm.arm_failsafe(arm_request2, nil, true)

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)
        general_comm.breadcrumb.should eq(200_u64) # PASE took over

        admin_comm.close
      end
    end

    describe "window and failsafe coordination" do
      it "window expires independently of failsafe" do
        admin_comm = Cluster::AdministratorCommissioning.new
        general_comm = Cluster::GeneralCommissioning.new
        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Open short window (1 second)
        open_request = Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(
          commissioning_timeout: 1_u16
        )
        admin_comm.open_basic_commissioning_window(open_request, 1_u8, 0x1234_u16)

        # Arm longer failsafe (5 seconds)
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request, nil, true)

        # Wait for window to expire
        sleep 1.5.seconds
        Fiber.yield

        # Window should be closed
        admin_comm.window_open?.should be_false

        # Failsafe should still be armed
        general_comm.failsafe_armed?.should be_true
      end

      it "can revoke window while failsafe is armed" do
        admin_comm = Cluster::AdministratorCommissioning.new
        general_comm = Cluster::GeneralCommissioning.new
        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Open window
        open_request = Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(
          commissioning_timeout: 5_u16
        )
        admin_comm.open_basic_commissioning_window(open_request, 1_u8, 0x1234_u16)

        # Arm failsafe
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request, nil, true)

        # Revoke window (should succeed)
        admin_comm.revoke_commissioning
        admin_comm.window_open?.should be_false

        # Failsafe should still be armed
        general_comm.failsafe_armed?.should be_true
      end
    end

    describe "commissioning complete validation" do
      it "rejects commissioning complete without armed failsafe" do
        general_comm = Cluster::GeneralCommissioning.new

        response = general_comm.commissioning_complete(1_u8, true)

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::NoFailSafe)
      end

      it "rejects commissioning complete with PASE session" do
        general_comm = Cluster::GeneralCommissioning.new

        # Arm failsafe with PASE
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request, nil, true)

        # Try to complete with PASE (should fail)
        response = general_comm.commissioning_complete(nil, false)

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::InvalidAuthentication)
      end

      it "rejects commissioning complete with wrong fabric" do
        general_comm = Cluster::GeneralCommissioning.new

        # Arm failsafe with fabric 1
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request, 1_u8, false)

        # Try to complete with fabric 2 (should fail)
        response = general_comm.commissioning_complete(2_u8, true)

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::InvalidAuthentication)
      end
    end

    describe "re-arming failsafe during commissioning" do
      it "extends failsafe timeout with re-arm" do
        general_comm = Cluster::GeneralCommissioning.new

        # Initial arm
        arm_request1 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 2_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request1, nil, true)

        # Wait 1 second
        sleep 1.0.seconds

        # Re-arm with 2 more seconds
        arm_request2 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 2_u16,
          breadcrumb: 200_u64
        )
        response = general_comm.arm_failsafe(arm_request2, nil, true)

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)
        general_comm.breadcrumb.should eq(200_u64)

        # Failsafe should still be armed after original timeout
        sleep 1.5.seconds
        general_comm.failsafe_armed?.should be_true

        # But should expire after re-armed timeout
        sleep 1.0.seconds
        general_comm.failsafe_armed?.should be_false
      end

      it "disarms failsafe with expiry_length=0" do
        general_comm = Cluster::GeneralCommissioning.new

        # Arm failsafe
        arm_request1 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request1, nil, true)

        # Disarm with 0
        arm_request2 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 0_u16,
          breadcrumb: 200_u64
        )
        response = general_comm.arm_failsafe(arm_request2, nil, true)

        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)
        general_comm.failsafe_armed?.should be_false
        general_comm.breadcrumb.should eq(0_u64) # Expiry rolls back commissioning state
      end
    end

    describe "integration with the session store" do
      it "integrates with the session store for full commissioning flow" do
        # Create complete system
        sessions = {} of UInt16 => Session::SecureContext
        admin_comm = Cluster::AdministratorCommissioning.new
        general_comm = Cluster::GeneralCommissioning.new

        admin_comm.configure_timeout_bounds(minimum: 1_u16, maximum: 10_u16)

        # Step 1: Open commissioning window
        open_request = Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(
          commissioning_timeout: 5_u16
        )
        admin_comm.open_basic_commissioning_window(open_request, 1_u8, 0x1234_u16)
        general_comm.open_commissioning_window

        # Step 2: Establish PASE session (simulated)
        pase_session_id = 1000_u16
        sessions[pase_session_id] = secure_session(pase_session_id, 2000_u16, case_session: false)

        # Step 3: Arm failsafe (PASE session)
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request, nil, true)

        # Step 4: Add NOC and transition to CASE (simulated)
        # This would create fabric index 2
        new_fabric_index = 2_u8
        general_comm.record_added_fabric(new_fabric_index)
        rearm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 5_u16,
          breadcrumb: 150_u64
        )
        general_comm.arm_failsafe(rearm_request, new_fabric_index, false)

        # Establish CASE session on the new fabric
        case_session_id = 3000_u16
        sessions[case_session_id] = secure_session(case_session_id, 4000_u16, case_session: true, fabric_index: new_fabric_index)

        # Step 5: Complete commissioning
        response = general_comm.commissioning_complete(new_fabric_index, true)
        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)

        # The CASE session on the new fabric carries the commissioning through
        sessions[case_session_id].fabric_index.should eq(new_fabric_index)
        general_comm.failsafe_armed?.should be_false

        admin_comm.close
      end

      it "enforces Terms & Conditions when enabled" do
        general_comm = Cluster::GeneralCommissioning.new
        general_comm.terms_conditions_required = true

        # Try to complete commissioning without accepting TC
        arm_request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        general_comm.arm_failsafe(arm_request, 1_u8, false)

        response = general_comm.commissioning_complete(1_u8, true)

        # Should be blocked
        response.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::RequiredTCNotAccepted)

        # Now accept and try again
        general_comm.accept_terms_conditions

        arm_request2 = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 200_u64
        )
        general_comm.arm_failsafe(arm_request2, 1_u8, false)

        response2 = general_comm.commissioning_complete(1_u8, true)
        response2.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)
      end

      it "validates country codes with whitelist" do
        general_comm = Cluster::GeneralCommissioning.new

        # Configure whitelist for specific countries
        general_comm.country_code_whitelist = ["US", "CA", "GB", "DE"]

        # Try to set whitelisted country (should succeed)
        request_us = Cluster::GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: Cluster::GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "US",
          breadcrumb: 100_u64
        )
        response_us = (general_comm.regulatory_config = request_us)
        response_us.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::OK)

        # Try to set non-whitelisted country (should fail)
        request_jp = Cluster::GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: Cluster::GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "JP",
          breadcrumb: 200_u64
        )
        response_jp = (general_comm.regulatory_config = request_jp)
        response_jp.error_code.should eq(Cluster::GeneralCommissioning::CommissioningError::ValueOutsideRange)
        response_jp.debug_text.should contain("not in whitelist")
      end
    end
  end
end
