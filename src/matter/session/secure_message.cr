require "../crypto/crypto"
require "../codec/message_codec"
require "./context"

module Matter
  module Session
    # Packet framing and authenticated encryption share one serialized header.
    module SecureMessage
      extend self

      Log = ::Log.for("matter.session.secure_message")

      NONCE_LENGTH = 13
      MIC_LENGTH   = 16

      def build_nonce(source_node_id : UInt64, message_counter : UInt32, security_flags : UInt8 = 0_u8) : Bytes
        io = IO::Memory.new(NONCE_LENGTH)
        io.write_byte(security_flags)
        IO::ByteFormat::LittleEndian.encode(message_counter, io)
        IO::ByteFormat::LittleEndian.encode(source_node_id, io)
        io.to_slice
      end

      def encode(
        session : SecureContext,
        payload_header : Codec::MessageCodec::PayloadHeader,
        payload : Bytes,
        source_node_id : DataType::NodeId? = nil,
        destination_node_id : DataType::NodeId? = nil,
        message_counter : UInt32? = nil,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : {Bytes, UInt32}
        counter = message_counter || session.next_message_counter
        header = Codec::MessageCodec::PacketHeader.new(
          session_id: session.peer_session_id,
          session_type: Codec::MessageCodec::SessionType::Unicast,
          message_id: counter,
          source_node_id: source_node_id,
          destination_node_id: destination_node_id
        )
        packet = Codec::MessageCodec::Base.encode_payload(Codec::MessageCodec::Message.new(header, payload_header, payload))
        aad = Codec::MessageCodec::Base.encode_packet_header(header)
        node_id = nonce_node_id(session, session.local_node_id, source_node_id)
        nonce = build_nonce(node_id, counter, aad[Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
        Log.trace { "Encoding secure message: session_id=#{session.peer_session_id}, counter=#{counter}, nonce_node_id=0x#{node_id.to_s(16)}, aad_bytes=#{aad.size}" }
        encrypted = crypto.encrypt(session.encryption_key, packet.payload, nonce, aad)
        {Slice.join([aad, encrypted]), counter}
      end

      # Replay classification belongs to the routing layer. Only authenticated,
      # successfully decoded messages advance the session's receive window.
      #
      # The received header bytes are the additional authenticated data: the
      # peer signed exactly what it sent, including reserved flag bits, so a
      # header re-encoded from parsed fields is never an acceptable substitute.
      def decode(
        session : SecureContext,
        packet : Codec::MessageCodec::Packet,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
        advance_counter : Bool = true,
      ) : Codec::MessageCodec::Message
        aad = packet.header_bytes || raise Matter::CodecError.new("Secure message decode: received header bytes required for authentication")
        node_id = nonce_node_id(session, session.peer_node_id, packet.header.source_node_id)
        nonce = build_nonce(node_id, packet.header.message_id, aad[Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
        Log.trace { "Decoding secure message: session_id=#{session.session_id}, counter=#{packet.header.message_id}, nonce_node_id=0x#{node_id.to_s(16)}, aad_bytes=#{aad.size}" }
        plaintext = crypto.decrypt(session.decryption_key, packet.payload, nonce, aad)
        message = Codec::MessageCodec::Base.decode_payload(Codec::MessageCodec::Packet.new(packet.header, plaintext, aad))
        session.accept_peer_message_counter(packet.header.message_id) if advance_counter
        message
      end

      # The node id mixed into the AEAD nonce. CASE sessions use the session's
      # node id, falling back to the one carried in the message header, then
      # UNSPECIFIED; PASE sessions always use UNSPECIFIED.
      private def nonce_node_id(session : SecureContext, session_node_id : DataType::NodeId?, header_node_id : DataType::NodeId?) : UInt64
        return DataType::NodeId::UNSPECIFIED unless session.case_session?

        session_node_id.try(&.id) || header_node_id.try(&.id) || DataType::NodeId::UNSPECIFIED
      end
    end
  end
end
