require "../spec_helper"
require "../../src/matter/controller/icd_client"
require "../../src/matter/device"

private class ControllerCheckInSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Controller ICD Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8127_u16,
    discriminator: 3845_u16, pin: 20202098_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory
end

describe Matter::Controller::IcdClient do
  it "accepts a later authenticated Check-In after the device's packet counter resets" do
    require_udp_sockets!
    controller = Matter::Controller::Client.new(port: 0)
    sender = UDPSocket.new(Socket::Family::INET6)
    sender.bind("::1", 0)
    store = Matter::Controller::IcdPeerStore.new(Matter::Storage::Memory.new)
    key = Bytes.new(16, 0x35_u8)
    store.save(Matter::Controller::IcdPeerStore::Record.new(
      0x1111_u64, Bytes.new(65, 0x46_u8), 0x2222_u64,
      0x3333_u64, key, 100_u32, 100_u32))
    receiver = Matter::Controller::IcdClient.new(controller, store)
    deliveries = Channel(UInt32).new(2)
    receiver.on_check_in = ->(check_in : Matter::Controller::IcdClient::CheckIn) do
      deliveries.send(check_in.counter)
    end
    peer = Socket::IPAddress.new("::1", controller.transport.port)
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 1_u16,
      protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
      message_type: Matter::Protocol::SecureChannelMessageType::IcdCheckIn.value,
      initiator_message: true, requires_acknowledge: false)
    [{0xF000_0000_u32, 101_u32}, {1_u32, 102_u32}].each do |packet_counter, icd_counter|
      packet_header = Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: packet_counter)
      payload = Matter::Protocol::Icd::CheckInMessage.encode_icd(key, icd_counter, 500_u16)
      sender.send(Matter::Codec::MessageCodec::Base.encode_message(
        packet_header, payload_header, payload), peer)
      received = select
      when result = deliveries.receive
        result
      when timeout(2.seconds)
        raise "controller dropped a valid ICD Check-In after packet counter reset"
      end
      received.should eq(icd_counter)
    end
  ensure
    receiver.try(&.close)
    controller.try(&.close)
    sender.try(&.close)
  end

  it "delivers a real Crystal ICD UDP Check-In with a persistent fabric-bound identity" do
    require_udp_sockets!
    backend = Matter::Storage::Memory.new
    controller = Matter::Controller::Client.new(port: 0)
    store = Matter::Controller::IcdPeerStore.new(backend)
    key = Bytes.new(16, 0x35_u8)
    root = Bytes.new(65, 0x46_u8)
    store.save(Matter::Controller::IcdPeerStore::Record.new(
      0x1111_u64, root, 0x2222_u64, 0x3333_u64, key))
    receiver = Matter::Controller::IcdClient.new(controller, store)
    deliveries = Channel(Matter::Controller::IcdClient::CheckIn).new(1)
    receiver.on_check_in = ->(check_in : Matter::Controller::IcdClient::CheckIn) do
      deliveries.send(check_in)
    end
    config = Matter::Cluster::IcdManagement::Configuration.new(
      feature_map: Matter::Cluster::IcdManagement::Feature::CheckInProtocolSupport,
      idle_mode_duration: 60_u32, active_mode_duration: 3_000_u32,
      active_mode_threshold: 5_000_u16)
    device = ControllerCheckInSpecDevice.new(port: 0, icd_configuration: config)
    cluster = device.icd_management.as(Matter::Cluster::IcdManagement)
    registration = Matter::Cluster::IcdManagement::RegisterClientRequest.new(
      0x2222_u64, 0x2222_u64, key, nil,
      Matter::Cluster::IcdManagement::ClientType::Permanent)
    cluster.invoke_command(Matter::Cluster::IcdManagement::CMD_REGISTER_CLIENT,
      registration.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .should be_a(Matter::Cluster::CommandResponse)
    peer = Socket::IPAddress.new("::1", controller.transport.port)
    device.icd_peer_resolver = ->(fabric : UInt8, node : UInt64) do
      (fabric == 1_u8 && node == 0x2222_u64) ? peer : nil
    end
    device.icd_enter_idle_mode
    device.icd_request_active_mode
    received = select
    when result = deliveries.receive
      result
    when timeout(2.seconds)
      raise "controller did not receive ICD Check-In"
    end
    received.device_node_id.should eq(0x3333_u64)
    received.counter.should eq(cluster.icd_counter)
    received.active_mode_threshold.should eq(5_000_u16)
    Matter::Controller::IcdPeerStore.new(backend).find_peer(
      0x1111_u64, root, 0x2222_u64, 0x3333_u64)
      .as(Matter::Controller::IcdPeerStore::Record).last_counter.should eq(received.counter)
  ensure
    receiver.try(&.close)
    controller.try(&.close)
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end
end
