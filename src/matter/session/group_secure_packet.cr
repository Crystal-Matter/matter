require "../codec/message_codec"
require "../codec/message_privacy"
require "../crypto/crypto"
require "../transport/message_counter"
require "./secure_message"

module Matter
  module Session
    # Authenticated group packet processing for installed, mapped operational
    # keys. The runtime must supply candidates and persist outbound counters.
    class GroupSecurePacket
      GROUP_SECURITY_INFO   = "GroupKey v1.0".to_slice
      GROUP_SESSION_INFO    = "GroupKeyHash".to_slice
      DATA_PEER_CAPACITY    = 10
      CONTROL_PEER_CAPACITY =  2

      class NoAvailableKey < Matter::AuthenticationError
        getter fabric_index : UInt8?
        getter group_id : UInt16?

        def initialize(message : String? = nil, @fabric_index : UInt8? = nil,
                       @group_id : UInt16? = nil)
          super(message || "No mapped operational group key could process the packet")
        end
      end

      class FailedAuth < Matter::AuthenticationError
      end

      class Replay < Matter::SessionError
        getter fabric_index : UInt8
        getter group_id : UInt16

        def initialize(message : String? = nil, @fabric_index : UInt8 = 0_u8,
                       @group_id : UInt16 = 0_u16)
          super(message || "Duplicate or stale group message")
        end
      end

      struct Key
        getter fabric_index : UInt8
        getter fabric_id : UInt64?
        getter group_id : DataType::GroupId
        getter operational_key : Bytes
        getter session_id : UInt16
        getter privacy_key : Bytes

        def initialize(@fabric_index : UInt8, group_id : UInt16, @operational_key : Bytes,
                       @fabric_id : UInt64? = nil)
          raise Matter::SessionError.new("Group key requires a fabric") if @fabric_index == 0
          raise Matter::SessionError.new("Fabric ID zero is reserved") if @fabric_id == 0_u64
          raise Matter::SessionError.new("Group ID zero is reserved") if group_id == 0
          raise Matter::SessionError.new("Operational group key must be 16 bytes") unless @operational_key.size == 16
          @group_id = DataType::GroupId.new(group_id)
          @session_id = GroupSecurePacket.session_id(@operational_key)
          @privacy_key = Codec::MessagePrivacy.derive_key(@operational_key)
        end
      end

      struct Decoded
        getter fabric_index : UInt8
        getter message : Codec::MessageCodec::Message

        def initialize(@fabric_index : UInt8, @message : Codec::MessageCodec::Message)
        end
      end

      @reception : Hash(Tuple(UInt8, UInt64, Bool), Transport::MessageCounter)

      def initialize(@keys : Array(Key),
                     @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        @reception = Hash(Tuple(UInt8, UInt64, Bool), Transport::MessageCounter).new
      end

      # Refresh installed epoch keys while preserving replay windows. A key
      # rotation must never make an old counter acceptable again in this boot.
      def keys=(@keys : Array(Key)) : Nil
      end

      def self.derive_operational_key(epoch_key : Bytes, compressed_fabric_id : Bytes) : Bytes
        raise Matter::SessionError.new("Epoch key must be 16 bytes") unless epoch_key.size == 16
        raise Matter::SessionError.new("Compressed fabric ID must be 8 bytes") unless compressed_fabric_id.size == 8
        Crypto.create_hkdf_key(epoch_key, compressed_fabric_id, GROUP_SECURITY_INFO, 16)
      end

      def self.session_id(operational_key : Bytes) : UInt16
        raise Matter::SessionError.new("Operational group key must be 16 bytes") unless operational_key.size == 16
        hash = Crypto.create_hkdf_key(operational_key, Bytes.empty, GROUP_SESSION_INFO, 2)
        IO::ByteFormat::BigEndian.decode(UInt16, hash)
      end

      # `counter` must come from a node-global durable group data/control
      # counter. Reuse of a counter with this key and source would repeat a nonce.
      def encode(key : Key, source_node_id : UInt64, counter : UInt32,
                 payload_header : Codec::MessageCodec::PayloadHeader, payload : Bytes,
                 control : Bool = false) : Bytes
        raise Matter::SessionError.new("Group key is not installed") unless @keys.includes?(key)
        raise Matter::SessionError.new("Source Node ID is required") if source_node_id == 0
        header = Codec::MessageCodec::PacketHeader.new(
          session_id: key.session_id,
          session_type: Codec::MessageCodec::SessionType::Group,
          message_id: counter,
          privacy_enhancements: true,
          control_message: control,
          source_node_id: DataType::NodeId.new(source_node_id),
          destination_group_id: key.group_id)
        clear_header = Codec::MessageCodec::Base.encode_packet_header(header)
        application = Codec::MessageCodec::Base.encode_payload(
          Codec::MessageCodec::Message.new(header, payload_header, payload)).payload
        nonce = SecureMessage.build_nonce(source_node_id, counter, header.security_flags)
        encrypted = @crypto.encrypt(key.operational_key, application, nonce, clear_header)
        Codec::MessageCodec::Base.encode_private_packet(
          Codec::MessageCodec::Packet.new(header, encrypted), key.privacy_key)
      end

      # Tries every installed key sharing the session ID; authentication must
      # succeed before group mapping or peer replay state is accepted.
      def decode(wire : Bytes) : Decoded
        raise Matter::CodecError.new("Group packet is too short") if wire.size < 8 + Codec::MessagePrivacy::MIC_LENGTH
        session_id = IO::ByteFormat::LittleEndian.decode(UInt16, wire[Codec::MessageCodec::SESSION_ID_OFFSET, 2])
        candidate_found = false
        authenticated_key : Key? = nil
        authenticated_group_id : UInt16? = nil
        @keys.each do |key|
          next unless key.session_id == session_id
          candidate_found = true
          packet = authenticate(wire, key)
          next unless packet
          unless packet.header.destination_group_id == key.group_id
            authenticated_key = key
            authenticated_group_id = packet.header.destination_group_id.try(&.id)
            next
          end
          source = packet.header.source_node_id.as(DataType::NodeId).id
          accept_counter(key.fabric_index, key.group_id.id, source,
            packet.header.control_message?, packet.header.message_id)
          message = Codec::MessageCodec::Base.decode_payload(packet)
          return Decoded.new(key.fabric_index, message)
        end
        if key = authenticated_key
          raise NoAvailableKey.new(fabric_index: key.fabric_index, group_id: authenticated_group_id)
        end
        raise NoAvailableKey.new unless candidate_found
        raise FailedAuth.new("No operational group key authenticated the packet")
      end

      private def authenticate(wire : Bytes, key : Key) : Codec::MessageCodec::Packet?
        packet = Codec::MessageCodec::Base.decode_private_packet(wire, key.privacy_key)
        aad = packet.header_bytes || raise Matter::CodecError.new("Private packet AAD is missing")
        source = packet.header.source_node_id.as(DataType::NodeId).id
        nonce = SecureMessage.build_nonce(source, packet.header.message_id, packet.header.security_flags)
        plaintext = @crypto.decrypt(key.operational_key, packet.payload, nonce, aad)
        Codec::MessageCodec::Packet.new(packet.header, plaintext, aad)
      rescue Matter::AuthenticationError | Matter::CodecError
        nil
      end

      private def accept_counter(fabric_index : UInt8, group_id : UInt16,
                                 source : UInt64, control : Bool, counter : UInt32) : Nil
        identity = {fabric_index, source, control}
        state = @reception[identity]?
        unless state
          cap = control ? CONTROL_PEER_CAPACITY : DATA_PEER_CAPACITY
          peers = @reception.keys.count { |entry| entry[0] == fabric_index && entry[2] == control }
          raise Matter::SessionError.new("Group peer replay table is full") if peers >= cap
          state = Transport::MessageCounter.new
          @reception[identity] = state
        end
        case state.check(counter)
        when Transport::MessageCounter::CheckResult::Accept
        else
          raise Replay.new(fabric_index: fabric_index, group_id: group_id)
        end
      end
    end
  end
end
