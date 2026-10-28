require "../support/administrator_commissioning_helpers"

module Matter::Cluster
  describe AdministratorCommissioning do
    describe "PAKE parameters" do
      it "keeps the parameters of an open enhanced window and drops them on close" do
        cluster = build(AdministratorCommissioning, 0)

        verifier = Bytes.new(AdministratorCommissioning::PAKE_PASSCODE_VERIFIER_LENGTH, 0xAB_u8)
        salt = Bytes.new(AdministratorCommissioning::PAKE_SALT_MAX_LENGTH, 0xCD_u8)
        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 300_u16,
          pake_passcode_verifier: verifier,
          discriminator: 3840_u16,
          iterations: 1000_u32,
          salt: salt
        )

        cluster.open_commissioning_window(request, 1_u8, 0xFFF1_u16)

        cluster.pake_verifier.should eq(verifier)
        cluster.discriminator.should eq(3840_u16)
        cluster.iterations.should eq(1000_u32)
        cluster.salt.should eq(salt)

        cluster.close

        cluster.pake_verifier.should be_nil
        cluster.discriminator.should be_nil
        cluster.iterations.should be_nil
        cluster.salt.should be_nil
      end
    end

    describe "OpenCommissioningWindow command (Enhanced)" do
      it "publishes the authenticated CASE fabric and its vendor on a wire command" do
        cluster = AdministratorCommissioning.new
        cluster.on_fabric_vendor_id = ->(index : UInt8) do
          index == 1_u8 ? 0xFFF1_u16 : nil
        end
        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 180_u16,
          pake_passcode_verifier: Bytes.new(AdministratorCommissioning::PAKE_PASSCODE_VERIFIER_LENGTH, 0_u8),
          discriminator: 3840_u16,
          iterations: AdministratorCommissioning::PBKDF2_MIN_ITERATIONS.to_u32,
          salt: Bytes.new(AdministratorCommissioning::PAKE_SALT_MIN_LENGTH, 1_u8)
        )

        cluster.invoke_command(AdministratorCommissioning::CMD_OPEN_COMMISSIONING_WINDOW,
          request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8).should eq(InteractionModel::Status.success)
        cluster.admin_fabric_index.should eq(1_u8)
        cluster.admin_vendor_id.should eq(0xFFF1_u16)
      end

      it "opens enhanced commissioning window with valid parameters" do
        cluster = AdministratorCommissioning.new

        # Valid 97-byte verifier (32 bytes w0 + 65 bytes L)
        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)

        cluster.window_status.should eq(AdministratorCommissioning::CommissioningWindowStatus::EnhancedWindowOpen)
        cluster.admin_fabric_index.should eq(1_u8)
        cluster.admin_vendor_id.should eq(0x1234_u16)
        cluster.window_open?.should be_true
      end

      it "rejects invalid verifier length" do
        cluster = AdministratorCommissioning.new

        # Invalid: 96 bytes (should be 97)
        verifier = Bytes.new(96, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        expect_raises(AdministratorCommissioning::PAKEParameterError, /verifier length is invalid/) do
          cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        end

        cluster.window_open?.should be_false
      end

      it "rejects iterations below minimum" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 999_u32, # Below 1000
          salt: salt
        )

        expect_raises(AdministratorCommissioning::PAKEParameterError, /iterations invalid/) do
          cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        end
      end

      it "rejects iterations above maximum" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 100001_u32, # Above 100,000
          salt: salt
        )

        expect_raises(AdministratorCommissioning::PAKEParameterError, /iterations invalid/) do
          cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        end
      end

      it "rejects salt below minimum length" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(15, 1_u8) # Below 16 bytes

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        expect_raises(AdministratorCommissioning::PAKEParameterError, /salt has invalid length/) do
          cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        end
      end

      it "rejects salt above maximum length" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(33, 1_u8) # Above 32 bytes

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        expect_raises(AdministratorCommissioning::PAKEParameterError, /salt has invalid length/) do
          cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        end
      end

      it "rejects timeout below minimum" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 179_u16, # Below 180 seconds (3 minutes)
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        expect_raises(ArgumentError, /must not be lower/) do
          cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        end
      end

      it "rejects timeout above maximum" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 901_u16, # Above 900 seconds (15 minutes)
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        expect_raises(ArgumentError, /must not exceed/) do
          cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        end
      end

      it "rejects opening window when one already open" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        # Open first window
        cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)

        # Try to open second window
        expect_raises(AdministratorCommissioning::BusyError, /already opened/) do
          cluster.open_commissioning_window(request, 2_u8, 0x5678_u16)
        end

        # First window should still be open
        cluster.admin_fabric_index.should eq(1_u8)
      end
    end

    describe "PAKE parameter validation edge cases" do
      it "accepts valid verifier at exactly 97 bytes" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0xAB_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        cluster.window_open?.should be_true
      end

      it "accepts iterations at minimum boundary (1000)" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 1000_u32,
          salt: salt
        )

        cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        cluster.window_open?.should be_true
      end

      it "accepts iterations at maximum boundary (100,000)" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 100000_u32,
          salt: salt
        )

        cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        cluster.window_open?.should be_true
      end

      it "accepts salt at minimum boundary (16 bytes)" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(16, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        cluster.window_open?.should be_true
      end

      it "accepts salt at maximum boundary (32 bytes)" do
        cluster = AdministratorCommissioning.new

        verifier = Bytes.new(97, 0_u8)
        salt = Bytes.new(32, 1_u8)

        request = AdministratorCommissioning::OpenCommissioningWindowRequest.new(
          commissioning_timeout: 900_u16,
          pake_passcode_verifier: verifier,
          discriminator: 1234_u16,
          iterations: 10000_u32,
          salt: salt
        )

        cluster.open_commissioning_window(request, 1_u8, 0x1234_u16)
        cluster.window_open?.should be_true
      end
    end

    describe "session context" do
      it "initializes session context as nil" do
        cluster = build(AdministratorCommissioning, 0)

        cluster.session_fabric_index.should be_nil
        cluster.session_vendor_id.should be_nil
      end

      it "uses authenticated CASE context in OpenCommissioningWindow" do
        cluster = build(AdministratorCommissioning, 0)

        # Legacy mutable context must not override the authenticated command.
        cluster.session_fabric_index = 4_u8
        cluster.session_vendor_id = 0xEEEE_u16
        cluster.on_fabric_vendor_id = ->(index : UInt8) { index == 3_u8 ? 0xABCD_u16 : nil }

        # Create TLV-encoded OpenCommissioningWindowRequest
        tlv_data = create_open_commissioning_window_tlv(
          timeout: 900_u16,
          verifier: Bytes.new(97, 0xAB_u8),
          discriminator: 3840_u16,
          iterations: 10000_u32,
          salt: Bytes.new(32, 0xCD_u8)
        )

        result = invoke(cluster,
          AdministratorCommissioning::CMD_OPEN_COMMISSIONING_WINDOW,
          tlv_data,
          is_case_session: true,
          fabric_index: 3_u8
        )

        result.should be_a(Matter::InteractionModel::Status | CommandResponse)
        # Only the authenticated command identity is published.
        cluster.admin_fabric_index.should eq(3_u8)
        cluster.admin_vendor_id.should eq(0xABCD_u16)
        cluster.window_status.should eq(AdministratorCommissioning::CommissioningWindowStatus::EnhancedWindowOpen)
      end

      it "uses nil values when session context not set in OpenCommissioningWindow" do
        cluster = build(AdministratorCommissioning, 0)

        # Don't set session context - should use nil (no session info available)

        # Create TLV-encoded OpenCommissioningWindowRequest
        tlv_data = create_open_commissioning_window_tlv(
          timeout: 900_u16,
          verifier: Bytes.new(97, 0xAB_u8),
          discriminator: 3840_u16,
          iterations: 10000_u32,
          salt: Bytes.new(32, 0xCD_u8)
        )

        result = invoke(cluster,
          AdministratorCommissioning::CMD_OPEN_COMMISSIONING_WINDOW,
          tlv_data
        )

        result.should be_a(Matter::InteractionModel::Status | CommandResponse)
        # Verify nil values when no session context
        cluster.admin_fabric_index.should be_nil
        cluster.admin_vendor_id.should be_nil
        cluster.window_status.should eq(AdministratorCommissioning::CommissioningWindowStatus::EnhancedWindowOpen)
      end

      it "uses authenticated CASE context in OpenBasicCommissioningWindow" do
        cluster = build(AdministratorCommissioning, 0)

        cluster.session_fabric_index = 4_u8
        cluster.session_vendor_id = 0xEEEE_u16
        cluster.on_fabric_vendor_id = ->(index : UInt8) { index == 5_u8 ? 0x1234_u16 : nil }

        # Create TLV-encoded OpenBasicCommissioningWindowRequest
        tlv_data = create_open_basic_commissioning_window_tlv(600_u16)

        result = invoke(cluster,
          AdministratorCommissioning::CMD_OPEN_BASIC_COMMISSIONING_WINDOW,
          tlv_data,
          is_case_session: true,
          fabric_index: 5_u8
        )

        result.should be_a(Matter::InteractionModel::Status | CommandResponse)
        # Only the authenticated command identity is published.
        cluster.admin_fabric_index.should eq(5_u8)
        cluster.admin_vendor_id.should eq(0x1234_u16)
        cluster.window_status.should eq(AdministratorCommissioning::CommissioningWindowStatus::BasicWindowOpen)
      end

      it "uses nil values when session context not set in OpenBasicCommissioningWindow" do
        cluster = build(AdministratorCommissioning, 0)

        # Don't set session context - should use nil (no session info available)

        # Create TLV-encoded OpenBasicCommissioningWindowRequest
        tlv_data = create_open_basic_commissioning_window_tlv(600_u16)

        result = invoke(cluster,
          AdministratorCommissioning::CMD_OPEN_BASIC_COMMISSIONING_WINDOW,
          tlv_data
        )

        result.should be_a(Matter::InteractionModel::Status | CommandResponse)
        # Verify nil values when no session context
        cluster.admin_fabric_index.should be_nil
        cluster.admin_vendor_id.should be_nil
        cluster.window_status.should eq(AdministratorCommissioning::CommissioningWindowStatus::BasicWindowOpen)
      end

      it "uses each command's authenticated CASE fabric" do
        cluster = build(AdministratorCommissioning, 0)
        cluster.on_fabric_vendor_id = ->(index : UInt8) do
          case index
          when 1_u8 then 0x1111_u16
          when 2_u8 then 0x2222_u16
          end
        end

        # First command with fabric 1
        cluster.session_fabric_index = 1_u8
        cluster.session_vendor_id = 0x1111_u16

        tlv_data = create_open_basic_commissioning_window_tlv(600_u16)

        invoke(cluster,
          AdministratorCommissioning::CMD_OPEN_BASIC_COMMISSIONING_WINDOW,
          tlv_data,
          is_case_session: true,
          fabric_index: 1_u8
        )

        # Verify first command used fabric 1
        cluster.admin_fabric_index.should eq(1_u8)
        cluster.admin_vendor_id.should eq(0x1111_u16)
        cluster.window_status.should eq(AdministratorCommissioning::CommissioningWindowStatus::BasicWindowOpen)

        # Close window to allow second open
        cluster.close_window

        # Second command with different fabric
        cluster.session_fabric_index = 2_u8
        cluster.session_vendor_id = 0x2222_u16

        invoke(cluster,
          AdministratorCommissioning::CMD_OPEN_BASIC_COMMISSIONING_WINDOW,
          tlv_data,
          is_case_session: true,
          fabric_index: 2_u8
        )

        # Verify second command used fabric 2
        cluster.admin_fabric_index.should eq(2_u8)
        cluster.admin_vendor_id.should eq(0x2222_u16)
        cluster.window_status.should eq(AdministratorCommissioning::CommissioningWindowStatus::BasicWindowOpen)
      end
    end
  end
end
