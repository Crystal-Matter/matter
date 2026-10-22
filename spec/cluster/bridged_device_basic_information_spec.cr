require "../spec_helper"
require "../../src/matter/cluster/bridged_device_basic_information"

describe Matter::Cluster::BridgedDeviceBasicInformation do
  describe "#initialize" do
    it "creates cluster with default values" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")

      cluster.reachable?.should be_true
      cluster.vendor_name.should be_nil
      cluster.product_name.should be_nil
      cluster.unique_id.should eq("test-bridged")
    end

    it "creates cluster with custom values" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation,
        reachable: true,
        vendor_name: "Test Vendor",
        product_name: "Test Product",
        node_label: "Test Label",
        unique_id: "unique-123",
        hardware_version: 2_u16,
        software_version: 100_u32
      )

      cluster.reachable?.should be_true
      cluster.vendor_name.should eq("Test Vendor")
      cluster.product_name.should eq("Test Product")
      cluster.node_label.should eq("Test Label")
      cluster.unique_id.should eq("unique-123")
      cluster.hardware_version.should eq(2_u16)
      cluster.software_version.should eq(100_u32)
    end
  end

  describe "#read_attribute" do
    it "reads Reachable attribute" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", reachable: true)

      read(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_REACHABLE).should be_true
    end

    it "reads NodeLabel attribute" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", node_label: "My Device")

      read(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_NODE_LABEL).should eq("My Device")
    end

    it "reads VendorName when present" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", vendor_name: "Acme Corp")

      read(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_VENDOR_NAME).should eq("Acme Corp")
    end

    it "returns UnsupportedAttribute for VendorName when not present" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")

      read_status(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_VENDOR_NAME).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end

    it "reads UniqueID when present" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "abc-123")

      read(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_UNIQUE_ID).should eq("abc-123")
    end

    it "advertises revision 6 and exposes ConfigurationVersion only when supplied" do
      absent = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "bridge-absent")
      absent.cluster_revision.should eq(6_u16)
      read_status(absent, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_CONFIGURATION_VERSION).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)

      present = build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "bridge-present", configuration_version: 1_u32)
      read(present, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_CONFIGURATION_VERSION).should eq(1_u32)
      write(present, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_CONFIGURATION_VERSION, 2_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  describe "#write_attribute" do
    it "allows writing NodeLabel" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", node_label: "Original")

      new_label = "New Label"
      status = write(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_NODE_LABEL, new_label)

      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster.node_label.should eq("New Label")
    end

    it "rejects NodeLabel over 32 bytes" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")

      long_label = ("A" * 33)
      status = write(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_NODE_LABEL, long_label)

      status.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end

    it "rejects writing to read-only attributes" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", reachable: true)

      value = Bytes[0]
      status = write(cluster, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_REACHABLE, value)

      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  describe "#reachable=" do
    it "updates reachable state" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", reachable: true)

      cluster.reachable?.should be_true

      cluster.reachable = (false)
      cluster.reachable?.should be_false

      cluster.reachable = (true)
      cluster.reachable?.should be_true
    end

    it "calls reachability callback" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", reachable: true)

      callback_called = false
      callback_value = true

      cluster.on_reachable_changed do |new_state|
        callback_called = true
        callback_value = new_state
      end

      cluster.reachable = (false)

      callback_called.should be_true
      callback_value.should be_false
    end

    it "does not call callback when state unchanged" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", reachable: true)

      callback_called = false
      cluster.on_reachable_changed do |_new_state|
        callback_called = true
      end

      cluster.reachable = (true) # Same state
      callback_called.should be_false
    end
  end

  describe "#emit_reachable_changed_event" do
    it "generates valid TLV event data" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")

      event_data = cluster.emit_reachable_changed_event(false)
      event_data.should be_a(Bytes)
      event_data.size.should be > 0

      # Verify it's valid TLV
      decoded = Matter::Cluster::BridgedDeviceBasicInformation::ReachableChangedEvent.from_slice(event_data)
      decoded.reachable_new_value?.should be_false
    end
  end

  describe "persistence" do
    it "saves and restores state" do
      cluster1 = build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "test-bridged",
        reachable: true,
        node_label: "Saved Label"
      )

      # Modify state
      new_label = "Modified Label"
      write(cluster1, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_NODE_LABEL, new_label)
      cluster1.reachable = false

      # Save state
      document = cluster1.save_state.as(Matter::Storage::Document)
      document["node_label"].should eq("Modified Label")
      document["reachable"].should be_false

      # Create new cluster and restore
      cluster2 = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")
      cluster2.restore_state(document)

      cluster2.node_label.should eq("Modified Label")
      cluster2.reachable?.should be_false
    end

    it "persists a supplied ConfigurationVersion across restart" do
      source = build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "bridge-config", configuration_version: 1_u32)
      source.configuration_version = 2_u32
      document = source.save_state.as(Matter::Storage::Document)
      document["configuration_version"].should eq(2_u32)

      restored = build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "bridge-config", configuration_version: 1_u32)
      restored.restore_state(document)
      read(restored, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_CONFIGURATION_VERSION).should eq(2_u32)
    end
  end

  it "rejects a zero ConfigurationVersion when supplied" do
    expect_raises(Matter::ConfigurationError) do
      build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "bridge-invalid", configuration_version: 0_u32)
    end
  end

  describe "#increase_configuration_version" do
    it "requires the optional attribute to be provisioned" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "bridge-absent")
      expect_raises(Matter::ConfigurationError) { cluster.increase_configuration_version }
      cluster.configuration_version.should be_nil
    end

    it "advances after a completed change and wraps past UInt32::MAX to one" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "bridge-version", configuration_version: 1_u32)
      cluster.increase_configuration_version do
        cluster.node_label = "Updated"
      end
      cluster.configuration_version.should eq(2_u32)
      cluster.node_label.should eq("Updated")

      cluster.configuration_version = UInt32::MAX
      cluster.increase_configuration_version
      cluster.configuration_version.should eq(1_u32)
    end

    it "does not advance when the application change fails" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "bridge-failed", configuration_version: 4_u32)
      expect_raises(Matter::ConfigurationError) do
        cluster.increase_configuration_version do
          raise Matter::ConfigurationError.new("device rejected change")
        end
      end
      cluster.configuration_version.should eq(4_u32)
    end

    it "rejects decreasing a provisioned version outside the specified wrap" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation,
        unique_id: "bridge-monotonic", configuration_version: 7_u32)
      expect_raises(Matter::ConfigurationError) { cluster.configuration_version = 6_u32 }
      cluster.configuration_version.should eq(7_u32)

      cluster.configuration_version = UInt32::MAX
      expect_raises(Matter::ConfigurationError) { cluster.configuration_version = 2_u32 }
      cluster.configuration_version = 1_u32
      cluster.configuration_version.should eq(1_u32)
    end
  end

  describe "#attributes" do
    it "includes required Reachable attribute" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")

      attrs = cluster.attributes
      reachable_attr = attrs.find { |attr| attr.id.id == Matter::Cluster::BridgedDeviceBasicInformation::ATTR_REACHABLE }
      reachable_attr.should_not be_nil
    end

    it "includes optional attributes only when set" do
      # Without optional attributes
      cluster1 = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")
      attrs1 = cluster1.attributes
      vendor_attr1 = attrs1.find { |attr| attr.id.id == Matter::Cluster::BridgedDeviceBasicInformation::ATTR_VENDOR_NAME }
      vendor_attr1.should be_nil

      # With optional attributes
      cluster2 = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged", vendor_name: "Test")
      attrs2 = cluster2.attributes
      vendor_attr2 = attrs2.find { |attr| attr.id.id == Matter::Cluster::BridgedDeviceBasicInformation::ATTR_VENDOR_NAME }
      vendor_attr2.should_not be_nil
    end
  end

  describe "#name" do
    it "returns cluster name" do
      cluster = build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "test-bridged")
      cluster.name.should eq("BridgedDeviceBasicInformation")
    end
  end

  describe "cluster ID" do
    it "has correct cluster ID" do
      Matter::Cluster::BridgedDeviceBasicInformation::CLUSTER_ID.should eq(0x0039_u32)
    end
  end
end
