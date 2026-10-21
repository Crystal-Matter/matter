require "socket"

module Matter
  module Transport
    # Matter PerGroupId multicast address (Core §2.5.6.2).
    module GroupMulticast
      def self.address(fabric_id : UInt64, group_id : UInt16, port : Int32 = UDPTransport::MATTER_PORT) : Socket::IPAddress
        raise ArgumentError.new("Group ID zero is reserved") if group_id == 0
        io = IO::Memory.new
        io.write_bytes(0xff35_u16, IO::ByteFormat::BigEndian)
        io.write_bytes(0x0040_u16, IO::ByteFormat::BigEndian)
        io.write_byte(0xfd_u8)
        io.write_bytes(fabric_id, IO::ByteFormat::BigEndian)
        io.write_byte(0_u8)
        io.write_bytes(group_id, IO::ByteFormat::BigEndian)
        bytes = io.to_slice
        segments = (0...8).map { |index| IO::ByteFormat::BigEndian.decode(UInt16, bytes[index * 2, 2]).to_s(16) }
        Socket::IPAddress.new(segments.join(":"), port)
      end
    end
  end
end
