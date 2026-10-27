require "socket"
require "../datatype/group_id"

module Matter
  module Transport
    # Matter PerGroupId multicast address (Core §2.5.6.2).
    module GroupMulticast
      # IANA-assigned IPv6 address used by Matter 1.6 Groupcast Listener.
      IANA_ADDRESS                = "ff05::fa"
      PER_GROUP_ID_SCOPE_PREFIX   = 0xff35_u16
      PER_GROUP_ID_NETWORK_PREFIX = 0x0040_u16
      PER_GROUP_ID_FABRIC_PREFIX  =    0xfd_u8
      PER_GROUP_ID_RESERVED_OCTET =       0_u8
      RESERVED_GROUP_ID           = DataType::GroupId::RESERVED.id

      def self.iana_address(port : Int32 = UDPTransport::MATTER_PORT) : Socket::IPAddress
        Socket::IPAddress.new(IANA_ADDRESS, port)
      end

      def self.address(fabric_id : UInt64, group_id : UInt16, port : Int32 = UDPTransport::MATTER_PORT) : Socket::IPAddress
        raise ArgumentError.new("Group ID zero is reserved") if group_id == RESERVED_GROUP_ID
        io = IO::Memory.new
        io.write_bytes(PER_GROUP_ID_SCOPE_PREFIX, IO::ByteFormat::BigEndian)
        io.write_bytes(PER_GROUP_ID_NETWORK_PREFIX, IO::ByteFormat::BigEndian)
        io.write_byte(PER_GROUP_ID_FABRIC_PREFIX)
        io.write_bytes(fabric_id, IO::ByteFormat::BigEndian)
        io.write_byte(PER_GROUP_ID_RESERVED_OCTET)
        io.write_bytes(group_id, IO::ByteFormat::BigEndian)
        bytes = io.to_slice
        segments = (0...8).map { |index| IO::ByteFormat::BigEndian.decode(UInt16, bytes[index * 2, 2]).to_s(16) }
        Socket::IPAddress.new(segments.join(":"), port)
      end
    end
  end
end
