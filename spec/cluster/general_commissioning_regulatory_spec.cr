require "../support/general_commissioning_helpers"

module Matter::Cluster
  describe GeneralCommissioning do
    describe "initialization" do
      it "creates general commissioning cluster" do
        cluster = build(GeneralCommissioning, 0)

        cluster.cluster_id.id.should eq(0x0030_u32)
        cluster.name.should eq("GeneralCommissioning")
        cluster.breadcrumb.should eq(0_u64)
        cluster.failsafe_armed?.should be_false
      end
    end

    describe "attributes" do
      it "reads Breadcrumb attribute" do
        cluster = build(GeneralCommissioning, 0)

        # UInt64 value 0 is TLV-encoded as 2 bytes (tag + value)
        read_tlv(cluster, GeneralCommissioning::ATTR_BREADCRUMB).to_slice.size.should eq(2)
      end

      it "writes Breadcrumb attribute" do
        cluster = build(GeneralCommissioning, 0)

        # Encode UInt64 value
        new_value = 0x1234567890ABCDEF_u64

        status = write(cluster,
          GeneralCommissioning::ATTR_BREADCRUMB,
          new_value
        )

        status.status.should eq(Matter::InteractionModel::StatusCode::Success)
        cluster.breadcrumb.should eq(0x1234567890ABCDEF_u64)
      end

      it "reads BasicCommissioningInfo attribute" do
        cluster = build(GeneralCommissioning, 0)

        value = cluster.read_attribute(GeneralCommissioning::ATTR_BASIC_COMMISSIONING_INFO)
        value.should be_a(TLV::Any)
      end

      it "reads RegulatoryConfig attribute" do
        cluster = build(GeneralCommissioning, 0)

        value = cluster.read_attribute(GeneralCommissioning::ATTR_REGULATORY_CONFIG)
        value.should be_a(TLV::Any)
      end

      it "reads LocationCapability attribute" do
        cluster = build(GeneralCommissioning, 0)

        value = cluster.read_attribute(GeneralCommissioning::ATTR_LOCATION_CAPABILITY)
        value.should be_a(TLV::Any)
      end

      it "reads SupportsConcurrentConnection attribute" do
        cluster = build(GeneralCommissioning, 0)

        read(cluster, GeneralCommissioning::ATTR_SUPPORTS_CONCURRENT_CONNECTION).should be_true
      end

      it "returns status for unsupported attribute write" do
        cluster = build(GeneralCommissioning, 0)

        status = write(cluster,
          GeneralCommissioning::ATTR_REGULATORY_CONFIG,
          0_u8
        )

        status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
      end
    end

    describe "metadata" do
      it "provides attribute metadata" do
        cluster = build(GeneralCommissioning, 0)

        attributes = cluster.attributes
        attributes.should_not be_empty
        attributes.size.should be >= 5

        breadcrumb = attributes.find { |attr| attr.id.id == GeneralCommissioning::ATTR_BREADCRUMB }
        breadcrumb.should_not be_nil
        breadcrumb_attr = breadcrumb.as(AttributeMetadata)
        breadcrumb_attr.name.should eq("breadcrumb")
        breadcrumb_attr.writable?.should be_true
      end

      it "provides command metadata" do
        cluster = build(GeneralCommissioning, 0)

        commands = cluster.commands
        commands.should_not be_empty
        commands.size.should be >= 3

        arm_failsafe = commands.find { |cmd| cmd.id.id == GeneralCommissioning::CMD_ARM_FAIL_SAFE }
        arm_failsafe.should_not be_nil
        arm_failsafe.as(CommandMetadata).name.should eq("armFailSafe")
      end
    end

    describe "BasicCommissioningInfo" do
      it "creates basic commissioning info" do
        info = GeneralCommissioning::BasicCommissioningInfo.new(
          fail_safe_expiry_length: 60_u16,
          max_cumulative_failsafe_seconds: 900_u16
        )

        info.fail_safe_expiry_length.should eq(60_u16)
        info.max_cumulative_failsafe_seconds.should eq(900_u16)
      end
    end

    describe "RegulatoryLocationType" do
      it "defines regulatory location types" do
        GeneralCommissioning::RegulatoryLocationType::Indoor.value.should eq(0_u8)
        GeneralCommissioning::RegulatoryLocationType::Outdoor.value.should eq(1_u8)
        GeneralCommissioning::RegulatoryLocationType::IndoorOutdoor.value.should eq(2_u8)
      end
    end

    describe "CommissioningError" do
      it "defines commissioning error codes" do
        GeneralCommissioning::CommissioningError::OK.value.should eq(0_u8)
        GeneralCommissioning::CommissioningError::ValueOutsideRange.value.should eq(1_u8)
        GeneralCommissioning::CommissioningError::InvalidAuthentication.value.should eq(2_u8)
        GeneralCommissioning::CommissioningError::NoFailSafe.value.should eq(3_u8)
        GeneralCommissioning::CommissioningError::BusyWithOtherAdmin.value.should eq(4_u8)
      end
    end

    describe "commands" do
      it "handles ArmFailSafe command" do
        cluster = build(GeneralCommissioning, 0)

        command_data = create_arm_failsafe_request_tlv(60_u16, 0x1234_u64)
        result = invoke(cluster, GeneralCommissioning::CMD_ARM_FAIL_SAFE, command_data)
        result.should be_a(CommandResponse)
      end

      it "handles SetRegulatoryConfig command" do
        cluster = build(GeneralCommissioning, 0)

        command_data = create_set_regulatory_config_request_tlv(2_u8, "US", 0x5678_u64) # IndoorOutdoor
        result = invoke(cluster, GeneralCommissioning::CMD_SET_REGULATORY_CONFIG, command_data)
        result.should be_a(CommandResponse)
      end

      it "handles CommissioningComplete command" do
        cluster = build(GeneralCommissioning, 0)

        # CommissioningComplete has no request parameters, but still needs empty TLV structure
        result = invoke(cluster, GeneralCommissioning::CMD_COMMISSIONING_COMPLETE, Bytes.new(0))
        result.should be_a(CommandResponse)
      end
    end

    describe "initialization and attributes" do
      it "initializes with default values" do
        cluster = GeneralCommissioning.new

        cluster.breadcrumb.should eq(0_u64)
        cluster.max_cumulative_failsafe_seconds.should eq(900_u16)
        cluster.max_network_commissioning_seconds.should eq(900_u16)
        cluster.regulatory_config.indoor_outdoor?.should be_true
        cluster.location_capability.indoor_outdoor?.should be_true
        cluster.supports_concurrent_connection?.should be_true
        cluster.failsafe_armed?.should be_false
      end

      it "exposes cluster ID" do
        GeneralCommissioning::CLUSTER_ID.should eq(0x0030_u32)
      end
    end

    describe "regulatory configuration" do
      it "tracks regulatory config" do
        cluster = build(GeneralCommissioning, 0)

        cluster.regulatory_config.should eq(GeneralCommissioning::RegulatoryLocationType::IndoorOutdoor)
      end

      it "updates regulatory config" do
        cluster = build(GeneralCommissioning, 0)

        cluster.regulatory_config = GeneralCommissioning::RegulatoryLocationType::Indoor
        cluster.regulatory_config.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor)
      end

      it "tracks country code" do
        cluster = build(GeneralCommissioning, 0)

        cluster.country_code.should eq("XX")
      end

      it "updates country code" do
        cluster = build(GeneralCommissioning, 0)

        cluster.country_code = "US"
        cluster.country_code.should eq("US")
      end
    end

    describe "SetRegulatoryConfig command" do
      it "sets regulatory config with valid parameters" do
        cluster = GeneralCommissioning.new

        request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Outdoor,
          country_code: "US",
          breadcrumb: 456_u64
        )

        response = (cluster.regulatory_config = request)

        response.error_code.ok?.should be_true
        cluster.regulatory_config.outdoor?.should be_true
        cluster.breadcrumb.should eq(456_u64)
      end

      it "rejects location exceeding capability" do
        cluster = GeneralCommissioning.new(
          location_capability: GeneralCommissioning::RegulatoryLocationType::Indoor)

        request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Outdoor,
          country_code: "US",
          breadcrumb: 456_u64
        )

        response = (cluster.regulatory_config = request)

        response.error_code.should eq(GeneralCommissioning::CommissioningError::ValueOutsideRange)
        cluster.regulatory_config.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor) # Not changed
        cluster.breadcrumb.should eq(0_u64)                                                       # Not updated on error
      end

      it "rejects invalid country code format" do
        cluster = GeneralCommissioning.new

        # Too short
        request1 = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "U",
          breadcrumb: 456_u64
        )
        response1 = (cluster.regulatory_config = request1)
        response1.error_code.should eq(GeneralCommissioning::CommissioningError::ValueOutsideRange)

        # Lowercase
        request2 = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "us",
          breadcrumb: 456_u64
        )
        response2 = (cluster.regulatory_config = request2)
        response2.error_code.should eq(GeneralCommissioning::CommissioningError::ValueOutsideRange)

        # Numbers
        request3 = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "U1",
          breadcrumb: 456_u64
        )
        response3 = (cluster.regulatory_config = request3)
        response3.error_code.should eq(GeneralCommissioning::CommissioningError::ValueOutsideRange)
      end

      it "accepts various valid country codes" do
        cluster = GeneralCommissioning.new

        ["US", "GB", "JP", "DE", "FR", "CA"].each do |country_code|
          request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
            new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
            country_code: country_code,
            breadcrumb: 100_u64
          )

          response = (cluster.regulatory_config = request)
          response.error_code.ok?.should be_true
        end
      end
    end

    describe "regulatory location validation" do
      it "allows any location with IndoorOutdoor capability" do
        cluster = GeneralCommissioning.new

        [
          GeneralCommissioning::RegulatoryLocationType::Indoor,
          GeneralCommissioning::RegulatoryLocationType::Outdoor,
          GeneralCommissioning::RegulatoryLocationType::IndoorOutdoor,
        ].each do |location|
          request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
            new_regulatory_config: location,
            country_code: "US",
            breadcrumb: 100_u64
          )

          response = (cluster.regulatory_config = request)
          response.error_code.ok?.should be_true
        end
      end

      it "restricts to Indoor only with Indoor capability" do
        cluster = GeneralCommissioning.new(
          location_capability: GeneralCommissioning::RegulatoryLocationType::Indoor)

        # Indoor should succeed
        request1 = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "US",
          breadcrumb: 100_u64
        )
        response1 = (cluster.regulatory_config = request1)
        response1.error_code.ok?.should be_true

        # Outdoor should fail
        request2 = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Outdoor,
          country_code: "US",
          breadcrumb: 200_u64
        )
        response2 = (cluster.regulatory_config = request2)
        response2.error_code.should eq(GeneralCommissioning::CommissioningError::ValueOutsideRange)
      end
    end

    describe "country code whitelist" do
      it "allows any country code when whitelist not configured" do
        cluster = GeneralCommissioning.new
        cluster.country_code_whitelist.should be_nil

        request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "ZZ",
          breadcrumb: 100_u64
        )

        response = (cluster.regulatory_config = request)
        response.error_code.ok?.should be_true
      end

      it "allows whitelisted country codes" do
        cluster = GeneralCommissioning.new
        cluster.country_code_whitelist = ["US", "CA", "GB", "JP"]

        request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "US",
          breadcrumb: 100_u64
        )

        response = (cluster.regulatory_config = request)
        response.error_code.ok?.should be_true
        cluster.country_code.should eq("US")
      end

      it "blocks non-whitelisted country codes" do
        cluster = GeneralCommissioning.new
        cluster.country_code_whitelist = ["US", "CA", "GB"]

        request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "FR", # Not in whitelist
          breadcrumb: 100_u64
        )

        response = (cluster.regulatory_config = request)
        response.error_code.should eq(GeneralCommissioning::CommissioningError::ValueOutsideRange)
        response.debug_text.should contain("not in whitelist")
      end

      it "validates all countries in whitelist" do
        cluster = GeneralCommissioning.new
        cluster.country_code_whitelist = ["US", "CA", "GB", "DE", "FR", "JP"]

        ["US", "CA", "GB", "DE", "FR", "JP"].each do |country|
          request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
            new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
            country_code: country,
            breadcrumb: 100_u64
          )

          response = (cluster.regulatory_config = request)
          response.error_code.ok?.should be_true
          cluster.country_code.should eq(country)
        end
      end
    end

    describe "commissioning info" do
      it "provides basic commissioning info" do
        cluster = build(GeneralCommissioning, 0)

        info = cluster.basic_commissioning_info
        info.fail_safe_expiry_length.should eq(60_u16)
        info.max_cumulative_failsafe_seconds.should eq(900_u16)
      end

      it "supports concurrent connection" do
        cluster = build(GeneralCommissioning, 0)

        cluster.supports_concurrent_connection?.should be_true
      end
    end

    describe "location capability" do
      it "tracks location capability" do
        cluster = build(GeneralCommissioning, 0)

        cluster.location_capability.should eq(GeneralCommissioning::RegulatoryLocationType::IndoorOutdoor)
      end
    end

    describe "breadcrumb tracking" do
      it "tracks breadcrumb value" do
        cluster = build(GeneralCommissioning, 0)

        cluster.breadcrumb.should eq(0_u64)
      end

      it "updates breadcrumb" do
        cluster = build(GeneralCommissioning, 0)

        cluster.breadcrumb = 0x123456789ABCDEF0_u64
        cluster.breadcrumb.should eq(0x123456789ABCDEF0_u64)
      end
    end

    describe "breadcrumb atomicity" do
      it "updates breadcrumb only on successful command execution" do
        cluster = GeneralCommissioning.new(
          location_capability: GeneralCommissioning::RegulatoryLocationType::Indoor)
        cluster.breadcrumb.should eq(0_u64)

        # Successful ArmFailSafe updates breadcrumb
        arm_request = GeneralCommissioning::ArmFailSafeRequest.new(
          expiry_length_seconds: 60_u16,
          breadcrumb: 100_u64
        )
        cluster.arm_failsafe(arm_request, nil, true)
        cluster.breadcrumb.should eq(100_u64)

        # Failed SetRegulatoryConfig doesn't update breadcrumb
        reg_request = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Outdoor,
          country_code: "US",
          breadcrumb: 200_u64
        )
        (cluster.regulatory_config = reg_request)
        cluster.breadcrumb.should eq(100_u64) # Still 100, not 200

        # Successful SetRegulatoryConfig updates breadcrumb
        reg_request2 = GeneralCommissioning::SetRegulatoryConfigRequest.new(
          new_regulatory_config: GeneralCommissioning::RegulatoryLocationType::Indoor,
          country_code: "US",
          breadcrumb: 300_u64
        )
        (cluster.regulatory_config = reg_request2)
        cluster.breadcrumb.should eq(300_u64)
      end
    end
  end
end
