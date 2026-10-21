module Matter
  module Transport
    # Matter Core §4.19.4 BTP wire frames carried by the Matter BLE GATT service.
    # This is framing only; a BTP session manages sequence windows, ACKs,
    # and segmentation. A platform adapter manages GATT subscriptions.
    module BtpCodec
      extend self

      HANDSHAKE_HEADER        = 0x65_u8
      HANDSHAKE_OPCODE        = 0x6c_u8
      HANDSHAKE_REQUEST_SIZE  =       9
      HANDSHAKE_RESPONSE_SIZE =       6
      VERSION_SLOTS           =       8
      MINIMUM_SEGMENT_SIZE    =  20_u16
      DATA_FLAG_MASK          = 0x0f_u8

      @[Flags]
      enum Flags : UInt8
        Begin    = 0x01
        Continue = 0x02
        End      = 0x04
        Ack      = 0x08
      end

      record HandshakeRequest, versions : Array(UInt8), segment_size : UInt16, window_size : UInt8
      record HandshakeResponse, version : UInt8, segment_size : UInt16, window_size : UInt8
      record Packet, flags : Flags, sequence_number : UInt8,
        ack_number : UInt8?, message_length : UInt16?, payload : Bytes

      def encode_handshake_request(request : HandshakeRequest) : Bytes
        unless request.versions.size.in?(1..VERSION_SLOTS) && request.versions.all?(&.in?(1_u8..15_u8))
          raise Matter::CodecError.new("BTP handshake needs one to eight nonzero 4-bit versions")
        end
        validate_handshake_window(request.segment_size, request.window_size)
        result = Bytes.new(HANDSHAKE_REQUEST_SIZE)
        result[0] = HANDSHAKE_HEADER
        result[1] = HANDSHAKE_OPCODE
        request.versions.each_with_index do |version, index|
          result[2 + index // 2] |= index.even? ? version : (version << 4).to_u8
        end
        IO::ByteFormat::LittleEndian.encode(request.segment_size, result[6, 2])
        result[8] = request.window_size
        result
      end

      def decode_handshake_request(data : Bytes) : HandshakeRequest
        validate_handshake_header(data, HANDSHAKE_REQUEST_SIZE)
        versions = [] of UInt8
        VERSION_SLOTS.times do |index|
          packed = data[2 + index // 2]
          version = index.even? ? packed & 0x0f_u8 : packed >> 4
          versions << version unless version == 0_u8
        end
        raise Matter::CodecError.new("BTP handshake has no supported versions") if versions.empty?
        segment_size = IO::ByteFormat::LittleEndian.decode(UInt16, data[6, 2])
        window_size = data[8]
        validate_handshake_window(segment_size, window_size)
        HandshakeRequest.new(versions, segment_size, window_size)
      end

      def encode_handshake_response(response : HandshakeResponse) : Bytes
        raise Matter::CodecError.new("BTP response version must be a nonzero 4-bit value") unless response.version.in?(1_u8..15_u8)
        validate_handshake_window(response.segment_size, response.window_size)
        result = Bytes.new(HANDSHAKE_RESPONSE_SIZE)
        result[0] = HANDSHAKE_HEADER
        result[1] = HANDSHAKE_OPCODE
        result[2] = response.version
        IO::ByteFormat::LittleEndian.encode(response.segment_size, result[3, 2])
        result[5] = response.window_size
        result
      end

      def decode_handshake_response(data : Bytes) : HandshakeResponse
        validate_handshake_header(data, HANDSHAKE_RESPONSE_SIZE)
        raise Matter::CodecError.new("BTP response reserved version bits are set") unless data[2] & 0xf0_u8 == 0_u8
        version = data[2] & 0x0f_u8
        raise Matter::CodecError.new("BTP response version is zero") if version == 0_u8
        segment_size = IO::ByteFormat::LittleEndian.decode(UInt16, data[3, 2])
        window_size = data[5]
        validate_handshake_window(segment_size, window_size)
        HandshakeResponse.new(version, segment_size, window_size)
      end

      def encode_packet(packet : Packet) : Bytes
        validate_packet(packet)
        header_size = 2 + (packet.ack_number ? 1 : 0) + (packet.message_length ? 2 : 0)
        result = Bytes.new(header_size + packet.payload.size)
        result[0] = packet.flags.value
        offset = 1
        if ack = packet.ack_number
          result[offset] = ack
          offset += 1
        end
        result[offset] = packet.sequence_number
        offset += 1
        if length = packet.message_length
          IO::ByteFormat::LittleEndian.encode(length, result[offset, 2])
          offset += 2
        end
        result[offset, packet.payload.size].copy_from(packet.payload)
        result
      end

      def decode_packet(data : Bytes) : Packet
        raise Matter::CodecError.new("BTP packet is truncated") if data.size < 2
        bits = data[0]
        raise Matter::CodecError.new("BTP packet has reserved flags") unless bits & ~DATA_FLAG_MASK == 0_u8
        flags = Flags.from_value(bits)
        offset = 1
        ack_number = nil
        if flags.includes?(Flags::Ack)
          raise Matter::CodecError.new("BTP ACK number is truncated") if data.size <= offset
          ack_number = data[offset]
          offset += 1
        end
        raise Matter::CodecError.new("BTP sequence number is truncated") if data.size <= offset
        sequence_number = data[offset]
        offset += 1
        message_length = nil
        if flags.includes?(Flags::Begin)
          raise Matter::CodecError.new("BTP message length is truncated") if data.size - offset < 2
          message_length = IO::ByteFormat::LittleEndian.decode(UInt16, data[offset, 2])
          offset += 2
        end
        packet = Packet.new(flags, sequence_number, ack_number, message_length, data[offset, data.size - offset].dup)
        validate_packet(packet)
        packet
      end

      private def validate_handshake_header(data : Bytes, length : Int32) : Nil
        unless data.size == length && data[0] == HANDSHAKE_HEADER && data[1] == HANDSHAKE_OPCODE
          raise Matter::CodecError.new("Invalid BTP handshake frame")
        end
      end

      private def validate_handshake_window(segment_size : UInt16, window_size : UInt8) : Nil
        if segment_size < MINIMUM_SEGMENT_SIZE || window_size == 0_u8
          raise Matter::CodecError.new("Invalid BTP segment or window size")
        end
      end

      private def validate_packet(packet : Packet) : Nil
        flags = packet.flags
        if flags.value & ~DATA_FLAG_MASK != 0_u8
          raise Matter::CodecError.new("BTP packet has reserved flags")
        end
        beginning = flags.includes?(Flags::Begin)
        continuing = flags.includes?(Flags::Continue)
        ending = flags.includes?(Flags::End)
        has_ack = flags.includes?(Flags::Ack)
        if beginning && continuing || ending && !beginning && !continuing
          raise Matter::CodecError.new("Invalid BTP segment flags")
        end
        if has_ack != !packet.ack_number.nil?
          raise Matter::CodecError.new("BTP ACK flag and number disagree")
        end
        if beginning != !packet.message_length.nil?
          raise Matter::CodecError.new("BTP beginning flag and message length disagree")
        end
        if beginning || continuing
          if packet.payload.empty?
            raise Matter::CodecError.new("BTP data segment is empty")
          end
        elsif !packet.payload.empty? || !has_ack
          raise Matter::CodecError.new("BTP packet has data without segment flags")
        end
        if length = packet.message_length
          if length < packet.payload.size || beginning && ending && length != packet.payload.size
            raise Matter::CodecError.new("BTP message length is inconsistent with payload")
          end
        end
      end
    end
  end
end
