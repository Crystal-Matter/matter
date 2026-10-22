require "../spec_helper"
require "../../src/matter/device/groupcast_sender"
require "file_utils"

private alias DeviceGC = Matter::Cluster::Groupcast
private alias DeviceGKM = Matter::Cluster::GroupKeyManagement

private class GroupcastSenderDeviceForSpec < Matter::Device
  def initialize(storage : Matter::Storage::Backend)
    super(storage, port: 0, groupcast_sender: true)
  end

  def device_name : String
    "Groupcast Sender"
  end

  def vendor_id : UInt16
    0xFFF1_u16
  end

  def product_id : UInt16
    0x8001_u16
  end

  def discriminator : UInt16
    3840_u16
  end

  def setup_pin : UInt32
    20202021_u32
  end

  def primary_device_type_id : UInt32
    Matter::DeviceType::ON_OFF_LIGHT
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    [] of Matter::Cluster::Base
  end

  def release : Nil
    message_handler.close
    persistence.close
    transport.close
  end
end

private def sender_test_fabric(index : UInt8, id : UInt64) : Matter::Fabric
  Matter::Fabric.new(fabric_id: id, fabric_index: index, node_id: 0x9988_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

describe Matter::Device::GroupcastSender do
  it "advertises a working SD root cluster only when durable storage is configured" do
    require_udp_sockets!
    expect_raises(Matter::ConfigurationError, /durable storage/) do
      GroupcastSenderDeviceForSpec.new(Matter::Storage::Memory.new)
    end
    directory = File.join(Dir.tempdir, "matter-device-sender-runtime-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    device = GroupcastSenderDeviceForSpec.new(Matter::Storage::YamlFile.new(File.join(directory, "state.yml")))
    groupcast = device.node.get_cluster(DeviceGC).as(DeviceGC)
    groupcast.feature_map.should eq(DeviceGC::Feature::Sender)
    device.node.get_cluster(DeviceGKM).as(DeviceGKM).feature_map.groupcast?.should be_true
    device.access_control.feature_map.auxiliary?.should be_false
    expect_raises(Matter::ConfigurationError, /not installed/) do
      device.send_groupcast_invoke(1_u8, 0x5551_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)
    end
    device.release
  ensure
    device.try(&.release) if device && device.persistence.backend.open?
    FileUtils.rm_rf(directory) if directory
  end

  it "sends an authenticated IANA multicast command from a Sender-only membership and advances across restart" do
    directory = File.join(Dir.tempdir, "matter-device-sender-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    backend = Matter::Storage::YamlFile.new(File.join(directory, "state.yml")).tap(&.open)
    table = Matter::FabricTable.new(backend)
    fabric = sender_test_fabric(1_u8, 0x1234_5678_9abc_def0_u64)
    table.add_fabric(fabric).should be_true
    root = Matter::DataType::EndpointNumber.new(0_u16)
    keys = DeviceGKM.new(root, feature_map: DeviceGKM::Feature::Groupcast, max_groups_per_fabric: 0_u16)
    acl = Matter::Cluster::AccessControl.new(root)
    acl.acl = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE, [10_u64], nil, 1_u8)]
    groupcast = DeviceGC.new(root, keys, acl, feature_map: DeviceGC::Feature::Sender)
    groupcast.request_is_case_session = true
    groupcast.request_fabric_index = 1_u8
    groupcast.request_peer_node_id = 10_u64
    groupcast.request_peer_subject_ids = [10_u64]
    group_id = 0x5551_u16
    epoch_key = Bytes.new(16, 0xAA_u8)
    groupcast.join_group(DeviceGC::JoinGroupRequest.new(group_id, [] of UInt16,
      7_u16, key: epoch_key)).should eq(Matter::InteractionModel::Status.success)
    capture = Matter::Spec::CaptureTransport.new_for_spec
    sender = Matter::Protocol::GroupMessageSender.new(capture,
      Matter::Session::GroupOutgoingCounters.new(backend))
    outbound = Matter::Device::GroupcastSender.new(table, groupcast, keys, sender)

    outbound.invoke(1_u8, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::CMD_ON)
    first, address = capture.sent_packets.first
    address.should eq(Matter::Transport::GroupMulticast.iana_address)
    operational = Matter::Session::GroupSecurePacket.derive_operational_key(
      epoch_key, fabric.compressed_fabric_id)
    key = Matter::Session::GroupSecurePacket::Key.new(1_u8, group_id, operational, fabric.fabric_id)
    decoded = Matter::Session::GroupSecurePacket.new([key]).decode(first)
    decoded.message.packet_header.source_node_id.as(Matter::DataType::NodeId).id.should eq(fabric.node_id)
    decoded.message.payload_header.message_type.should eq(Matter::Protocol::IMHandler::MSG_INVOKE_REQUEST)
    first_counter = decoded.message.packet_header.message_id

    restarted_sender = Matter::Protocol::GroupMessageSender.new(capture,
      Matter::Session::GroupOutgoingCounters.new(backend))
    Matter::Device::GroupcastSender.new(table, groupcast, keys, restarted_sender)
      .invoke(1_u8, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON)
    second = Matter::Session::GroupSecurePacket.new([key]).decode(capture.sent_packets.last[0])
    second.message.packet_header.message_id.should be > first_counter
    expect_raises(Matter::ConfigurationError) do
      outbound.invoke(2_u8, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON)
    end
    backend.close
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "forwards only the originating CASE fabric's joined groups" do
    directory = File.join(Dir.tempdir, "matter-device-sender-fabric-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    backend = Matter::Storage::YamlFile.new(File.join(directory, "state.yml")).tap(&.open)
    table = Matter::FabricTable.new(backend)
    first_fabric = sender_test_fabric(1_u8, 0x1234_5678_9abc_def0_u64)
    second_fabric = sender_test_fabric(2_u8, 0x1234_5678_9abc_def1_u64)
    table.add_fabric(first_fabric).should be_true
    table.add_fabric(second_fabric).should be_true
    root = Matter::DataType::EndpointNumber.new(0_u16)
    keys = DeviceGKM.new(root, feature_map: DeviceGKM::Feature::Groupcast, max_groups_per_fabric: 0_u16)
    acl = Matter::Cluster::AccessControl.new(root)
    acl.acl = [1_u8, 2_u8].map do |index|
      Matter::Cluster::AccessControl::AccessControlEntry.new(
        Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        [10_u64], nil, index)
    end
    groupcast = DeviceGC.new(root, keys, acl, feature_map: DeviceGC::Feature::Sender)
    groupcast.request_is_case_session = true
    groupcast.request_peer_node_id = 10_u64
    groupcast.request_peer_subject_ids = [10_u64]
    { {1_u8, 0x5551_u16, 7_u16, Bytes.new(16, 0xAA_u8)},
     {2_u8, 0x5552_u16, 8_u16, Bytes.new(16, 0xBB_u8)} }.each do |index, group_id, key_set_id, key|
      groupcast.request_fabric_index = index
      groupcast.join_group(DeviceGC::JoinGroupRequest.new(group_id, [] of UInt16,
        key_set_id, key: key)).should eq(Matter::InteractionModel::Status.success)
    end
    capture = Matter::Spec::CaptureTransport.new_for_spec
    sender = Matter::Protocol::GroupMessageSender.new(capture,
      Matter::Session::GroupOutgoingCounters.new(backend))
    outbound = Matter::Device::GroupcastSender.new(table, groupcast, keys, sender)
    source = Matter::Cluster::OnOff.new(Matter::DataType::EndpointNumber.new(1_u16))
    source.on_state_changed do |state|
      outbound.invoke_joined_for_request(source, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON) if state && source.request_command_active? && source.request_is_case_session?
    end
    source.invoke_command(Matter::Cluster::OnOff::CMD_ON,
      is_case_session: true, fabric_index: 1_u8).should eq(Matter::InteractionModel::Status.success)
    capture.sent_packets.size.should eq(1)
    operational = Matter::Session::GroupSecurePacket.derive_operational_key(
      Bytes.new(16, 0xAA_u8), first_fabric.compressed_fabric_id)
    key = Matter::Session::GroupSecurePacket::Key.new(1_u8, 0x5551_u16,
      operational, first_fabric.fabric_id)
    decoded = Matter::Session::GroupSecurePacket.new([key]).decode(capture.sent_packets.first[0])
    decoded.message.packet_header.source_node_id.as(Matter::DataType::NodeId).id.should eq(first_fabric.node_id)

    expect_raises(Matter::ConfigurationError, /active CASE/) do
      outbound.invoke_joined_for_request(source, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON)
    end
    source.off
    source.invoke_command(Matter::Cluster::OnOff::CMD_ON).should eq(Matter::InteractionModel::Status.success)
    capture.sent_packets.size.should eq(1)
    backend.close
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end
