require "../../spec_helper"

require "../../../src/matter/codec/message_codec"
require "../../../src/matter/crypto/crypto"
require "../../../src/matter/datatype/node_id"
require "../../../src/matter/protocol/message_handler"
require "../../../src/matter/session/secure_message"
require "../../../src/matter/transport/udp_transport"

# Minimal transport that avoids binding OS UDP sockets in the spec environment.
class NoSocketTransportForPeerNodeIdSpec < Matter::Transport::UDPTransport
  def self.new_for_spec : self
    transport = allocate
    transport.initialize_for_spec
    transport
  end

  protected def initialize_for_spec : Nil
    initialize_reliable_messages
  end

  def send_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
  end
end

describe "CASE peer_node_id population" do
  it "populates session.peer_node_id from packet header when missing" do
    transport = NoSocketTransportForPeerNodeIdSpec.new_for_spec
    storage = Matter::Storage::Memory.new
    fabric_table = Matter::FabricTable.new(storage)

    handler = Matter::Protocol::MessageHandler.new(
      transport: transport,
      setup_pin: 20202021_u32,
      discriminator: 3840_u16,
      fabric_table: fabric_table
    )

    session_id = 1_u16
    message_counter = 5_u32

    local_node = Matter::DataType::NodeId.new(0x1111_u64)
    peer_node = Matter::DataType::NodeId.new(0x2222_u64)

    session = Matter::Session::SecureContext.new(
      session_id: session_id,
      peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x11_u8),
      decryption_key: Bytes.new(16, 0x22_u8),
      initiator: false,
      peer_node_id: nil,
      local_node_id: local_node,
      case_session: true,
      fabric_index: 1_u8
    )
    handler.sessions[session_id] = session

    packet_header = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: session_id,
      session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
      message_id: message_counter,
      privacy_enhancements: false,
      control_message: false,
      message_extensions: false,
      source_node_id: peer_node,
      destination_node_id: local_node
    )

    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 1_u16,
      protocol_id: 0x9999_u16, # Unsupported protocol (ensures no response is sent)
      message_type: 0_u8,
      initiator_message: true,
      requires_acknowledge: false
    )

    plaintext_message = Matter::Codec::MessageCodec::Message.new(
      packet_header: packet_header,
      payload_header: payload_header,
      payload: Bytes.empty
    )
    plaintext_packet = Matter::Codec::MessageCodec::Base.encode_payload(plaintext_message)
    plaintext = plaintext_packet.payload

    aad = Matter::Codec::MessageCodec::Base.encode_packet_header(packet_header)
    nonce = Matter::Session::SecureMessage.build_nonce(peer_node.id, message_counter, packet_header.security_flags)
    encrypted_payload = Matter::Crypto::StandardCrypto.new.encrypt(session.decryption_key, plaintext, nonce, aad)

    encrypted_msg = Matter::Codec::MessageCodec::Message.new(
      packet_header: packet_header,
      payload_header: payload_header,
      payload: encrypted_payload,
      header_bytes: aad
    )

    handler.handle_message(encrypted_msg, Socket::IPAddress.new("127.0.0.1", 5540))

    session.peer_node_id.should_not be_nil
    session.peer_node_id.as(Matter::DataType::NodeId).id.should eq(peer_node.id)
    session.peer_subject_ids.should eq([peer_node.id])
  end
end
