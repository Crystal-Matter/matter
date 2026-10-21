require "../spec_helper"
require "file_utils"

describe Matter::Protocol::GroupMessageSender do
  it "sends an untimed response-suppressed group WriteRequest with no endpoint or data version" do
    directory = File.join(Dir.tempdir, "matter-group-write-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    begin
      store = Matter::Storage::YamlFile.new(File.join(directory, "state.yml")).tap(&.open)
      transport = Matter::Spec::CaptureTransport.new_for_spec
      sender = Matter::Protocol::GroupMessageSender.new(transport,
        Matter::Session::GroupOutgoingCounters.new(store))
      fabric_id = 0x1234_5678_9abc_def0_u64
      key = Matter::Session::GroupSecurePacket::Key.new(1_u8, 0x0101_u16, Bytes.new(16, 0x11_u8), fabric_id)
      attribute = Matter::InteractionModel::AttributeDataIB.new(
        Matter::InteractionModel::AttributePath.new(nil, Matter::Cluster::LevelControl::CLUSTER_ID,
          Matter::Cluster::LevelControl::ATTR_OPTIONS), TLV::Any.new(1_u8, nil))

      expect_raises(ArgumentError, /not bound/) do
        sender.write(fabric_id + 1_u64, 1_u8, 0x2222_u64, key, [attribute])
      end
      invalid_path = Matter::InteractionModel::AttributeDataIB.new(
        Matter::InteractionModel::AttributePath.new(1_u16, Matter::Cluster::LevelControl::CLUSTER_ID,
          Matter::Cluster::LevelControl::ATTR_OPTIONS), TLV::Any.new(1_u8, nil))
      expect_raises(ArgumentError, /omit/) do
        sender.write(fabric_id, 1_u8, 0x2222_u64, key, [invalid_path])
      end
      sender.write(fabric_id, 1_u8, 0x2222_u64, key, [attribute])
      packet, address = transport.sent_packets.first
      address.should eq(Matter::Transport::GroupMulticast.address(fabric_id, key.group_id.id))
      decoded = Matter::Session::GroupSecurePacket.new([key]).decode(packet)
      decoded.message.payload_header.message_type.should eq(Matter::Protocol::IMHandler::MSG_WRITE_REQUEST)
      request = Matter::InteractionModel::WriteRequestMessage.from_slice(decoded.message.payload)
      request.suppress_response.should be_true
      request.timed_request.should be_false
      request.write_requests.as(Array(Matter::InteractionModel::AttributeDataIB)).first.path.endpoint.should be_nil
      store.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "emits an authenticated private one-way multicast InvokeRequest" do
    directory = File.join(Dir.tempdir, "matter-group-send-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    begin
      store = Matter::Storage::YamlFile.new(File.join(directory, "state.yml")).tap(&.open)
      counters = Matter::Session::GroupOutgoingCounters.new(store)
      transport = Matter::Spec::CaptureTransport.new_for_spec
      sender = Matter::Protocol::GroupMessageSender.new(transport, counters)
      fabric_id = 0x1234_5678_9abc_def0_u64
      key = Matter::Session::GroupSecurePacket::Key.new(1_u8, 0x0101_u16, Bytes.new(16, 0x11_u8), fabric_id)
      command = Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(nil, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON))

      expect_raises(ArgumentError, /not bound/) do
        sender.invoke(0x1234_5678_9abc_def1_u64, 1_u8, 0x2222_u64, key, [command])
      end
      sender.invoke(fabric_id, 1_u8, 0x2222_u64, key, [command])
      transport.sent_packets.size.should eq(1)
      packet, address = transport.sent_packets.first
      address.address.should eq("ff35:40:fd12:3456:789a:bcde:f000:101")
      address.port.should eq(5540)
      (packet[3] & 0x80).should eq(0x80)
      decoded = Matter::Session::GroupSecurePacket.new([key]).decode(packet)
      decoded.message.payload_header.requires_acknowledge?.should be_false
      request = Matter::InteractionModel::InvokeRequestMessage.from_slice(decoded.message.payload)
      request.suppress_response.should be_true
      request.invoke_requests.first.command_path.command.should eq(Matter::Cluster::OnOff::CMD_ON)
      request.invoke_requests.first.command_path.endpoint.should be_nil
      store.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
