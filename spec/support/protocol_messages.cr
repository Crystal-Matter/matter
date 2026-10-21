require "../../src/matter/codec/message_codec"
require "../../src/matter/crypto/crypto"
require "../../src/matter/protocol/message_type"
require "../../src/matter/session/secure_message"

module Matter
  module Spec
    # Builders for the encrypted messages a controller would send, so protocol
    # specs can drive `MessageHandler#handle_message` over the real path.
    module ProtocolMessages
      extend self

      # A CASE session as the node would hold it after commissioning.
      def case_session(session_id : UInt16) : Session::SecureContext
        Session::SecureContext.new(
          session_id: session_id,
          peer_session_id: session_id &+ 1_u16,
          session_type: Session::SessionType::Unicast,
          encryption_key: Bytes.new(16, 0x11_u8),
          decryption_key: Bytes.new(16, 0x22_u8),
          initiator: false,
          peer_node_id: DataType::NodeId.new(0x2222_u64),
          local_node_id: DataType::NodeId.new(0x1111_u64),
          case_session: true,
          fabric_index: 1_u8
        )
      end

      # Encrypts *payload* as though the peer of *session* had sent it.
      def from_peer(
        session : Session::SecureContext,
        message_type : UInt8,
        payload : Bytes,
        message_counter : UInt32,
        exchange_id : UInt16,
        protocol_id : UInt16 = Protocol::ProtocolId::InteractionModel.value,
        requires_acknowledge : Bool = true,
        initiator_message : Bool = true,
      ) : Codec::MessageCodec::Message
        peer_node = session.peer_node_id.as(DataType::NodeId)

        packet_header = Codec::MessageCodec::PacketHeader.new(
          session_id: session.session_id,
          session_type: Codec::MessageCodec::SessionType::Unicast,
          message_id: message_counter,
          privacy_enhancements: false,
          control_message: false,
          message_extensions: false,
          source_node_id: peer_node,
          destination_node_id: session.local_node_id
        )

        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange_id,
          protocol_id: protocol_id,
          message_type: message_type,
          initiator_message: initiator_message,
          requires_acknowledge: requires_acknowledge
        )

        plaintext = Codec::MessageCodec::Base.encode_payload(
          Codec::MessageCodec::Message.new(packet_header, payload_header, payload)
        ).payload

        aad = Codec::MessageCodec::Base.encode_packet_header(packet_header)
        nonce = Session::SecureMessage.build_nonce(peer_node.id, message_counter, packet_header.security_flags)
        encrypted = Crypto::StandardCrypto.new.encrypt(session.decryption_key, plaintext, nonce, aad)

        Codec::MessageCodec::Message.new(
          packet_header: packet_header,
          payload_header: payload_header,
          payload: encrypted,
          header_bytes: aad
        )
      end

      # A StatusResponse carrying *status*, as a controller sends between
      # ReportData chunks.
      def status_response(
        session : Session::SecureContext,
        message_counter : UInt32,
        exchange_id : UInt16,
        status : UInt8 = InteractionModel::StatusCode::Success.value,
      ) : Codec::MessageCodec::Message
        from_peer(
          session,
          InteractionModel::MessageType::StatusResponse.value,
          InteractionModel::StatusResponseMessage.new(status: status).to_slice,
          message_counter: message_counter,
          exchange_id: exchange_id
        )
      end

      # A bare MRP acknowledgement, which is what iOS sends between chunks.
      def standalone_ack(
        session : Session::SecureContext,
        message_counter : UInt32,
        exchange_id : UInt16,
      ) : Codec::MessageCodec::Message
        from_peer(
          session,
          Protocol::SecureChannelMessageType::StandaloneAck.value,
          Bytes.empty,
          message_counter: message_counter,
          exchange_id: exchange_id,
          protocol_id: Protocol::ProtocolId::SecureChannel.value,
          requires_acknowledge: false
        )
      end

      # The Interaction Model message type of an encrypted packet the node sent
      # on *session*, or `nil` when it is not an Interaction Model message.
      def decode_message_type(packet_bytes : Bytes, session : Session::SecureContext) : UInt8?
        packet = Codec::MessageCodec::Base.decode_packet(packet_bytes)
        header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
        nonce = Session::SecureMessage.build_nonce(
          session.local_node_id.as(DataType::NodeId).id,
          packet.header.message_id,
          header_bytes[Codec::MessageCodec::SECURITY_FLAGS_OFFSET]
        )
        plaintext = Crypto::StandardCrypto.new.decrypt(session.encryption_key, packet.payload, nonce, header_bytes)
        message = Codec::MessageCodec::Base.decode_payload(Codec::MessageCodec::Packet.new(packet.header, plaintext))
        return unless message.payload_header.protocol_id == Protocol::ProtocolId::InteractionModel.value

        message.payload_header.message_type
      end
    end
  end
end
