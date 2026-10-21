require "../spec_helper"
require "../../src/matter/device"

private class CheckInSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "ICD Check-In Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8126_u16,
    discriminator: 3844_u16, pin: 20202097_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory
end

describe Matter::Device do
  it "sends a durable, unsecured Secure Channel Check-In to a resolved registered client" do
    require_udp_sockets!
    listener = UDPSocket.new(Socket::Family::INET6)
    listener.bind("::1", 0)
    listener.read_timeout = 1.second
    storage = Matter::Storage::Memory.new
    config = Matter::Cluster::IcdManagement::Configuration.new(
      feature_map: Matter::Cluster::IcdManagement::Feature::CheckInProtocolSupport,
      idle_mode_duration: 60_u32, active_mode_duration: 3_000_u32,
      active_mode_threshold: 5_000_u16)
    device = CheckInSpecDevice.new(storage: storage, port: 0, icd_configuration: config)
    icd = device.icd_management.as(Matter::Cluster::IcdManagement)
    key = Bytes.new(16, 0x45_u8)
    registration = Matter::Cluster::IcdManagement::RegisterClientRequest.new(
      0x1234_u64, 0x1234_u64, key, nil,
      Matter::Cluster::IcdManagement::ClientType::Permanent)
    icd.invoke_command(Matter::Cluster::IcdManagement::CMD_REGISTER_CLIENT,
      registration.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .should be_a(Matter::Cluster::CommandResponse)
    device.icd_peer_resolver = ->(fabric : UInt8, node : UInt64) do
      (fabric == 1_u8 && node == 0x1234_u64) ? listener.local_address : nil
    end

    device.icd_enter_idle_mode
    device.icd_request_active_mode
    datagram, _ = listener.receive
    packet = Matter::Codec::MessageCodec::Base.decode_packet(datagram.to_slice)
    message = Matter::Codec::MessageCodec::Base.decode_payload(packet)
    packet.header.session_id.should eq(0_u16)
    message.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::SecureChannel.value)
    message.payload_header.message_type.should eq(Matter::Protocol::SecureChannelMessageType::IcdCheckIn.value)
    decoded = Matter::Protocol::Icd::CheckInMessage.decode(key, message.payload)
    decoded.counter.should eq(icd.icd_counter)
    decoded.application_data.should eq(Bytes[0x88_u8, 0x13_u8])

    state = storage.read(Matter::Device::Persistence::CLUSTERS, icd.persistence_key)
    saved = Matter::Cluster::IcdManagement.new(configuration: config)
    saved.restore_state(state.as(Matter::Storage::Document))
    saved.icd_counter.should be > decoded.counter
  ensure
    listener.try(&.close)
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end

  it "keeps a registered key across restart and erases it on fabric removal" do
    require_udp_sockets!
    storage = Matter::Storage::Memory.new
    config = Matter::Cluster::IcdManagement::Configuration.new(
      feature_map: Matter::Cluster::IcdManagement::Feature::CheckInProtocolSupport)
    first = CheckInSpecDevice.new(storage: storage, port: 0, icd_configuration: config)
    fabric = Matter::Fabric.new(
      fabric_id: 0x1234_u64, fabric_index: 1_u8, node_id: 0x5678_u64,
      root_public_key: Random::Secure.random_bytes(65),
      operational_cert: Random::Secure.random_bytes(200),
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: Random::Secure.random_bytes(16))
    first.fabric_table.add_fabric(fabric).should be_true
    key = Bytes.new(16, 0x23_u8)
    registration = Matter::Cluster::IcdManagement::RegisterClientRequest.new(
      0x1234_u64, 0x1234_u64, key, nil,
      Matter::Cluster::IcdManagement::ClientType::Permanent)
    first.icd_management.as(Matter::Cluster::IcdManagement).invoke_command(
      Matter::Cluster::IcdManagement::CMD_REGISTER_CLIENT, registration.to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8).should be_a(Matter::Cluster::CommandResponse)
    before_restart = first.icd_management.as(Matter::Cluster::IcdManagement).icd_counter
    first.message_handler.close
    first.persistence.close
    first.transport.close

    second = CheckInSpecDevice.new(storage: storage, port: 0, icd_configuration: config)
    restored = second.icd_management.as(Matter::Cluster::IcdManagement)
    restored.check_in_key(1_u8, 0x1234_u64).should eq(key)
    restored.icd_counter.should be > before_restart
    second.fabric_table.remove_fabric(1_u8).should be_true
    second.operational_credentials.on_fabric_removed.try(&.call(1_u8))
    restored.check_in_key(1_u8, 0x1234_u64).should be_nil
    second.message_handler.close
    second.persistence.close
    second.transport.close

    third = CheckInSpecDevice.new(storage: storage, port: 0, icd_configuration: config)
    third.icd_management.as(Matter::Cluster::IcdManagement).check_in_key(1_u8, 0x1234_u64)
      .should be_nil
  ensure
    if third
      third.message_handler.close
      third.persistence.close
      third.transport.close
    end
    if second
      second.message_handler.close
      second.persistence.close
      second.transport.close
    end
    if first
      first.message_handler.close
      first.persistence.close
      first.transport.close
    end
  end
end
