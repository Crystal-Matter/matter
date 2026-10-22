require "../spec_helper"
require "../../src/matter/device/persistence"

private alias Ecosystem = Matter::Cluster::EcosystemInformation

private def ecosystem_devices(cluster : Ecosystem, fabric : UInt8) : Array(Ecosystem::EcosystemDeviceStruct)
  cluster.device_directory(fabric).as(Array(Ecosystem::EcosystemDeviceStruct))
end

private def ecosystem_locations(cluster : Ecosystem, fabric : UInt8) : Array(Ecosystem::EcosystemLocationStruct)
  cluster.location_directory(fabric).as(Array(Ecosystem::EcosystemLocationStruct))
end

private def ecosystem_device(name : String, fabric : UInt8, locations = [] of String) : Ecosystem::EcosystemDeviceStruct
  Ecosystem::EcosystemDeviceStruct.new(
    device_name: name,
    device_name_last_edit: 42_u64,
    bridged_endpoint: 2_u16,
    original_endpoint: 1_u16,
    device_types: [Ecosystem::DeviceTypeStruct.new(0x0100_u32, 1_u16)],
    unique_location_ids: locations,
    unique_location_ids_last_edit: 42_u64,
    fabric_index: fabric
  )
end

private def ecosystem_location(id : String, fabric : UInt8) : Ecosystem::EcosystemLocationStruct
  Ecosystem::EcosystemLocationStruct.new(
    unique_location_id: id,
    location_descriptor: Ecosystem::LocationDescriptorStruct.new("Kitchen", 0_i16, nil),
    location_descriptor_last_edit: 42_u64,
    fabric_index: fabric
  )
end

describe Ecosystem do
  it "declares the Matter 1.6 read-only Manage directories" do
    cluster = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([Ecosystem::ATTR_DEVICE_DIRECTORY, Ecosystem::ATTR_LOCATION_DIRECTORY])
    cluster.commands.should be_empty
    cluster.attributes.each do |attribute|
      attribute.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      attribute.fabric_scoped?.should be_true
      attribute.writable?.should be_false
    end
  end

  it "starts with unavailable directories and rejects fabricless reads" do
    cluster = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    cluster.read_attribute(Ecosystem::ATTR_DEVICE_DIRECTORY).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    ecosystem_devices(cluster, 1_u8).should be_empty
    ecosystem_locations(cluster, 1_u8).should be_empty
  end

  it "publishes consented metadata only to its fabric and survives restart" do
    cluster = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    cluster.publish(1_u8, [ecosystem_device("Lamp", 1_u8, ["room-a"])], [ecosystem_location("room-a", 1_u8)])
    cluster.publish(2_u8, [ecosystem_device("Private", 2_u8)], [] of Ecosystem::EcosystemLocationStruct)
    ecosystem_devices(cluster, 1_u8).map(&.device_name).should eq(["Lamp"])
    ecosystem_devices(cluster, 2_u8).map(&.device_name).should eq(["Private"])
    ecosystem_locations(cluster, 1_u8).map(&.unique_location_id).should eq(["room-a"])
    ecosystem_locations(cluster, 2_u8).should be_empty

    cluster.request_is_case_session = true
    first_fabric_wire = cluster.read_attribute(Ecosystem::ATTR_DEVICE_DIRECTORY, 1_u8).as(TLV::Any).as_list
    first_fabric_wire.size.should eq(1)
    Ecosystem::EcosystemDeviceStruct.from_tlv(first_fabric_wire.first).fabric_index.should eq(1_u8)
    location_wire = cluster.read_attribute(Ecosystem::ATTR_LOCATION_DIRECTORY, 1_u8).as(TLV::Any).as_list
    location_wire.size.should eq(1)
    decoded_location = Ecosystem::EcosystemLocationStruct.from_tlv(location_wire.first)
    decoded_location.location_descriptor.floor_number.should eq(0_i16)
    decoded_location.location_descriptor.area_type.should be_nil
    cluster.request_fabric_filtered = false
    cluster.read_attribute(Ecosystem::ATTR_DEVICE_DIRECTORY, 1_u8).as(TLV::Any).as_list.size.should eq(2)

    restored = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    ecosystem_devices(restored, 1_u8).map(&.device_name).should eq(["Lamp"])
    ecosystem_devices(restored, 2_u8).map(&.device_name).should eq(["Private"])
    restored.remove_fabric(1_u8)
    ecosystem_devices(restored, 1_u8).should be_empty
    ecosystem_devices(restored, 2_u8).map(&.device_name).should eq(["Private"])
  end

  it "rejects cross-fabric records and overlong names while allowing independent locations" do
    cluster = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    expect_raises(Matter::ConfigurationError) { cluster.publish(1_u8, [ecosystem_device("Wrong", 2_u8)], [] of Ecosystem::EcosystemLocationStruct) }
    expect_raises(Matter::ConfigurationError) { cluster.publish(1_u8, [ecosystem_device("x" * 65, 1_u8)], [] of Ecosystem::EcosystemLocationStruct) }
    cluster.publish(1_u8, [] of Ecosystem::EcosystemDeviceStruct, [ecosystem_location("room-a", 1_u8)])
    ecosystem_locations(cluster, 1_u8).map(&.unique_location_id).should eq(["room-a"])
  end

  it "persists publication and erasure in a file across restart and index reuse" do
    path = File.join(Dir.tempdir, "matter-ecosystem-#{Random::Secure.hex(6)}.yml")
    installed = [1_u8, 2_u8]

    persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    cluster = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    cluster.fabric_installed = ->(index : UInt8) { installed.includes?(index) }
    persistence.track(cluster)
    cluster.publish(1_u8, [ecosystem_device("First", 1_u8)], [] of Ecosystem::EcosystemLocationStruct)
    cluster.publish(2_u8, [ecosystem_device("Second", 2_u8)], [] of Ecosystem::EcosystemLocationStruct)
    expect_raises(Matter::ConfigurationError) do
      cluster.publish(3_u8, [ecosystem_device("Unknown", 3_u8)], [] of Ecosystem::EcosystemLocationStruct)
    end
    persistence.close

    reopened = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    restored = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    restored.fabric_installed = ->(index : UInt8) { installed.includes?(index) }
    reopened.restore_clusters([restored] of Matter::Cluster::Base).should eq(1)
    ecosystem_devices(restored, 1_u8).map(&.device_name).should eq(["First"])
    ecosystem_devices(restored, 2_u8).map(&.device_name).should eq(["Second"])

    restored.remove_fabric(1_u8)
    reopened.save_cluster(restored).should be_true
    installed.delete(1_u8)
    reopened.close

    after_removal = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    reused = Ecosystem.new(Matter::DataType::EndpointNumber.new(2_u16))
    installed << 1_u8
    reused.fabric_installed = ->(index : UInt8) { installed.includes?(index) }
    after_removal.restore_clusters([reused] of Matter::Cluster::Base).should eq(1)
    ecosystem_devices(reused, 1_u8).should be_empty
    ecosystem_devices(reused, 2_u8).map(&.device_name).should eq(["Second"])
    after_removal.close
  ensure
    File.delete?(path) if path
  end
end
