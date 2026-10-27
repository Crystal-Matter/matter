require "./id"
require "./case_authenticated_tag"

module Matter
  module DataType
    define_id NodeId, UInt64

    struct NodeId
      UNSPECIFIED = 0_u64

      # Operational Node ID range (Matter 1.4 § 2.5.5.1)
      OPERATIONAL_MINIMUM = 0x0000_0000_0000_0001_u64
      OPERATIONAL_MAXIMUM = 0xFFFF_FFEF_FFFF_FFFF_u64
      # Matter 1.6 Joint Fabric Node IDs use an exclusive upper bound.
      JOINT_FABRIC_EXCLUSIVE_MAXIMUM = OPERATIONAL_MAXIMUM

      def self.valid_joint_fabric?(value : UInt64) : Bool
        value >= OPERATIONAL_MINIMUM && value < JOINT_FABRIC_EXCLUSIVE_MAXIMUM
      end

      # A CASE ACL subject is either an operational node or a CAT with a
      # nonzero version. Reserved, group and PASE subject ranges are excluded.
      def self.valid_case_subject?(value : UInt64) : Bool
        return true if value >= OPERATIONAL_MINIMUM && value <= OPERATIONAL_MAXIMUM

        (value & ~CAT_VALUE_MASK) == CAT_PREFIX &&
          (value & CaseAuthenticatedTag::VERSION_MASK.to_u64) != 0_u64
      end

      def self.random_joint_fabric : NodeId
        new(Random::Secure.rand(OPERATIONAL_MINIMUM...JOINT_FABRIC_EXCLUSIVE_MAXIMUM))
      end

      # Group Node ID prefix: 0xFFFFFFFFFFFF followed by the 16-bit group id
      GROUP_NODE_ID_PREFIX = 0xFFFF_FFFF_FFFF_0000_u64

      # CAT NodeId prefix: 0xFFFFFFFD followed by 32-bit CAT value
      CAT_PREFIX     = 0xFFFFFFFD00000000_u64
      CAT_VALUE_MASK =        0xFFFF_FFFF_u64

      # Width of the big-endian byte form
      BYTE_SIZE = 8

      # Create NodeId from bytes (big-endian)
      def self.from_be_bytes(slice : Bytes) : NodeId
        if slice.size < BYTE_SIZE
          raise Matter::CodecError.new("NodeId slice must be at least #{BYTE_SIZE} bytes")
        end
        new(IO::ByteFormat::BigEndian.decode(UInt64, slice))
      end

      # Serialize to bytes (big-endian). `to_slice` is the TLV encoding.
      def to_be_bytes : Bytes
        bytes = Bytes.new(BYTE_SIZE)
        IO::ByteFormat::BigEndian.encode(@id, bytes)
        bytes
      end

      # Create NodeId from a CaseAuthenticatedTag
      # Format: 0xFFFFFFFD + 32-bit CAT value
      def self.from_case_authenticated_tag(cat : CaseAuthenticatedTag) : NodeId
        new(CAT_PREFIX | cat.value.to_u64)
      end

      # Decode a CASE subject only when it is a CAT with a nonzero version.
      # Ordinary operational node IDs and group IDs have no CAT identity.
      def self.case_authenticated_tag_from_subject?(subject : UInt64) : CaseAuthenticatedTag?
        node_id = new(subject)
        return unless node_id.case_authenticated_tag?

        value = (subject & CAT_VALUE_MASK).to_u32
        return if (value & CaseAuthenticatedTag::VERSION_MASK) == 0_u32

        CaseAuthenticatedTag.new(value)
      end

      # Check if this NodeId encodes a CaseAuthenticatedTag
      def case_authenticated_tag? : Bool
        (id & ~CAT_VALUE_MASK) == CAT_PREFIX
      end

      # Extract the CaseAuthenticatedTag from this NodeId
      # Raises if this NodeId is not a CAT-encoded NodeId
      def extract_as_case_authenticated_tag : CaseAuthenticatedTag
        unless case_authenticated_tag?
          raise ArgumentError.new("NodeId does not encode a CaseAuthenticatedTag")
        end
        CaseAuthenticatedTag.new((id & CAT_VALUE_MASK).to_u32)
      end

      # Generate a random NodeId within the operational range
      def self.random_operational : NodeId
        new(Random::Secure.rand(OPERATIONAL_MINIMUM..OPERATIONAL_MAXIMUM))
      end

      # Create the Group NodeId for a group id
      # Format: 0xFFFFFFFFFFFF + 16-bit group id
      def self.group(group_id : UInt16) : NodeId
        new(GROUP_NODE_ID_PREFIX | group_id.to_u64)
      end

      # 16 uppercase hex digits, the mDNS instance/hostname form
      def hexstring : String
        Hex.node_id(@id)
      end
    end
  end
end
