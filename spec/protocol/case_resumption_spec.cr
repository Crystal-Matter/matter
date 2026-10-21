require "../spec_helper"
require "../../src/matter/protocol/secure_channel"
require "../../src/matter/session/case/resumption_store"

private CASE_RESUME_PEER            = Socket::IPAddress.new("127.0.0.1", 5540)
private CASE_RESUME_OTHER_PEER      = Socket::IPAddress.new("127.0.0.2", 5540)
private CASE_RESUME_EXCHANGE        =      7_u16
private CASE_RESUME_CONTROLLER_NODE = 0x2222_u64

private record CaseResumeFixture,
  channel : Matter::Protocol::SecureChannel,
  registry : Matter::Protocol::SessionRegistry,
  transport : Matter::Spec::CaptureTransport,
  fabric : Matter::Fabric,
  table : Matter::FabricTable

private def case_resume_fixture : CaseResumeFixture
  crypto = Matter::Crypto::StandardCrypto.new
  authority = crypto.create_key_pair
  operational = crypto.create_key_pair
  fabric_id = 0x1234_u64
  node_id = 0x4321_u64
  noc = Matter::Crypto::MatterCertificate::Builder.node(
    public_key: operational.public_key, fabric_id: fabric_id, node_id: node_id,
    issuer_key: authority, issuer_rcac_id: 1_u64,
    serial: crypto.random_bytes(8), crypto: crypto)
  fabric = Matter::Fabric.new(fabric_id, 1_u8, node_id, authority.public_key,
    noc, operational, Bytes.new(16, 0x01_u8))
  table = Matter::FabricTable.new(Matter::Storage::Memory.new)
  table.add_fabric(fabric).should be_true
  transport = Matter::Spec::CaptureTransport.new_for_spec
  cache = Matter::Protocol::MrpCache.new(transport)
  registry = Matter::Protocol::SessionRegistry.new(mrp_cache: cache)
  channel = Matter::Protocol::SecureChannel.new(table, registry,
    Matter::Protocol::ResponseSender.new(transport, cache), 20202021_u32,
    1000_u32, Bytes.new(32, 0x01_u8))
  CaseResumeFixture.new(channel, registry, transport, fabric, table)
end

private def resumed_sigma1(fabric : Matter::Fabric, id : Bytes, secret : Bytes,
                           bad_mic : Bool = false) : Matter::Codec::MessageCodec::Message
  crypto = Matter::Crypto::StandardCrypto.new
  random = Bytes.new(32, 0x55_u8)
  mic = Matter::Session::Case.resume1_mic(crypto, secret, random, id)
  mic[0] ^= 0x01_u8 if bad_mic
  payload = Matter::Session::Case::Definitions::Sigma1.new(
    initiator_random: random, initiator_session_id: 0x1111_u16,
    destination_id: fabric.compute_destination_id(random),
    initiator_eph_pub_key: crypto.create_key_pair.public_key,
    resumption_id: id, initiator_resume_mic: mic).to_slice
  case_resume_message(Matter::Protocol::SecureChannelMessageType::CaseSigma1.value,
    payload, 1_u32)
end

private def case_resume_message(message_type : UInt8, payload : Bytes,
                                message_id : UInt32) : Matter::Codec::MessageCodec::Message
  Matter::Codec::MessageCodec::Message.new(
    Matter::Codec::MessageCodec::PacketHeader.new(0_u16,
      Matter::Codec::MessageCodec::SessionType::Unicast, message_id),
    Matter::Codec::MessageCodec::PayloadHeader.new(CASE_RESUME_EXCHANGE,
      Matter::Protocol::ProtocolId::SecureChannel.value, message_type, true, false),
    payload)
end

private def case_resume_response(fixture : CaseResumeFixture) : Matter::Codec::MessageCodec::Message
  packet = Matter::Codec::MessageCodec::Base.decode_packet(fixture.transport.sent_packets.last[0])
  Matter::Codec::MessageCodec::Base.decode_payload(packet)
end

describe "device CASE resumption" do
  it "rotates a valid resumed session only after the matching Success status" do
    fixture = case_resume_fixture
    id = Bytes.new(16, 0x11_u8)
    secret = Bytes.new(32, 0x22_u8)
    fixture.channel.resumption_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fixture.fabric.fabric_id, fixture.fabric.root_public_key, fixture.fabric.node_id,
      CASE_RESUME_CONTROLLER_NODE, id, secret, [CASE_RESUME_CONTROLLER_NODE]))

    fixture.channel.handle(resumed_sigma1(fixture.fabric, id, secret), CASE_RESUME_PEER)
    response = case_resume_response(fixture)
    response.payload_header.message_type.should eq(Matter::Protocol::SecureChannelMessageType::CaseSigma2Resume.value)
    sigma2 = Matter::Session::Case::Definitions::Sigma2Resume.from_slice(response.payload)
    Matter::Session::Case.valid_resume2_mic?(Matter::Crypto::StandardCrypto.new,
      secret, Bytes.new(32, 0x55_u8), sigma2.resumption_id, sigma2.resume_mic).should be_true
    fixture.registry.sessions.should be_empty
    fixture.channel.resumption_store.find_by_id(id).should_not be_nil

    success = Matter::Session::Pase::Definitions::StatusReport.new(0_u16, 0_u16).to_bytes
    fixture.channel.handle(case_resume_message(Matter::Protocol::SecureChannelMessageType::StatusReport.value,
      success, 2_u32), CASE_RESUME_OTHER_PEER)
    fixture.registry.sessions.should be_empty

    fixture.channel.handle(case_resume_message(Matter::Protocol::SecureChannelMessageType::StatusReport.value,
      success, 3_u32), CASE_RESUME_PEER)
    fixture.registry.sessions.keys.should eq([sigma2.responder_session_id])
    fixture.registry.sessions[sigma2.responder_session_id].peer_node_id.try(&.id)
      .should eq(CASE_RESUME_CONTROLLER_NODE)
    fixture.channel.resumption_store.find_by_id(id).should be_nil
    fixture.channel.resumption_store.find_by_id(sigma2.resumption_id).should_not be_nil

    # A copied old Sigma1 is still syntactically valid, but its old ID cannot
    # resume the rotated secret. The responder must use full certificate CASE.
    fixture.channel.handle(resumed_sigma1(fixture.fabric, id, secret), CASE_RESUME_PEER)
    case_resume_response(fixture).payload_header.message_type
      .should eq(Matter::Protocol::SecureChannelMessageType::CaseSigma2.value)
  end

  it "falls back to full Sigma2 when Resume1 MIC is invalid or belongs to another fabric" do
    fixture = case_resume_fixture
    id = Bytes.new(16, 0x11_u8)
    secret = Bytes.new(32, 0x22_u8)
    fixture.channel.resumption_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fixture.fabric.fabric_id, fixture.fabric.root_public_key, fixture.fabric.node_id,
      CASE_RESUME_CONTROLLER_NODE, id, secret, [CASE_RESUME_CONTROLLER_NODE]))

    fixture.channel.handle(resumed_sigma1(fixture.fabric, id, secret, bad_mic: true), CASE_RESUME_PEER)
    case_resume_response(fixture).payload_header.message_type
      .should eq(Matter::Protocol::SecureChannelMessageType::CaseSigma2.value)
    fixture.channel.resumption_store.find_by_id(id).should_not be_nil
  end

  it "does not resume a record bound to another root or peer" do
    fixture = case_resume_fixture
    id = Bytes.new(16, 0x11_u8)
    secret = Bytes.new(32, 0x22_u8)
    fixture.channel.resumption_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fixture.fabric.fabric_id, Bytes.new(65, 0x99_u8), fixture.fabric.node_id,
      CASE_RESUME_CONTROLLER_NODE + 1_u64, id, secret,
      [CASE_RESUME_CONTROLLER_NODE + 1_u64]))

    fixture.channel.handle(resumed_sigma1(fixture.fabric, id, secret), CASE_RESUME_PEER)
    case_resume_response(fixture).payload_header.message_type
      .should eq(Matter::Protocol::SecureChannelMessageType::CaseSigma2.value)
    fixture.registry.sessions.should be_empty
  end

  it "deletes resumption records when their fabric is removed" do
    fixture = case_resume_fixture
    id = Bytes.new(16, 0x11_u8)
    fixture.channel.resumption_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fixture.fabric.fabric_id, fixture.fabric.root_public_key, fixture.fabric.node_id,
      CASE_RESUME_CONTROLLER_NODE, id, Bytes.new(32, 0x22_u8),
      [CASE_RESUME_CONTROLLER_NODE]))
    fixture.table.remove_fabric(fixture.fabric.fabric_index).should be_true
    fixture.channel.resumption_store.find_by_id(id).should be_nil
  end

  it "bounds pending resumed handshakes across peers" do
    fixture = case_resume_fixture
    id = Bytes.new(16, 0x11_u8)
    secret = Bytes.new(32, 0x22_u8)
    fixture.channel.resumption_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fixture.fabric.fabric_id, fixture.fabric.root_public_key, fixture.fabric.node_id,
      CASE_RESUME_CONTROLLER_NODE, id, secret, [CASE_RESUME_CONTROLLER_NODE]))
    sigma1 = resumed_sigma1(fixture.fabric, id, secret)

    (Matter::Protocol::SecureChannel::MAX_HANDSHAKES_IN_FLIGHT + 1).times do |index|
      fixture.channel.handle(sigma1,
        Socket::IPAddress.new("127.0.0.1", 6000 + index))
    end

    fixture.channel.handshakes_in_flight.should eq(Matter::Protocol::SecureChannel::MAX_HANDSHAKES_IN_FLIGHT)
    fixture.registry.sessions.should be_empty
  end
end
