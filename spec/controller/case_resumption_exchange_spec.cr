require "../spec_helper"
require "../../src/matter/controller/pairing/case_pairing"
require "../../src/matter/controller/im_client"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/protocol/secure_channel"

private class ResumeExchangeClient < Matter::Controller::Client
  getter sent_types = [] of UInt8
  property handler : Matter::Protocol::MessageHandler?
  property response_peer : Socket::IPAddress?
  @counter = 0_u32
  @encrypted_counter = 17_u32

  def initialize(@channel : Matter::Protocol::SecureChannel,
                 @capture : Matter::Spec::CaptureTransport,
                 @peer : Socket::IPAddress,
                 session_id_in_use : Proc(UInt16, Bool)? = nil)
    super(session_id_in_use: session_id_in_use)
  end

  def send_unsecured_request(peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             requires_ack : Bool = true) : UInt16
    forward(message_type, payload.to_slice)
    7_u16
  end

  def send_unsecured_on_exchange(peer : Socket::IPAddress, exchange_id : UInt16,
                                 protocol_id : UInt16, message_type : UInt8,
                                 payload : Bytes | Slice(UInt8),
                                 initiator_message : Bool = true,
                                 requires_ack : Bool = true,
                                 acknowledged_message_id : UInt32? = nil) : Nil
    forward(message_type, payload.to_slice)
  end

  def wait_for_any(exchange_id : UInt16, protocol_id : UInt16,
                   message_types : Array(UInt8), timeout : Time::Span) : ReceivedMessage?
    while sent = @capture.sent_packets.shift?
      packet = Matter::Codec::MessageCodec::Base.decode_packet(sent[0])
      message = if packet.header.session_id == 0
                  Matter::Codec::MessageCodec::Base.decode_payload(packet)
                else
                  handler = @handler.as(Matter::Protocol::MessageHandler)
                  device_session = handler.sessions.values.find do |candidate|
                    candidate.peer_session_id == packet.header.session_id
                  end.as(Matter::Session::SecureContext)
                  header_bytes = sent[0][0, sent[0].size - packet.payload.size]
                  nonce = Matter::Session::SecureMessage.build_nonce(
                    device_session.local_node_id.as(Matter::DataType::NodeId).id,
                    packet.header.message_id,
                    header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
                  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(
                    device_session.encryption_key, packet.payload, nonce, header_bytes)
                  Matter::Codec::MessageCodec::Base.decode_payload(
                    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
                end
      next unless message.payload_header.exchange_id == exchange_id
      next unless message_types.includes?(message.payload_header.message_type)
      return ReceivedMessage.new(message, @response_peer || sent[1])
    end
    nil
  end

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = next_exchange_id,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    handler = @handler.as(Matter::Protocol::MessageHandler)
    device_session = handler.sessions[session.peer_session_id]
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
      device_session, message_type, payload.to_slice, @encrypted_counter,
      exchange_id, protocol_id: protocol_id,
      requires_acknowledge: requires_ack), peer)
    @encrypted_counter &+= 1_u32
    exchange_id
  end

  private def forward(message_type : UInt8, payload : Bytes) : Nil
    @sent_types << message_type
    @counter &+= 1_u32
    message = Matter::Codec::MessageCodec::Message.new(
      Matter::Codec::MessageCodec::PacketHeader.new(0_u16,
        Matter::Codec::MessageCodec::SessionType::Unicast, @counter),
      Matter::Codec::MessageCodec::PayloadHeader.new(7_u16, 0_u16,
        message_type, true, false), payload)
    @channel.handle(message, @peer)
  end
end

describe "controller and device CASE resumption exchange" do
  it "reports a peer rejection during Sigma1 instead of timing out" do
    require_udp_sockets!
    crypto = Matter::Crypto::StandardCrypto.new
    authority = TestCertificateAuthority.new
    fabric_id = 0x1234_u64
    device_node = 0x4321_u64
    controller_node = 0x2222_u64
    device_key = crypto.create_key_pair
    controller_key = crypto.create_key_pair
    root_cert = authority.root_certificate
    device_fabric = Matter::Fabric.new(fabric_id, 1_u8, device_node,
      authority.root_public_key, authority.issue(fabric_id, device_node, device_key.public_key),
      device_key, Bytes.new(16, 0x44_u8), root_cert: root_cert)
    controller_fabric = Matter::Controller::FabricInfo.new(fabric_id, controller_node,
      Bytes.new(16, 0x45_u8), root_cert, authority.root_public_key,
      authority.issue(fabric_id, controller_node, controller_key.public_key),
      controller_key.private_key)
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    table.add_fabric(device_fabric).should be_true
    capture = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(capture)
    registry = Matter::Protocol::SessionRegistry.new(mrp_cache: cache)
    channel = Matter::Protocol::SecureChannel.new(table, registry,
      Matter::Protocol::ResponseSender.new(capture, cache), 20202021_u32,
      1000_u32, Bytes.new(32, 0x01_u8))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    client = ResumeExchangeClient.new(channel, capture, peer)
    client.response_peer = Socket::IPAddress.new("::ffff:127.0.0.1", 5540)

    expect_raises(Matter::ProtocolError, /general_status=1 protocol_status=1/) do
      Matter::Controller::Pairing::CasePairing.new(crypto).pair(client, peer,
        controller_fabric, device_node)
    end
    client.sent_types.should eq([0x30_u8])
  ensure
    client.try(&.close)
  end

  it "reconnects through real Sigma1/Sigma2Resume/Success wire messages and rotates both stores" do
    require_udp_sockets!
    crypto = Matter::Crypto::StandardCrypto.new
    authority = TestCertificateAuthority.new
    fabric_id = 0x1234_u64
    device_node = 0x4321_u64
    controller_node = 0x2222_u64
    ipk = Bytes.new(16, 0x44_u8)
    device_key = crypto.create_key_pair
    controller_key = crypto.create_key_pair
    root_cert = authority.root_certificate
    device_noc = authority.issue(fabric_id, device_node, device_key.public_key)
    controller_noc = authority.issue(fabric_id, controller_node, controller_key.public_key)
    device_fabric = Matter::Fabric.new(fabric_id, 1_u8, device_node,
      authority.root_public_key, device_noc, device_key, ipk, root_cert: root_cert)
    controller_fabric = Matter::Controller::FabricInfo.new(fabric_id, controller_node,
      ipk, root_cert, authority.root_public_key, controller_noc,
      controller_key.private_key)
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    table.add_fabric(device_fabric).should be_true
    capture = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(capture)
    registry = Matter::Protocol::SessionRegistry.new(mrp_cache: cache)
    channel = Matter::Protocol::SecureChannel.new(table, registry,
      Matter::Protocol::ResponseSender.new(capture, cache), 20202021_u32,
      1000_u32, Bytes.new(32, 0x01_u8))
    controller_backend = Matter::Storage::Memory.new
    controller_store = Matter::Session::Case::ResumptionStore.new(controller_backend)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    client = ResumeExchangeClient.new(channel, capture, peer)
    # A dual-stack UDP socket may report the IPv4 peer as IPv4-mapped IPv6.
    client.response_peer = Socket::IPAddress.new("::ffff:127.0.0.1", 5540)

    pairing = Matter::Controller::Pairing::CasePairing.new(crypto, controller_store)
    first_session = pairing.pair(client, peer, controller_fabric, device_node)
    client.sent_types.should eq([0x30_u8, 0x32_u8])
    first_session.case_session?.should be_true
    previous = controller_store.find_by_peer(fabric_id, authority.root_public_key,
      controller_node, device_node).as(Matter::Session::Case::ResumptionStore::Record)
    channel.resumption_store.find_by_id(previous.resumption_id).should_not be_nil

    # Reopen both persistent stores and discard each in-memory session. The
    # second CASE must use only the records left by the first exchange.
    client.close
    capture = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(capture)
    registry = Matter::Protocol::SessionRegistry.new(mrp_cache: cache)
    channel = Matter::Protocol::SecureChannel.new(table, registry,
      Matter::Protocol::ResponseSender.new(capture, cache), 20202021_u32,
      1000_u32, Bytes.new(32, 0x01_u8))
    controller_store = Matter::Session::Case::ResumptionStore.new(controller_backend)
    pairing = Matter::Controller::Pairing::CasePairing.new(crypto, controller_store)
    reserved_checks = 0
    client = ResumeExchangeClient.new(channel, capture, peer,
      ->(id : UInt16) { reserved_checks += 1; id == first_session.session_id })
    client.response_peer = Socket::IPAddress.new("::ffff:127.0.0.1", 5540)

    session = pairing.pair(client, peer, controller_fabric, device_node)

    reserved_checks.should be > 0
    session.session_id.should_not eq(first_session.session_id)
    client.sent_types.should eq([0x30_u8, 0x40_u8])
    session.case_session?.should be_true
    device_session = registry.session(session.peer_session_id).as(Matter::Session::SecureContext)
    session.encryption_key.should eq(device_session.decryption_key)
    session.decryption_key.should eq(device_session.encryption_key)
    controller_store.find_by_id(previous.resumption_id).should be_nil
    channel.resumption_store.find_by_id(previous.resumption_id).should be_nil
    controller_store.find_by_peer(fabric_id, authority.root_public_key,
      controller_node, device_node).as(Matter::Session::Case::ResumptionStore::Record).resumption_id
      .should eq(channel.resumption_store.find_by_peer(fabric_id, authority.root_public_key,
        device_node, controller_node).as(Matter::Session::Case::ResumptionStore::Record).resumption_id)

    # Use the resumed session for an actual encrypted Interaction Model read.
    capture.sent_packets.clear
    handler = Matter::Protocol::MessageHandler.new(capture, 20202021_u32,
      3840_u16, table)
    handler.sessions[device_session.session_id] = device_session
    client.handler = handler
    report = Matter::Controller::ImClient.new(client).read_attribute(session, peer,
      0_u16, Matter::Cluster::BasicInformation::CLUSTER_ID,
      Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME)
    report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.should_not be_nil

    # Normalizing mapped IPv4 must not admit a different network peer.
    client.response_peer = Socket::IPAddress.new("127.0.0.2", 5540)
    expect_raises(Matter::AuthenticationError, /another peer/) do
      pairing.pair(client, peer, controller_fabric, device_node)
    end
  ensure
    client.try(&.close)
    handler.try(&.close)
  end
end
