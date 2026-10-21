require "../spec_helper"
require "../../src/matter/device"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/groups"
require "../../src/matter/cluster/bridged_device_basic_information"

# Test device for dynamic endpoint tests
class TestBridgeDevice < Matter::Device
  def initialize(storage : Matter::Storage::Backend = Matter::Storage::Memory.new)
    super(storage)
  end

  def device_name : String
    "Test Bridge"
  end

  def vendor_id : UInt16
    0xFFF1_u16
  end

  def product_id : UInt16
    0x8000_u16
  end

  def discriminator : UInt16
    3840_u16
  end

  def setup_pin : UInt32
    20202021_u32
  end

  def primary_device_type_id : UInt32
    Matter::DeviceType::ROOT_NODE
  end

  # Bridge has no static device endpoints
  protected def device_clusters : Array(Matter::Cluster::Base)
    [] of Matter::Cluster::Base
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {} of UInt16 => UInt32
  end
end

# The mandatory server clusters of an On/Off Light (Matter Device Library,
# On/Off Light): Identify, Groups and On/Off. `add_endpoint` holds every
# endpoint to its device type, so a bridged light carries all three.
private def light_clusters(endpoint : Matter::DataType::EndpointNumber) : Array(Matter::Cluster::Base)
  [
    Matter::Cluster::OnOff.new(endpoint),
    Matter::Cluster::Identify.new(endpoint),
    Matter::Cluster::Groups.new(endpoint),
  ] of Matter::Cluster::Base
end

private def light_clusters(endpoint_id : UInt16) : Array(Matter::Cluster::Base)
  light_clusters(endpoint(endpoint_id))
end

private def add_light(device : TestBridgeDevice, endpoint_id : UInt16) : Bool
  device.add_endpoint(
    endpoint_id: endpoint_id,
    device_type: Matter::DeviceType::ON_OFF_LIGHT,
    clusters: light_clusters(endpoint_id)
  )
end

private def root_descriptor(device : TestBridgeDevice) : Matter::Cluster::Descriptor
  device.message_handler.clusters[{0_u16, Matter::Cluster::Descriptor::CLUSTER_ID}]
    .as(Matter::Cluster::Descriptor)
end

private def parts_list(device : TestBridgeDevice) : Array(UInt16)
  read_tlv(root_descriptor(device), Matter::Cluster::Descriptor::ATTR_PARTS_LIST).as_list.map do |part|
    case value = part.value
    when UInt8  then value.to_u16
    when UInt16 then value
    else             raise "Unexpected type: #{value.class}"
    end
  end
end

describe "Dynamic Endpoint Management" do
  describe "#add_endpoint" do
    it "adds a new endpoint with clusters" do
      device = TestBridgeDevice.new

      endpoint_id = 1_u16
      endpoint = endpoint(endpoint_id)

      bridged_info = Matter::Cluster::BridgedDeviceBasicInformation.new(
        endpoint,
        unique_id: "test-light-1",
        reachable: true,
        product_name: "Test Light"
      )

      result = device.add_endpoint(
        endpoint_id: endpoint_id,
        device_type: Matter::DeviceType::ON_OFF_LIGHT,
        clusters: light_clusters(endpoint) << bridged_info
      )

      result.should be_true

      # Verify clusters are registered
      device.message_handler.clusters.has_key?({endpoint_id, Matter::Cluster::OnOff::CLUSTER_ID}).should be_true
      device.message_handler.clusters.has_key?({endpoint_id, Matter::Cluster::BridgedDeviceBasicInformation::CLUSTER_ID}).should be_true

      # Verify descriptor was auto-injected
      device.message_handler.clusters.has_key?({endpoint_id, Matter::Cluster::Descriptor::CLUSTER_ID}).should be_true

      # Verify descriptor has correct device type, at the revision of the definition
      descriptor = device.node.endpoint!(endpoint_id).descriptor
      descriptor.device_type_list.size.should eq(1)
      descriptor.device_type_list[0].device_type.should eq(Matter::DeviceType::ON_OFF_LIGHT)
      descriptor.device_type_list[0].revision.should eq(Matter::DeviceType.on_off_light.revision)

      # Verify descriptor has server list populated
      descriptor.server_list.should contain(Matter::Cluster::OnOff::CLUSTER_ID)
      descriptor.server_list.should contain(Matter::Cluster::BridgedDeviceBasicInformation::CLUSTER_ID)
      descriptor.server_list.should contain(Matter::Cluster::Descriptor::CLUSTER_ID)
    end

    it "honours an explicit device type revision" do
      device = TestBridgeDevice.new

      device.add_endpoint(
        endpoint_id: 1_u16,
        device_type: Matter::DeviceType::ON_OFF_LIGHT,
        clusters: light_clusters(1_u16),
        device_type_revision: 1_u16
      ).should be_true

      device.node.endpoint!(1_u16).descriptor.device_type_list[0].revision.should eq(1_u16)
    end

    it "adds endpoint to root node parts list" do
      device = TestBridgeDevice.new

      add_light(device, 1_u16)

      # Verify root node's parts list contains the new endpoint
      root_descriptor(device).parts_list.should contain(1_u16)
    end

    it "returns false for duplicate endpoint" do
      device = TestBridgeDevice.new

      add_light(device, 1_u16).should be_true
      add_light(device, 1_u16).should be_false
    end

    it "returns false for endpoint 0" do
      device = TestBridgeDevice.new

      device.add_endpoint(
        endpoint_id: 0_u16,
        device_type: Matter::DeviceType::ON_OFF_LIGHT,
        clusters: light_clusters(0_u16)
      ).should be_false
    end

    it "raises for mismatched endpoint ID" do
      device = TestBridgeDevice.new

      expect_raises(Matter::ConfigurationError, /does not match/) do
        device.add_endpoint(
          endpoint_id: 1_u16, # Mismatched!
          device_type: Matter::DeviceType::ON_OFF_LIGHT,
          clusters: light_clusters(2_u16)
        )
      end
    end

    it "raises when the device type's mandatory clusters are missing" do
      device = TestBridgeDevice.new

      endpoint = endpoint(1)

      expect_raises(Matter::ConfigurationError, /Missing required cluster/) do
        device.add_endpoint(
          endpoint_id: 1_u16,
          device_type: Matter::DeviceType::ON_OFF_LIGHT,
          clusters: [Matter::Cluster::OnOff.new(endpoint)] of Matter::Cluster::Base
        )
      end
    end
  end

  describe "#remove_endpoint" do
    it "removes an endpoint and its clusters" do
      device = TestBridgeDevice.new

      endpoint_id = 1_u16
      endpoint = endpoint(endpoint_id)
      bridged_info = Matter::Cluster::BridgedDeviceBasicInformation.new(endpoint, unique_id: "test-light-1")

      device.add_endpoint(
        endpoint_id: endpoint_id,
        device_type: Matter::DeviceType::ON_OFF_LIGHT,
        clusters: light_clusters(endpoint) << bridged_info
      )

      # Verify clusters exist
      device.message_handler.clusters.has_key?({endpoint_id, Matter::Cluster::OnOff::CLUSTER_ID}).should be_true

      # Remove endpoint
      device.remove_endpoint(endpoint_id).should be_true

      # Verify clusters are gone
      device.message_handler.clusters.has_key?({endpoint_id, Matter::Cluster::OnOff::CLUSTER_ID}).should be_false
      device.message_handler.clusters.has_key?({endpoint_id, Matter::Cluster::BridgedDeviceBasicInformation::CLUSTER_ID}).should be_false
      device.message_handler.clusters.has_key?({endpoint_id, Matter::Cluster::Descriptor::CLUSTER_ID}).should be_false
      device.node.endpoint(endpoint_id).should be_nil
    end

    it "forgets the persisted state of every removed cluster" do
      storage = Matter::Storage::Memory.new
      device = TestBridgeDevice.new(storage)

      endpoint_id = 1_u16
      add_light(device, endpoint_id)

      on_off = device.node.endpoint!(endpoint_id).get_cluster!(Matter::Cluster::OnOff)
      device.persistence.save_cluster(on_off).should be_true
      key = Matter::Cluster::Base.persistence_key(endpoint_id, Matter::Cluster::OnOff::CLUSTER_ID)
      storage.read(Matter::Storage::Collections::CLUSTERS, key).should_not be_nil

      device.remove_endpoint(endpoint_id)

      storage.read(Matter::Storage::Collections::CLUSTERS, key).should be_nil
    end

    it "removes endpoint from root node parts list" do
      device = TestBridgeDevice.new

      endpoint_id = 1_u16
      add_light(device, endpoint_id)

      # Verify in parts list
      root_descriptor(device).parts_list.should contain(endpoint_id)

      # Remove endpoint
      device.remove_endpoint(endpoint_id)

      # Verify removed from parts list
      root_descriptor(device).parts_list.should_not contain(endpoint_id)
    end

    it "removes quietly when subscribers must not be notified" do
      device = TestBridgeDevice.new

      endpoint_id = 1_u16
      add_light(device, endpoint_id)

      device.remove_endpoint(endpoint_id, notify_subscribers: false).should be_true
      root_descriptor(device).parts_list.should_not contain(endpoint_id)
    end

    it "returns false for non-existent endpoint" do
      device = TestBridgeDevice.new
      device.remove_endpoint(99_u16).should be_false
    end

    it "returns false for endpoint 0" do
      device = TestBridgeDevice.new
      device.remove_endpoint(0_u16).should be_false
    end
  end

  describe "#endpoint_ids" do
    it "returns all non-root endpoint IDs" do
      device = TestBridgeDevice.new

      # Initially empty (only root node)
      device.endpoint_ids.should be_empty

      # Add some endpoints
      (1..3).each { |index| add_light(device, index.to_u16) }

      ids = device.endpoint_ids
      ids.size.should eq(3)
      ids.should contain(1_u16)
      ids.should contain(2_u16)
      ids.should contain(3_u16)
      ids.should_not contain(0_u16)
    end

    it "returns sorted IDs" do
      device = TestBridgeDevice.new

      [5_u16, 2_u16, 8_u16, 1_u16].each { |endpoint_id| add_light(device, endpoint_id) }

      device.endpoint_ids.should eq([1_u16, 2_u16, 5_u16, 8_u16])
    end
  end

  describe "#next_endpoint_id" do
    it "returns 1 when no endpoints exist" do
      device = TestBridgeDevice.new
      device.next_endpoint_id.should eq(1_u16)
    end

    it "returns next available ID" do
      device = TestBridgeDevice.new

      # Add endpoints 1, 2, 3
      (1..3).each { |index| add_light(device, index.to_u16) }

      device.next_endpoint_id.should eq(4_u16)
    end

    it "fills gaps in endpoint IDs" do
      device = TestBridgeDevice.new

      # Add endpoints 1, 3 (skip 2)
      [1_u16, 3_u16].each { |endpoint_id| add_light(device, endpoint_id) }

      device.next_endpoint_id.should eq(2_u16)
    end
  end

  describe "multiple endpoint operations" do
    it "supports adding and removing multiple endpoints" do
      device = TestBridgeDevice.new

      # Add 5 endpoints
      5.times { |index| add_light(device, (index + 1).to_u16) }

      device.endpoint_ids.size.should eq(5)

      # Remove some
      device.remove_endpoint(2_u16)
      device.remove_endpoint(4_u16)

      ids = device.endpoint_ids
      ids.size.should eq(3)
      ids.should eq([1_u16, 3_u16, 5_u16])

      # Add more (should fill gaps)
      device.next_endpoint_id.should eq(2_u16)

      add_light(device, 2_u16)

      device.endpoint_ids.should eq([1_u16, 2_u16, 3_u16, 5_u16])
    end
  end

  describe "subscription notifications" do
    # These tests verify the integration between dynamic endpoints and
    # subscription notifications. The actual notification delivery is tested
    # elsewhere; here we verify the flow doesn't error and state is consistent.

    it "triggers notification flow when endpoint is added" do
      device = TestBridgeDevice.new

      # This should trigger notify_subscriptions for PartsList
      # (verified by debug log: "notify_subscriptions: endpoint=0, cluster=0x1d, attr=0x3")
      add_light(device, 1_u16).should be_true

      # Verify PartsList was updated (prerequisite for notification)
      root_descriptor(device).parts_list.should contain(1_u16)
    end

    it "triggers notification flow when endpoint is removed" do
      device = TestBridgeDevice.new

      add_light(device, 1_u16)

      # This should trigger notify_subscriptions for PartsList
      device.remove_endpoint(1_u16).should be_true

      # Verify PartsList was updated (prerequisite for notification)
      root_descriptor(device).parts_list.should_not contain(1_u16)
    end

    it "can read PartsList attribute after endpoint changes" do
      device = TestBridgeDevice.new

      # Add multiple endpoints
      [1_u16, 2_u16, 3_u16].each { |endpoint_id| add_light(device, endpoint_id) }

      # Read the PartsList attribute via the cluster interface
      # (this is what a subscriber would receive in a ReportData)
      parts = parts_list(device)

      parts.should contain(1_u16)
      parts.should contain(2_u16)
      parts.should contain(3_u16)
    end

    it "correctly updates PartsList TLV when endpoints change" do
      device = TestBridgeDevice.new

      # Add endpoints
      [1_u16, 2_u16].each { |endpoint_id| add_light(device, endpoint_id) }

      # Remove one endpoint
      device.remove_endpoint(1_u16)

      # Read PartsList - should only have endpoint 2
      parts = parts_list(device)

      parts.should_not contain(1_u16)
      parts.should contain(2_u16)
    end
  end
end
