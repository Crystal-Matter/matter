require "../spec_helper"
require "../../src/matter/controller"
require "file_utils"

private def group_invoker_fabric(store : Matter::Controller::StateStore,
                                 client : Matter::Controller::Client) : Matter::Controller::FabricInfo
  fabric = Matter::Controller::Commissioning::Commissioner.new(store, client)
    .create_fabric(controller_node_id: 0x321_u64)
  state = store.load
  state.install_fabric(fabric)
  store.save(state)
  fabric
end

describe Matter::Controller::GroupInvoker do
  it "uses an installed fabric-scoped epoch key and a durable counter" do
    directory = File.join(Dir.tempdir, "matter-controller-group-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    begin
      backend = Matter::Storage::YamlFile.new(File.join(directory, "state.yml"))
      store = Matter::Controller::StateStore.new(backend)
      client = Matter::Controller::Client.new
      fabric = group_invoker_fabric(store, client)
      capture = Matter::Spec::CaptureTransport.new_for_spec
      sender = Matter::Protocol::GroupMessageSender.new(capture,
        Matter::Session::GroupOutgoingCounters.new(backend))
      invoker = Matter::Controller::GroupInvoker.new(client, store, sender)
      group_id = 0x5551_u16
      epoch_key = Bytes.new(16, 0x11_u8)
      invoker.install_epoch_key(fabric.fabric_id, fabric.root_public_key, group_id, epoch_key)
      invoker.invoke(fabric.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON, root_public_key: fabric.root_public_key)

      capture.sent_packets.size.should eq(1)
      packet, address = capture.sent_packets.first
      address.should eq(Matter::Transport::GroupMulticast.address(fabric.fabric_id, group_id))
      compressed = Bytes.new(8)
      IO::ByteFormat::BigEndian.encode(fabric.compressed_fabric_id, compressed)
      key_bytes = Matter::Session::GroupSecurePacket.derive_operational_key(epoch_key, compressed)
      key = Matter::Session::GroupSecurePacket::Key.new(1_u8, group_id, key_bytes, fabric.fabric_id)
      decoded = Matter::Session::GroupSecurePacket.new([key]).decode(packet)
      decoded.message.packet_header.source_node_id.as(Matter::DataType::NodeId).id.should eq(fabric.controller_node_id)
      request = Matter::InteractionModel::InvokeRequestMessage.from_slice(decoded.message.payload)
      request.suppress_response.should be_true
      request.invoke_requests.first.command_path.endpoint.should be_nil

      first_counter = decoded.message.packet_header.message_id
      restarted_sender = Matter::Protocol::GroupMessageSender.new(capture,
        Matter::Session::GroupOutgoingCounters.new(backend))
      restarted = Matter::Controller::GroupInvoker.new(client, store, restarted_sender)
      restarted.invoke(fabric.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON, root_public_key: fabric.root_public_key)
      second = Matter::Session::GroupSecurePacket.new([key]).decode(capture.sent_packets.last[0])
      second.message.packet_header.message_id.should be > first_counter
      client.close
      backend.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "refuses missing keys and identities from another fabric" do
    directory = File.join(Dir.tempdir, "matter-controller-group-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    begin
      backend = Matter::Storage::YamlFile.new(File.join(directory, "state.yml"))
      store = Matter::Controller::StateStore.new(backend)
      client = Matter::Controller::Client.new
      fabric = group_invoker_fabric(store, client)
      capture = Matter::Spec::CaptureTransport.new_for_spec
      sender = Matter::Protocol::GroupMessageSender.new(capture,
        Matter::Session::GroupOutgoingCounters.new(backend))
      invoker = Matter::Controller::GroupInvoker.new(client, store, sender)
      group_id = 0x5551_u16
      expect_raises(Matter::ConfigurationError) do
        invoker.invoke(fabric.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
          Matter::Cluster::OnOff::CMD_ON)
      end
      expect_raises(Matter::ConfigurationError) do
        invoker.install_epoch_key(fabric.fabric_id, Bytes.new(65, 0x04_u8), group_id,
          Bytes.new(16, 0x11_u8))
      end
      capture.sent_packets.should be_empty
      client.close
      backend.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "keeps one Group ID's keys distinct across fabrics and purges a removed fabric" do
    directory = File.join(Dir.tempdir, "matter-controller-group-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    begin
      backend = Matter::Storage::YamlFile.new(File.join(directory, "state.yml"))
      store = Matter::Controller::StateStore.new(backend)
      client = Matter::Controller::Client.new
      first = group_invoker_fabric(store, client)
      second = Matter::Controller::Commissioning::Commissioner.new(store, client)
        .create_fabric(controller_node_id: 0x322_u64)
      state = store.load
      state.install_fabric(second)
      store.save(state)
      capture = Matter::Spec::CaptureTransport.new_for_spec
      sender = Matter::Protocol::GroupMessageSender.new(capture,
        Matter::Session::GroupOutgoingCounters.new(backend))
      invoker = Matter::Controller::GroupInvoker.new(client, store, sender)
      group_id = 0x5551_u16
      invoker.install_epoch_key(first.fabric_id, first.root_public_key, group_id, Bytes.new(16, 0x11_u8))
      invoker.install_epoch_key(second.fabric_id, second.root_public_key, group_id, Bytes.new(16, 0x22_u8))
      store.load.group_keys.size.should eq(2)
      invoker.invoke(second.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON)
      capture.sent_packets.last[1].should eq(Matter::Transport::GroupMulticast.address(second.fabric_id, group_id))

      state = store.load
      state.remove_fabric(first.fabric_id)
      store.save(state)
      store.load.group_keys.map(&.fabric_id).should eq([second.fabric_id])
      expect_raises(Matter::ConfigurationError) do
        invoker.invoke(first.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
          Matter::Cluster::OnOff::CMD_ON)
      end
      invoker.invoke(second.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
        Matter::Cluster::OnOff::CMD_ON)
      capture.sent_packets.size.should eq(2)
      client.close
      backend.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
