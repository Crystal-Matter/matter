module Matter
  module Codec
    module MessageCodec
      Log = ::Log.for("matter.codec.message_codec")

      HEADER_VERSION       = UInt8.new(0x00)
      COMMON_VENDOR_ID     = UInt16.new(0x0000)
      UNSECURED_SESSION_ID = 0_u16

      # Header version lives in the top nibble of the packet header flags byte
      VERSION_SHIFT = 4

      # A protocol id is `vendor id << 16 | protocol number`
      VENDOR_ID_MASK   = 0xFFFF0000_u32
      VENDOR_ID_SHIFT  =             16
      PROTOCOL_ID_MASK =     0xFFFF_u32

      # Byte offsets of the fixed part of the packet header
      FLAGS_OFFSET           = 0
      SESSION_ID_OFFSET      = 1
      SECURITY_FLAGS_OFFSET  = 3
      MESSAGE_COUNTER_OFFSET = 4

      enum SessionType : UInt8
        Unicast = 0
        Group   = 1
      end

      enum PacketHeaderFlag : UInt8
        HasDestNodeId   = 0b00000001
        HasDestGroupId  = 0b00000010
        HasSourceNodeId = 0b00000100
        VersionMask     = 0b11110000
      end

      enum PayloadHeaderFlag : UInt8
        IsInitiatorMessage = 0b00000001
        IsAckMessage       = 0b00000010
        RequiresAck        = 0b00000100
        HasSecureExtension = 0b00001000
        HasVendorId        = 0b00010000
      end

      enum SecurityFlag : UInt8
        HasPrivacyEnhancements = 0b10000000
        IsControlMessage       = 0b01000000
        HasMessageExtension    = 0b00100000
        SessionTypeMask        = 0b00000011
      end

      struct PacketHeader
        getter session_id : UInt16
        getter session_type : SessionType
        getter message_id : UInt32
        getter source_node_id : DataType::NodeId?
        getter destination_node_id : DataType::NodeId?
        getter destination_group_id : DataType::GroupId?
        getter? privacy_enhancements : Bool
        getter? control_message : Bool
        getter? message_extensions : Bool
        getter message_extension_data : Bytes?

        def initialize(@session_id : UInt16, @session_type : SessionType, @message_id : UInt32, @privacy_enhancements : Bool = false, @control_message : Bool = false, @message_extensions : Bool = false, @source_node_id : DataType::NodeId? = nil, @destination_node_id : DataType::NodeId? = nil, @destination_group_id : DataType::GroupId? = nil, @message_extension_data : Bytes? = nil)
          if @destination_node_id && @destination_group_id
            raise Matter::CodecError.new("The header cannot contain destination group and node at the same time")
          end
          @message_extensions = true if @message_extension_data
        end

        def flags : UInt8
          value = (HEADER_VERSION << VERSION_SHIFT).to_u8
          value |= PacketHeaderFlag::HasSourceNodeId.value if @source_node_id
          value |= PacketHeaderFlag::HasDestNodeId.value if @destination_node_id
          value |= PacketHeaderFlag::HasDestGroupId.value if @destination_group_id
          value
        end

        def security_flags : UInt8
          value = @session_type.value
          value |= SecurityFlag::HasPrivacyEnhancements.value if @privacy_enhancements
          value |= SecurityFlag::IsControlMessage.value if @control_message
          value |= SecurityFlag::HasMessageExtension.value if @message_extensions
          value
        end
      end

      struct PayloadHeader
        UNDECODED_EXCHANGE_ID  = 0_u16
        UNDECODED_PROTOCOL_ID  = 0_u16
        UNDECODED_MESSAGE_TYPE =  0_u8

        # Encrypted packets do not expose their payload header until decryption.
        # The transport carries this placeholder only until the handler decodes it.
        def self.encrypted_placeholder : self
          new(exchange_id: UNDECODED_EXCHANGE_ID,
            protocol_id: UNDECODED_PROTOCOL_ID,
            message_type: UNDECODED_MESSAGE_TYPE,
            initiator_message: false,
            requires_acknowledge: false)
        end

        getter exchange_id : UInt16
        getter protocol_id : UInt32
        getter message_type : UInt8
        getter? initiator_message : Bool
        getter? requires_acknowledge : Bool
        getter acknowledged_message_id : UInt32?
        getter secured_extensions : Bytes?

        def initialize(@exchange_id : UInt16, protocol_id : UInt16 | UInt32, @message_type : UInt8, @initiator_message : Bool, @requires_acknowledge : Bool, @acknowledged_message_id : UInt32? = nil, @secured_extensions : Bytes? = nil)
          @protocol_id = protocol_id.to_u32
        end
      end

      struct Packet
        getter header : PacketHeader
        getter header_bytes : Bytes?
        getter payload : Slice(UInt8)

        def initialize(@header : PacketHeader, @payload : Slice(UInt8), @header_bytes : Bytes? = nil)
        end
      end

      struct Message
        getter packet_header : PacketHeader
        getter header_bytes : Bytes?
        getter payload_header : PayloadHeader
        getter payload : Slice(UInt8)

        def initialize(@packet_header : PacketHeader, @payload_header : PayloadHeader, @payload : Slice(UInt8), @header_bytes : Bytes? = nil)
        end
      end

      module Base
        extend self

        def decode_packet(data : Slice(UInt8)) : Packet
          decode_packet_internal(data, false)
        end

        # Deobfuscates a group packet header using a candidate privacy key.
        # The returned packet is unauthenticated; callers must verify its
        # AES-CCM MIC with the matching operational group key before use.
        def decode_private_packet(data : Bytes, privacy_key : Bytes) : Packet
          raise Matter::CodecError.new("Private packet is too short") if data.size < 8 + MessagePrivacy::MIC_LENGTH
          flags = data[FLAGS_OFFSET]
          security_flags = data[SECURITY_FLAGS_OFFSET]
          unless (security_flags & SecurityFlag::HasPrivacyEnhancements.value) != 0 &&
                 (security_flags & SecurityFlag::SessionTypeMask.value) == SessionType::Group.value
            raise Matter::CodecError.new("Privacy requires a group packet")
          end
          has_source = (flags & PacketHeaderFlag::HasSourceNodeId.value) != 0
          has_group = (flags & PacketHeaderFlag::HasDestGroupId.value) != 0
          has_node = (flags & PacketHeaderFlag::HasDestNodeId.value) != 0
          if !has_source || !has_group || has_node
            raise Matter::CodecError.new("Private group packet requires source and group IDs")
          end
          header_length = 8 + 8 + 2
          raise Matter::CodecError.new("Private packet has no MIC") if data.size < header_length + MessagePrivacy::MIC_LENGTH

          session_id = IO::ByteFormat::LittleEndian.decode(UInt16, data[SESSION_ID_OFFSET, 2])
          mic = data[data.size - MessagePrivacy::MIC_LENGTH, MessagePrivacy::MIC_LENGTH]
          privacy_nonce = MessagePrivacy.nonce(session_id, mic)
          region = MessagePrivacy.obfuscate(privacy_key, data[MESSAGE_COUNTER_OFFSET, header_length - MESSAGE_COUNTER_OFFSET], privacy_nonce)
          clear = data.dup
          clear[MESSAGE_COUNTER_OFFSET, region.size].copy_from(region)
          decode_packet_internal(clear, true)
        end

        private def decode_packet_internal(data : Slice(UInt8), allow_private : Bool) : Packet
          io = IO::Memory.new

          io.write(data)
          io.rewind
          header = decode_packet_header(io, allow_private: allow_private)

          header_bytes = data[0, io.pos.to_i].dup
          Packet.new(header, io.getb_to_end, header_bytes)
        end

        def decode_payload(packet : Packet) : Message
          io = IO::Memory.new

          io.write(packet.payload)
          io.rewind
          header = decode_payload_header(io)

          Message.new(packet.header, header, io.getb_to_end, packet.header_bytes)
        end

        def encode_payload(message : Message) : Packet
          io = IO::Memory.new
          encode_payload_header(message.payload_header, io)

          Packet.new(header: message.packet_header, payload: Slice.join([io.rewind.to_slice, message.payload]))
        end

        def encode_message(packet_header : PacketHeader, payload_header : PayloadHeader, payload : Bytes) : Bytes
          encode_packet(encode_payload(Message.new(packet_header, payload_header, payload)))
        end

        def encode_packet_header(packet_header : PacketHeader) : Bytes
          io = IO::Memory.new
          encode_packet_header(packet_header, io)
          io.to_slice
        end

        def encode_packet(packet : Packet) : Slice(UInt8)
          if packet.header.privacy_enhancements?
            raise Matter::CodecError.new("Use encode_private_packet for a privacy-enhanced packet")
          end
          io = IO::Memory.new
          encode_packet_header(packet.header, io)

          Slice.join([io.rewind.to_slice, packet.payload])
        end

        # The payload must already be AES-CCM encrypted and include its MIC.
        def encode_private_packet(packet : Packet, privacy_key : Bytes) : Bytes
          header = packet.header
          if !header.session_type.group? || !header.privacy_enhancements? ||
             !header.source_node_id || !header.destination_group_id || header.destination_node_id
            raise Matter::CodecError.new("Privacy requires a group packet with source and group IDs")
          end
          raise Matter::CodecError.new("Private packet has no MIC") if packet.payload.size < MessagePrivacy::MIC_LENGTH
          clear_header = encode_packet_header(header)
          mic = packet.payload[packet.payload.size - MessagePrivacy::MIC_LENGTH, MessagePrivacy::MIC_LENGTH]
          privacy_nonce = MessagePrivacy.nonce(header.session_id, mic)
          region = MessagePrivacy.obfuscate(privacy_key, clear_header[MESSAGE_COUNTER_OFFSET, clear_header.size - MESSAGE_COUNTER_OFFSET], privacy_nonce)
          wire_header = clear_header.dup
          wire_header[MESSAGE_COUNTER_OFFSET, region.size].copy_from(region)
          Slice.join([wire_header, packet.payload])
        end

        def encode_packet_header(packet_header : PacketHeader, io : IO::Memory, byte_format : IO::ByteFormat = IO::ByteFormat::LittleEndian)
          flags = packet_header.flags
          security_flags = packet_header.security_flags

          byte_format.encode(UInt8.new(flags), io)
          byte_format.encode(UInt16.new(packet_header.session_id), io)
          byte_format.encode(UInt8.new(security_flags), io)
          byte_format.encode(UInt32.new(packet_header.message_id), io)

          # Presence is based on nil-ness, not the ID value
          source_node_id = packet_header.source_node_id
          dest_node_id = packet_header.destination_node_id

          byte_format.encode(UInt64.new(source_node_id.as(DataType::NodeId).id), io) if source_node_id
          byte_format.encode(UInt64.new(dest_node_id.as(DataType::NodeId).id), io) if dest_node_id
          byte_format.encode(UInt16.new(packet_header.destination_group_id.as(DataType::GroupId).id), io) if packet_header.destination_group_id
          if packet_header.message_extensions?
            encode_extension(io, packet_header.message_extension_data || Bytes.empty, "Message extension", byte_format)
          end
        end

        def encode_payload_header(payload_header : PayloadHeader, io : IO::Memory, byte_format : IO::ByteFormat = IO::ByteFormat::LittleEndian)
          vendor_id = (payload_header.protocol_id & VENDOR_ID_MASK) >> VENDOR_ID_SHIFT

          flags = (payload_header.initiator_message? ? PayloadHeaderFlag::IsInitiatorMessage.value : 0) | \
            (payload_header.acknowledged_message_id.nil? ? 0 : PayloadHeaderFlag::IsAckMessage.value) | \
            (payload_header.requires_acknowledge? ? PayloadHeaderFlag::RequiresAck.value : 0) | \
            (payload_header.secured_extensions.nil? ? 0 : PayloadHeaderFlag::HasSecureExtension.value) | \
            (vendor_id != COMMON_VENDOR_ID ? PayloadHeaderFlag::HasVendorId.value : 0)

          byte_format.encode(UInt8.new(flags), io)
          byte_format.encode(UInt8.new(payload_header.message_type), io)
          byte_format.encode(UInt16.new(payload_header.exchange_id), io)

          byte_format.encode(vendor_id.to_u16, io) if vendor_id != COMMON_VENDOR_ID
          byte_format.encode((payload_header.protocol_id & PROTOCOL_ID_MASK).to_u16, io)
          byte_format.encode(UInt32.new(payload_header.acknowledged_message_id.as(UInt32)), io) if payload_header.acknowledged_message_id
          if extension = payload_header.secured_extensions
            encode_extension(io, extension, "Secured extension", byte_format)
          end
        end

        private def decode_packet_header(io : IO::Memory, byte_format : IO::ByteFormat = IO::ByteFormat::LittleEndian, allow_private : Bool = false) : PacketHeader
          flags = io.read_bytes(UInt8, byte_format)
          version = (flags & PacketHeaderFlag::VersionMask.value) >> VERSION_SHIFT

          has_destination_node_id = (flags & PacketHeaderFlag::HasDestNodeId.value) != 0
          has_destination_group_id = (flags & PacketHeaderFlag::HasDestGroupId.value) != 0
          has_source_node_id = (flags & PacketHeaderFlag::HasSourceNodeId.value) != 0

          raise Matter::CodecError.new("The header cannot contain destination group and node at the same time") if has_destination_node_id && has_destination_group_id
          raise Matter::CodecError.new("Unsupported header version #{version}") if version != HEADER_VERSION

          session_id = io.read_bytes(UInt16, byte_format)
          security_flags = io.read_bytes(UInt8, byte_format)
          message_id = io.read_bytes(UInt32, byte_format)

          source_node_id = has_source_node_id ? DataType::NodeId.new(io.read_bytes(UInt64, byte_format)) : nil
          destination_node_id = has_destination_node_id ? DataType::NodeId.new(io.read_bytes(UInt64, byte_format)) : nil
          destination_group_id = has_destination_group_id ? DataType::GroupId.new(io.read_bytes(UInt16, byte_format)) : nil

          session_type = security_flags & SecurityFlag::SessionTypeMask.value

          raise Matter::CodecError.new("Unsupported session type #{session_type}") if session_type != SessionType::Group.value && session_type != SessionType::Unicast.value

          has_privacy_enhancements = (security_flags & SecurityFlag::HasPrivacyEnhancements.value) != 0
          raise Matter::CodecError.new("Privacy key required") if has_privacy_enhancements && !allow_private

          is_control_message = (security_flags & SecurityFlag::IsControlMessage.value) != 0
          # Control messages are valid - used for MRP standalone ACKs and other control functions

          has_message_extensions = (security_flags & SecurityFlag::HasMessageExtension.value) != 0
          message_extension_data = has_message_extensions ? decode_extension(io, "Message extension", byte_format) : nil

          PacketHeader.new(session_id: session_id,
            session_type: SessionType.from_value(session_type),
            message_id: message_id,
            privacy_enhancements: has_privacy_enhancements,
            control_message: is_control_message,
            message_extensions: has_message_extensions,
            message_extension_data: message_extension_data,
            source_node_id: source_node_id,
            destination_node_id: destination_node_id,
            destination_group_id: destination_group_id)
        end

        private def decode_payload_header(io : IO::Memory, byte_format : IO::ByteFormat = IO::ByteFormat::LittleEndian) : PayloadHeader
          flags = io.read_bytes(UInt8, byte_format)

          is_initiator_message = (flags & PayloadHeaderFlag::IsInitiatorMessage.value) != 0
          is_acknowledge_message = (flags & PayloadHeaderFlag::IsAckMessage.value) != 0
          requires_acknowledge = (flags & PayloadHeaderFlag::RequiresAck.value) != 0
          has_secured_extension = (flags & PayloadHeaderFlag::HasSecureExtension.value) != 0
          has_vendor_id = (flags & PayloadHeaderFlag::HasVendorId.value) != 0

          message_type = io.read_bytes(UInt8, byte_format)
          exchange_id = io.read_bytes(UInt16, byte_format)
          vendor_id = has_vendor_id ? io.read_bytes(UInt16, byte_format) : COMMON_VENDOR_ID
          protocol_id = (vendor_id.to_u32 << VENDOR_ID_SHIFT) | io.read_bytes(UInt16, byte_format).to_u32
          acknowledged_message_id = is_acknowledge_message ? io.read_bytes(UInt32, byte_format) : nil
          secured_extensions = has_secured_extension ? decode_extension(io, "Secured extension", byte_format) : nil

          PayloadHeader.new(exchange_id: exchange_id,
            protocol_id: protocol_id,
            message_type: message_type,
            initiator_message: is_initiator_message,
            requires_acknowledge: requires_acknowledge,
            acknowledged_message_id: acknowledged_message_id,
            secured_extensions: secured_extensions)
        end

        private def encode_extension(io : IO::Memory, extension : Bytes, label : String,
                                     byte_format : IO::ByteFormat) : Nil
          if extension.size > UInt16::MAX
            raise Matter::CodecError.new("#{label} exceeds 65535 bytes")
          end
          byte_format.encode(extension.size.to_u16, io)
          io.write(extension)
        end

        private def decode_extension(io : IO::Memory, label : String,
                                     byte_format : IO::ByteFormat) : Bytes
          if io.size - io.pos < sizeof(UInt16)
            raise Matter::CodecError.new("#{label} length is truncated")
          end
          length = io.read_bytes(UInt16, byte_format)
          if length > io.size - io.pos
            raise Matter::CodecError.new("#{label} exceeds received bytes")
          end
          extension = Bytes.new(length)
          io.read_fully(extension)
          extension
        end
      end
    end
  end
end
