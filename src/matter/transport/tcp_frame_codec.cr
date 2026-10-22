require "../error"

module Matter
  module Transport
    # Matter TCP stream framing (Core 4.13.1). The four-byte little-endian
    # length covers one complete Matter packet, excluding the prefix itself.
    # Each connection owns one decoder with its negotiated receive limit.
    class TcpFrameCodec
      LENGTH_PREFIX_SIZE = 4

      getter max_message_size : Int32

      @prefix : Bytes
      @prefix_size : Int32
      @message : Bytes?
      @message_size : Int32
      @failed : Bool

      def initialize(@max_message_size : Int32)
        if @max_message_size <= 0
          raise Matter::ConfigurationError.new("Matter TCP receive limit must be positive")
        end
        @prefix = Bytes.new(LENGTH_PREFIX_SIZE)
        @prefix_size = 0
        @message = nil
        @message_size = 0
        @failed = false
      end

      def failed? : Bool
        @failed
      end

      def incomplete? : Bool
        @prefix_size > 0 || !@message.nil?
      end

      def self.encode(message : Bytes, max_message_size : Int32) : Bytes
        validate_limit!(max_message_size)
        unless message.size.in?(1..max_message_size)
          raise Matter::ProtocolError.new("Matter TCP message length is out of range")
        end

        frame = Bytes.new(LENGTH_PREFIX_SIZE + message.size)
        IO::ByteFormat::LittleEndian.encode(message.size.to_u32, frame[0, LENGTH_PREFIX_SIZE])
        frame[LENGTH_PREFIX_SIZE, message.size].copy_from(message)
        frame
      end

      # A socket read can end anywhere or contain several framed packets.
      # Reject malformed lengths before allocating a body buffer.
      def feed(data : Bytes) : Array(Bytes)
        raise Matter::ProtocolError.new("Matter TCP frame decoder failed") if @failed

        messages = [] of Bytes
        offset = 0
        while offset < data.size
          if message = @message
            amount = {message.size - @message_size, data.size - offset}.min
            message[@message_size, amount].copy_from(data[offset, amount])
            @message_size += amount
            offset += amount
            if @message_size == message.size
              messages << message
              @message = nil
              @message_size = 0
            end
          else
            amount = {LENGTH_PREFIX_SIZE - @prefix_size, data.size - offset}.min
            @prefix[@prefix_size, amount].copy_from(data[offset, amount])
            @prefix_size += amount
            offset += amount
            if @prefix_size == LENGTH_PREFIX_SIZE
              length = IO::ByteFormat::LittleEndian.decode(UInt32, @prefix)
              reject!("Matter TCP message has zero length") if length == 0
              reject!("Matter TCP message exceeds receive limit") if length > @max_message_size.to_u32
              @message = Bytes.new(length.to_i)
              @prefix_size = 0
            end
          end
        end
        messages
      end

      private def reject!(message : String) : NoReturn
        @failed = true
        @message = nil
        raise Matter::ProtocolError.new(message)
      end

      private def self.validate_limit!(max_message_size : Int32) : Nil
        if max_message_size <= 0
          raise Matter::ConfigurationError.new("Matter TCP receive limit must be positive")
        end
      end
    end
  end
end
