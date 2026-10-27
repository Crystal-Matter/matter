require "../spec_helper"
require "../../src/matter/datatype/node_id"

# Ported from matter.js NodeIdTests.ts
# Tests NodeId datatype functionality
describe Matter::DataType::NodeId do
  describe "creation" do
    it "creates a valid NodeId with UInt64" do
      node_id = Matter::DataType::NodeId.new(0x10001_u64)
      node_id.id.should eq(0x10001_u64)
    end

    it "is a value type" do
      Matter::DataType::NodeId.new(0x10001_u64).should eq(Matter::DataType::NodeId.new(0x10001_u64))
      Matter::DataType::NodeId.new(0x10001_u64).hash.should eq(Matter::DataType::NodeId.new(0x10001_u64).hash)
    end
  end

  describe "hexstring" do
    it "returns the 16 uppercase digit big-endian form" do
      node_id = Matter::DataType::NodeId.new(0x10001_u64)
      node_id.hexstring.should eq("0000000000010001")
    end
  end

  describe ".group" do
    it "creates a NodeId from a group ID" do
      group_node = Matter::DataType::NodeId.group(0x1234_u16)
      # Group NodeIds have the format 0xFFFFFFFFFFFF + 16-bit group id
      group_node.id.should eq(0xFFFF_FFFF_FFFF_1234_u64)
    end

    it "uses the group node id prefix" do
      Matter::DataType::NodeId.group(0_u16).id.should eq(Matter::DataType::NodeId::GROUP_NODE_ID_PREFIX)
      Matter::DataType::NodeId.group(UInt16::MAX).id.should eq(0xFFFF_FFFF_FFFF_FFFF_u64)
    end
  end

  describe ".random_operational" do
    sample_size = 1000

    it "generates NodeIds within the operational range" do
      sample_size.times do
        random_node = Matter::DataType::NodeId.random_operational

        random_node.id.should_not eq(0_u64)
        random_node.id.should be >= Matter::DataType::NodeId::OPERATIONAL_MINIMUM
        random_node.id.should be <= Matter::DataType::NodeId::OPERATIONAL_MAXIMUM
      end
    end

    it "does not repeat ids" do
      ids = Array.new(sample_size) { Matter::DataType::NodeId.random_operational.id }
      ids.uniq.size.should eq(sample_size)
    end
  end

  describe "constants" do
    it "has correct OPERATIONAL_MINIMUM" do
      Matter::DataType::NodeId::OPERATIONAL_MINIMUM.should eq(1_u64)
    end

    it "has correct OPERATIONAL_MAXIMUM" do
      # FFFFFFEFFFFFFFFF in hex
      Matter::DataType::NodeId::OPERATIONAL_MAXIMUM.to_s(16).upcase.should eq("FFFFFFEFFFFFFFFF")
    end
  end

  describe "big-endian bytes" do
    it "serializes to 8 big-endian bytes" do
      node_id = Matter::DataType::NodeId.new(0x123456789ABCDEF0_u64)
      node_id.to_be_bytes.should eq(Bytes[0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])
    end

    it "round-trips" do
      original = Matter::DataType::NodeId.new(0x123456789ABCDEF0_u64)
      Matter::DataType::NodeId.from_be_bytes(original.to_be_bytes).should eq(original)
    end

    it "rejects short slices" do
      expect_raises(Matter::CodecError, "NodeId slice must be at least 8 bytes") do
        Matter::DataType::NodeId.from_be_bytes(Bytes[1, 2, 3])
      end
    end
  end

  describe "TLV serialization" do
    it "encodes as a bare unsigned integer" do
      node_id = Matter::DataType::NodeId.new(0x123456789ABCDEF0_u64)
      TLV::Any.from_slice(node_id.to_slice).value.should eq(0x123456789ABCDEF0_u64)
    end

    it "round-trips through TLV" do
      original = Matter::DataType::NodeId.new(0x123456789ABCDEF0_u64)
      Matter::DataType::NodeId.from_slice(original.to_slice).should eq(original)
    end
  end

  describe "CaseAuthenticatedTag support" do
    it "creates NodeId from CaseAuthenticatedTag" do
      cat = Matter::DataType::CaseAuthenticatedTag.new(0x12345678_u32)
      node_id = Matter::DataType::NodeId.from_case_authenticated_tag(cat)

      # Format: 0xFFFFFFFD + 32-bit CAT value
      node_id.id.should eq(0xFFFFFFFD12345678_u64)
    end

    it "detects CAT-encoded NodeId" do
      cat = Matter::DataType::CaseAuthenticatedTag.new(0x12345678_u32)
      node_id = Matter::DataType::NodeId.from_case_authenticated_tag(cat)

      node_id.case_authenticated_tag?.should be_true
    end

    it "returns false for non-CAT NodeId" do
      node_id = Matter::DataType::NodeId.new(0x123456789ABCDEF0_u64)

      node_id.case_authenticated_tag?.should be_false
    end

    it "returns false for a CAT prefix that is off by one" do
      Matter::DataType::NodeId.new(0xFFFFFFFC12345678_u64).case_authenticated_tag?.should be_false
      Matter::DataType::NodeId.new(0xFFFFFFFE12345678_u64).case_authenticated_tag?.should be_false
    end

    it "extracts CaseAuthenticatedTag from NodeId" do
      original_cat = Matter::DataType::CaseAuthenticatedTag.new(0xABCD1234_u32)
      node_id = Matter::DataType::NodeId.from_case_authenticated_tag(original_cat)

      extracted_cat = node_id.extract_as_case_authenticated_tag
      extracted_cat.should eq(original_cat)
      extracted_cat.identity_value.should eq(0xABCD_u16)
      extracted_cat.version.should eq(0x1234_u16)
    end

    it "only decodes valid CAT subjects for access checks" do
      cat = Matter::DataType::CaseAuthenticatedTag.create(0xFFFE_u16, 2_u16)
      subject = Matter::DataType::NodeId.from_case_authenticated_tag(cat).id

      Matter::DataType::NodeId.case_authenticated_tag_from_subject?(subject).should eq(cat)
      Matter::DataType::NodeId.case_authenticated_tag_from_subject?(0xFFFF_FFFD_FFFE_0000_u64).should be_nil
      Matter::DataType::NodeId.case_authenticated_tag_from_subject?(0xFFFF_FFFF_FFFE_0002_u64).should be_nil
      Matter::DataType::NodeId.case_authenticated_tag_from_subject?(1_u64).should be_nil
    end

    it "raises when extracting CAT from non-CAT NodeId" do
      node_id = Matter::DataType::NodeId.new(0x123456789ABCDEF0_u64)

      expect_raises(ArgumentError, "NodeId does not encode a CaseAuthenticatedTag") do
        node_id.extract_as_case_authenticated_tag
      end
    end

    it "has correct CAT constants" do
      Matter::DataType::NodeId::CAT_PREFIX.should eq(0xFFFFFFFD00000000_u64)
      Matter::DataType::NodeId::CAT_VALUE_MASK.should eq(0x00000000FFFFFFFF_u64)
    end
  end
end
