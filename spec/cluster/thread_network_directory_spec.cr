require "../spec_helper"
require "../../src/matter/device/persistence"

private alias Directory = Matter::Cluster::ThreadNetworkDirectory

private def thread_tlv(type : UInt8, bytes : Bytes) : Bytes
  Bytes[type, bytes.size.to_u8] + bytes
end

private def thread_dataset(xpan : Bytes = Bytes[1, 2, 3, 4, 5, 6, 7, 8],
                           timestamp : UInt64 = 1_u64, name : String = "Home") : Bytes
  stamp = Bytes.new(8) { |index| ((timestamp >> ((7 - index) * 8)) & 0xff).to_u8 }
  thread_tlv(14_u8, stamp) +
    thread_tlv(0_u8, Bytes[0, 0, 15]) +
    thread_tlv(53_u8, Bytes[0, 4, 0, 0, 0, 1]) +
    thread_tlv(2_u8, xpan) +
    thread_tlv(5_u8, Bytes.new(16, 0xaa_u8)) +
    thread_tlv(7_u8, Bytes.new(8, 0xfd_u8)) +
    thread_tlv(3_u8, name.to_slice) +
    thread_tlv(1_u8, Bytes[0x12, 0x34]) +
    thread_tlv(4_u8, Bytes.new(16, 0xbb_u8)) +
    thread_tlv(12_u8, Bytes[0, 1, 0, 0])
end

private def directory : Directory
  Directory.new(Matter::DataType::EndpointNumber.new(2_u16))
end

private def add_dataset(cluster : Directory, dataset : Bytes) : Matter::InteractionModel::Status
  cluster.add_network(Directory::AddNetworkRequest.new(dataset))
end

describe Directory do
  it "advertises complete rev1 metadata with Manage and timed commands" do
    cluster = directory
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([
      Directory::ATTR_PREFERRED_EXTENDED_PAN_ID,
      Directory::ATTR_THREAD_NETWORKS,
      Directory::ATTR_THREAD_NETWORK_TABLE_SIZE,
    ])
    cluster.thread_network_table_size.should be >= 32_u8
    cluster.get_attribute_metadata(Directory::ATTR_PREFERRED_EXTENDED_PAN_ID).as(Matter::Cluster::AttributeMetadata).write_access
      .should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    [Directory::CMD_ADD_NETWORK, Directory::CMD_REMOVE_NETWORK].each do |id|
      metadata = cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata)
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      metadata.timed?.should be_true
    end
    cluster.get_command_metadata(Directory::CMD_GET_OPERATIONAL_DATASET).as(Matter::Cluster::CommandMetadata).timed?.should be_false
  end

  it "rejects missing, malformed and duplicate Thread dataset TLVs" do
    cluster = directory
    dataset = thread_dataset
    bad = [
      Bytes.new(0),
      dataset[0, dataset.size - 1],
      dataset[10, dataset.size - 10],
      dataset + thread_tlv(2_u8, Bytes[1, 2, 3, 4, 5, 6, 7, 8]),
      thread_dataset(name: ""),
    ]
    bad.each do |input|
      add_dataset(cluster, input).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end
    cluster.thread_networks.should be_empty
  end

  it "shares entries across fabrics and replaces only with a newer timestamp" do
    cluster = directory
    xpan = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    cluster.request_fabric_index = 1_u8
    add_dataset(cluster, thread_dataset(xpan, 7_u64)).status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.request_fabric_index = 2_u8
    cluster.thread_networks.map(&.network_name).should eq(["Home"])
    add_dataset(cluster, thread_dataset(xpan, 7_u64, "Old")).status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    add_dataset(cluster, thread_dataset(xpan, 6_u64, "Older")).status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    add_dataset(cluster, thread_dataset(xpan, 8_u64, "New")).status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.thread_networks.map(&.network_name).should eq(["New"])
    cluster.thread_networks.first.channel.should eq(15_u16)
    cluster.thread_networks.first.active_timestamp.should eq(8_u64)
    cluster.thread_networks.first.extended_pan_id.should eq(xpan)
  end

  it "enforces table capacity and protects the preferred network" do
    cluster = Directory.new(Matter::DataType::EndpointNumber.new(2_u16), table_size: 10_u8, supported_fabrics: 5_u8)
    10.times do |index|
      xpan = Bytes.new(8, index.to_u8)
      add_dataset(cluster, thread_dataset(xpan)).status.should eq(Matter::InteractionModel::StatusCode::Success)
    end
    add_dataset(cluster, thread_dataset(Bytes.new(8, 10_u8))).status.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
    first = Bytes.new(8, 0_u8)
    missing = Bytes.new(8, 99_u8)
    cluster.preferred_extended_pan_id = first
    cluster.remove_network(Directory::ExtendedPanIdRequest.new(first)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.remove_network(Directory::ExtendedPanIdRequest.new(missing)).status.should eq(Matter::InteractionModel::StatusCode::NotFound)
    cluster.preferred_extended_pan_id = nil
    cluster.remove_network(Directory::ExtendedPanIdRequest.new(first)).status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.thread_networks.size.should eq(9)
    cluster.preferred_extended_pan_id = Bytes.new(0)
    cluster.preferred_extended_pan_id.should be_nil
    cluster.write_attribute(Directory::ATTR_PREFERRED_EXTENDED_PAN_ID, TLV::Any.new(missing)).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "releases raw credentials only on CASE and persists the shared directory" do
    cluster = directory
    dataset = thread_dataset
    xpan = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    add_dataset(cluster, dataset).status.should eq(Matter::InteractionModel::StatusCode::Success)
    request = Directory::ExtendedPanIdRequest.new(xpan)
    cluster.get_operational_dataset(request).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.request_is_case_session = true
    cluster.get_operational_dataset(request).as(Directory::OperationalDatasetResponse).operational_dataset.should eq(dataset)
    cluster.preferred_extended_pan_id = xpan

    restored = directory
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.thread_networks.size.should eq(1)
    restored.preferred_extended_pan_id.should eq(xpan)
    restored.request_is_case_session = true
    restored.get_operational_dataset(request).as(Directory::OperationalDatasetResponse).operational_dataset.should eq(dataset)
    restored.factory_reset
    restored.thread_networks.should be_empty
    restored.preferred_extended_pan_id.should be_nil
  end

  it "survives a storage backend restart without exposing credentials in the directory attribute" do
    path = File.join(Dir.tempdir, "matter-thread-directory-#{Random::Secure.hex(6)}.yml")
    dataset = thread_dataset
    first = directory
    persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    persistence.track(first)
    add_dataset(first, dataset).status.should eq(Matter::InteractionModel::StatusCode::Success)
    first.preferred_extended_pan_id = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    persistence.save_cluster(first).should be_true
    persistence.close

    reopened = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    restored = directory
    reopened.restore_clusters([restored] of Matter::Cluster::Base).should eq(1)
    restored.thread_networks.size.should eq(1)
    restored.thread_networks.first.network_name.should eq("Home")
    restored.read_attribute(Directory::ATTR_THREAD_NETWORKS).as(TLV::Any).as_list.first.as_structure.size.should eq(4)
    restored.request_is_case_session = true
    restored.get_operational_dataset(Directory::ExtendedPanIdRequest.new(Bytes[1, 2, 3, 4, 5, 6, 7, 8]))
      .as(Directory::OperationalDatasetResponse).operational_dataset.should eq(dataset)
    reopened.close
  ensure
    File.delete?(path) if path
  end
end
