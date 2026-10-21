require "../spec_helper"
require "../../src/matter/cluster/basic_information"

describe Matter::Cluster::BasicInformation do
  describe "initialization" do
    it "creates basic information cluster" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      cluster.cluster_id.id.should eq(0x0028_u32)
      cluster.name.should eq("BasicInformation")
      cluster.data_version.should eq(0_u32)
    end

    it "initializes with default values" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      cluster.data_model_revision.should eq(Matter::Cluster::BasicInformation::DATA_MODEL_REVISION_1_6)
      cluster.specification_version.should eq(0_u32)
      cluster.max_paths_per_invoke.should eq(1_u16)
      cluster.configuration_version.should eq(1_u32)
      cluster.vendor_name.should eq("")
      cluster.vendor_id.should eq(0_u16)
      cluster.product_name.should eq("")
      cluster.product_id.should eq(0_u16)
      cluster.node_label.should eq("")
      cluster.location.should eq("XX")
      cluster.hardware_version.should eq(0_u16)
      cluster.hardware_version_string.should eq("1.0")
      cluster.software_version.should eq(0_u32)
      cluster.software_version_string.should eq("1.0.0")
    end
  end

  describe "required attributes" do
    it "has all required attributes" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      attributes = cluster.attributes
      attributes.should_not be_empty
      attributes.size.should be >= 15

      # Check for required attributes
      data_model_revision = attributes.find { |attr| attr.id.id == Matter::Cluster::BasicInformation::ATTR_DATA_MODEL_REVISION }
      data_model_revision.should_not be_nil
      dmr_attr = data_model_revision.as(Matter::Cluster::AttributeMetadata)
      dmr_attr.name.should eq("dataModelRevision")
      dmr_attr.writable?.should be_false

      vendor_name = attributes.find { |attr| attr.id.id == Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME }
      vendor_name.should_not be_nil
      vendor_name.as(Matter::Cluster::AttributeMetadata).writable?.should be_false

      vendor_id = attributes.find { |attr| attr.id.id == Matter::Cluster::BasicInformation::ATTR_VENDOR_ID }
      vendor_id.should_not be_nil
      vendor_id.as(Matter::Cluster::AttributeMetadata).writable?.should be_false

      product_name = attributes.find { |attr| attr.id.id == Matter::Cluster::BasicInformation::ATTR_PRODUCT_NAME }
      product_name.should_not be_nil
      product_name.as(Matter::Cluster::AttributeMetadata).writable?.should be_false

      node_label = attributes.find { |attr| attr.id.id == Matter::Cluster::BasicInformation::ATTR_NODE_LABEL }
      node_label.should_not be_nil
      node_label.as(Matter::Cluster::AttributeMetadata).writable?.should be_true # User can set node label
    end
  end

  describe "Matter 1.6 version and capability metadata" do
    it "advertises revision 6 and the required version and capacity attributes" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(6_u16)
      read(cluster, Matter::Cluster::BasicInformation::ATTR_DATA_MODEL_REVISION).should eq(21_u16)
      read(cluster, Matter::Cluster::BasicInformation::ATTR_SPECIFICATION_VERSION).should eq(0_u32)
      read(cluster, Matter::Cluster::BasicInformation::ATTR_MAX_PATHS_PER_INVOKE).should eq(1_u16)
      read(cluster, Matter::Cluster::BasicInformation::ATTR_CONFIGURATION_VERSION).should eq(1_u32)

      ids = attribute_ids(cluster)
      ids.should contain(Matter::Cluster::BasicInformation::ATTR_SPECIFICATION_VERSION)
      ids.should contain(Matter::Cluster::BasicInformation::ATTR_MAX_PATHS_PER_INVOKE)
      ids.should contain(Matter::Cluster::BasicInformation::ATTR_CONFIGURATION_VERSION)
      write(cluster, Matter::Cluster::BasicInformation::ATTR_CONFIGURATION_VERSION, 2_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end

    it "allows a certified application to report its exact specification version" do
      version = Matter::Cluster::BasicInformation::MATTER_1_6_SPECIFICATION_VERSION
      cluster = build(Matter::Cluster::BasicInformation, 0, specification_version: version, max_paths_per_invoke: 4_u16)

      read(cluster, Matter::Cluster::BasicInformation::ATTR_SPECIFICATION_VERSION).should eq(version)
      read(cluster, Matter::Cluster::BasicInformation::ATTR_MAX_PATHS_PER_INVOKE).should eq(4_u16)
    end

    it "rejects zero capacity and configuration versions" do
      expect_raises(Matter::ConfigurationError) { build(Matter::Cluster::BasicInformation, 0, max_paths_per_invoke: 0_u16) }
      expect_raises(Matter::ConfigurationError) { build(Matter::Cluster::BasicInformation, 0, configuration_version: 0_u32) }
    end
  end

  describe "TLV attribute encoding - read_attribute" do
    it "reads DATA_MODEL_REVISION with TLV encoding" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        data_model_revision: 17_u16
      )

      read(cluster, Matter::Cluster::BasicInformation::ATTR_DATA_MODEL_REVISION).should eq(17)
    end

    it "reads VENDOR_NAME with TLV encoding" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        vendor_name: "Test Vendor"
      )

      read(cluster, Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME).should eq("Test Vendor")
    end

    it "reads VENDOR_ID with TLV encoding" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        vendor_id: 0xFFF1_u16
      )

      read(cluster, Matter::Cluster::BasicInformation::ATTR_VENDOR_ID).should eq(0xFFF1)
    end

    it "reads SOFTWARE_VERSION with TLV encoding" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        software_version: 0x01020304_u32
      )

      read(cluster, Matter::Cluster::BasicInformation::ATTR_SOFTWARE_VERSION).should eq(0x01020304)
    end

    it "reads LOCAL_CONFIG_DISABLED with TLV encoding" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        local_config_disabled: true
      )

      read(cluster, Matter::Cluster::BasicInformation::ATTR_LOCAL_CONFIG_DISABLED).should be_true
    end

    it "reads CAPABILITY_MINIMA with TLV struct encoding" do
      capability = Matter::Cluster::BasicInformation::CapabilityMinimaStruct.new(
        case_sessions_per_fabric: 5_u16,
        subscriptions_per_fabric: 10_u16
      )

      cluster = build(Matter::Cluster::BasicInformation, 0,
        capability_minima: capability
      )

      # Parse TLV structure using TLV::Serializable
      parsed = Matter::Cluster::BasicInformation::CapabilityMinimaStruct.from_tlv(read_tlv(cluster, Matter::Cluster::BasicInformation::ATTR_CAPABILITY_MINIMA))
      parsed.case_sessions_per_fabric.should eq(5)
      parsed.subscriptions_per_fabric.should eq(10)
    end

    it "reads PRODUCT_APPEARANCE with TLV struct encoding" do
      appearance = Matter::Cluster::BasicInformation::ProductAppearanceStruct.new(
        finish: Matter::Cluster::BasicInformation::ProductFinish::Matte,
        primary_color: Matter::Cluster::BasicInformation::Color::Blue
      )

      cluster = build(Matter::Cluster::BasicInformation, 0,
        product_appearance: appearance
      )

      # Parse TLV structure using TLV::Serializable
      parsed = Matter::Cluster::BasicInformation::ProductAppearanceStruct.from_tlv(read_tlv(cluster, Matter::Cluster::BasicInformation::ATTR_PRODUCT_APPEARANCE))
      parsed.finish.should eq(Matter::Cluster::BasicInformation::ProductFinish::Matte)
      parsed.primary_color.should eq(Matter::Cluster::BasicInformation::Color::Blue)
    end

    it "reads PRODUCT_APPEARANCE with nullable primary_color omitted" do
      appearance = Matter::Cluster::BasicInformation::ProductAppearanceStruct.new(
        finish: Matter::Cluster::BasicInformation::ProductFinish::Polished,
        primary_color: nil
      )

      cluster = build(Matter::Cluster::BasicInformation, 0,
        product_appearance: appearance
      )

      # Parse TLV structure using TLV::Serializable
      parsed = Matter::Cluster::BasicInformation::ProductAppearanceStruct.from_tlv(read_tlv(cluster, Matter::Cluster::BasicInformation::ATTR_PRODUCT_APPEARANCE))
      parsed.finish.should eq(Matter::Cluster::BasicInformation::ProductFinish::Polished)
      parsed.primary_color.should be_nil
    end

    it "returns UnsupportedAttribute for missing PRODUCT_APPEARANCE" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        product_appearance: nil
      )

      read_status(cluster, Matter::Cluster::BasicInformation::ATTR_PRODUCT_APPEARANCE).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "raw attribute value decoding - write_attribute" do
    it "writes NODE_LABEL with TLV decoding" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      # Encode new label as TLV
      tlv_value = "My Device"

      initial_version = cluster.data_version
      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_NODE_LABEL, tlv_value)

      status.should be_a(Matter::InteractionModel::Status)
      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster.node_label.should eq("My Device")
      cluster.data_version.should eq(initial_version + 1)
    end

    it "rejects NODE_LABEL exceeding max length (32 bytes)" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      long_label = "a" * 33
      tlv_value = long_label

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_NODE_LABEL, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end

    it "writes LOCATION with TLV decoding and validates format" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      tlv_value = "US"

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_LOCATION, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster.location.should eq("US")
    end

    it "normalizes LOCATION to uppercase" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      tlv_value = "gb"

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_LOCATION, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster.location.should eq("GB")
    end

    it "accepts region-agnostic location XX" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      tlv_value = "XX"

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_LOCATION, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster.location.should eq("XX")
    end

    it "rejects LOCATION with invalid length" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      tlv_value = "USA"

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_LOCATION, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end

    it "rejects LOCATION with non-alpha characters" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      tlv_value = "U1"

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_LOCATION, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end

    it "writes LOCAL_CONFIG_DISABLED with TLV decoding" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        local_config_disabled: false
      )

      tlv_value = true

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_LOCAL_CONFIG_DISABLED, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster.local_config_disabled?.should be_true
    end

    it "rejects write to read-only VENDOR_NAME" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      tlv_value = "New Vendor"

      status = write(cluster, Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME, tlv_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  describe "event emission" do
    it "emits StartUp event with TLV-encoded software version" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        software_version: 0x01000000_u32
      )

      event_data = cluster.emit_start_up_event(0x01000000_u32)
      event_data.should be_a(Bytes)

      # Parse using TLV::Serializable
      parsed = Matter::Cluster::BasicInformation::StartUpEvent.from_slice(event_data)
      parsed.software_version.should eq(0x01000000)
    end

    it "emits ShutDown event with empty TLV structure" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      event_data = cluster.emit_shut_down_event
      event_data.should be_a(Bytes)

      # ShutDown event is an empty structure - just verify it deserializes
      parsed = Matter::Cluster::BasicInformation::ShutDownEvent.from_slice(event_data)
      parsed.should_not be_nil
    end

    it "emits Leave event with fabric index" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      event_data = cluster.emit_leave_event(1_u8)
      event_data.should be_a(Bytes)

      # Parse using TLV::Serializable
      parsed = Matter::Cluster::BasicInformation::LeaveEvent.from_slice(event_data)
      parsed.fabric_index.should eq(1)
    end

    it "emits ReachableChanged event and updates reachable attribute" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        reachable: true
      )

      initial_version = cluster.data_version
      event_data = cluster.emit_reachable_changed_event(false)
      event_data.should be_a(Bytes)

      cluster.reachable?.should be_false
      cluster.data_version.should eq(initial_version + 1)

      # Parse using TLV::Serializable
      parsed = Matter::Cluster::BasicInformation::ReachableChangedEvent.from_slice(event_data)
      parsed.reachable_new_value?.should be_false
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute read" do
      cluster = build(Matter::Cluster::BasicInformation, 0)

      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "complete device configuration" do
    it "configures a complete device with all attributes" do
      cluster = build(Matter::Cluster::BasicInformation, 0,
        vendor_name: "SmartHome Inc",
        vendor_id: 0xFFF1_u16,
        product_name: "WiFi Smart Bulb",
        product_id: 0x8001_u16,
        node_label: "Kitchen Light",
        hardware_version: 2_u16,
        hardware_version_string: "2.1",
        software_version: 0x01020304_u32,
        software_version_string: "1.2.3.4",
        manufacturing_date: "20231215",
        part_number: "BULB-001",
        product_url: "https://smarthome.example/bulb",
        serial_number: "SN987654321"
      )

      cluster.vendor_name.should eq("SmartHome Inc")
      cluster.vendor_id.should eq(0xFFF1_u16)
      cluster.product_name.should eq("WiFi Smart Bulb")
      cluster.product_id.should eq(0x8001_u16)
      cluster.node_label.should eq("Kitchen Light")
      cluster.hardware_version.should eq(2_u16)
      cluster.hardware_version_string.should eq("2.1")
      cluster.software_version.should eq(0x01020304_u32)
      cluster.software_version_string.should eq("1.2.3.4")
      cluster.manufacturing_date.should eq("20231215")
      cluster.part_number.should eq("BULB-001")
      cluster.product_url.should eq("https://smarthome.example/bulb")
      cluster.serial_number.should eq("SN987654321")
    end
  end
end
