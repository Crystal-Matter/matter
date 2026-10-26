require "./spec_helper"
require "../src/matter/fabric"

describe Matter::Fabric do
  it "keeps all IPK epochs for responder CASE and selects the second newest for initiator CASE" do
    fabric = Matter::Fabric.new(
      fabric_id: 0x1234_u64,
      fabric_index: 1_u8,
      node_id: 0x5678_u64,
      root_public_key: Random::Secure.random_bytes(65),
      operational_cert: Bytes[1],
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: Bytes.new(16, 0x11_u8)
    )
    random = Bytes.new(32, 0xAB_u8)
    first = fabric.derived_ipk
    fabric.ipk_epoch_keys = [Bytes.new(16, 0x11_u8), Bytes.new(16, 0x22_u8), Bytes.new(16, 0x33_u8)]
    selected = fabric.derived_ipk
    selected.should_not eq(first)
    fabric.matching_derived_ipk(fabric.compute_destination_id(random), random).should eq(selected)
    old_destination = fabric.compute_destination_id(random, first)
    fabric.matching_derived_ipk(old_destination, random).should eq(first)
    restored = Matter::Fabric.from_document(fabric.to_document)
    restored.ipk_epoch_keys.should eq(fabric.ipk_epoch_keys)
    restored.matching_derived_ipk(old_destination, random).should eq(first)
  end

  describe "initialization" do
    it "creates fabric with valid parameters" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      fabric = Matter::Fabric.new(
        fabric_id: 0x1234567890ABCDEF_u64,
        fabric_index: 1_u8,
        node_id: 0x1122334455667788_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk,
        vendor_id: 0xFFF1_u16,
        label: "Test Fabric"
      )

      fabric.fabric_id.should eq(0x1234567890ABCDEF_u64)
      fabric.fabric_index.should eq(1_u8)
      fabric.node_id.should eq(0x1122334455667788_u64)
      fabric.vendor_id.should eq(0xFFF1_u16)
      fabric.label.should eq("Test Fabric")
    end

    it "validates fabric_index range (must be 1-254)" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      expect_raises(ArgumentError, /fabric_index must be 1-254/) do
        Matter::Fabric.new(
          fabric_id: 0x1_u64,
          fabric_index: 0_u8, # Invalid: 0 is reserved
          node_id: 0x1_u64,
          root_public_key: Random::Secure.random_bytes(65),
          operational_cert: Random::Secure.random_bytes(200),
          operational_key: key,
          ipk: ipk
        )
      end

      expect_raises(ArgumentError, /fabric_index must be 1-254/) do
        Matter::Fabric.new(
          fabric_id: 0x1_u64,
          fabric_index: 255_u8, # Invalid: 255 is reserved
          node_id: 0x1_u64,
          root_public_key: Random::Secure.random_bytes(65),
          operational_cert: Random::Secure.random_bytes(200),
          operational_key: key,
          ipk: ipk
        )
      end
    end

    it "validates IPK is exactly 16 bytes" do
      key = Matter::Crypto::Key.generate_key_pair

      expect_raises(ArgumentError, /ipk must be 16 bytes/) do
        Matter::Fabric.new(
          fabric_id: 0x1_u64,
          fabric_index: 1_u8,
          node_id: 0x1_u64,
          root_public_key: Random::Secure.random_bytes(65),
          operational_cert: Random::Secure.random_bytes(200),
          operational_key: key,
          ipk: Random::Secure.random_bytes(15) # Too short
        )
      end
    end

    it "validates label length (max 32 chars)" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      expect_raises(ArgumentError, /label must be <= 32 characters/) do
        Matter::Fabric.new(
          fabric_id: 0x1_u64,
          fabric_index: 1_u8,
          node_id: 0x1_u64,
          root_public_key: Random::Secure.random_bytes(65),
          operational_cert: Random::Secure.random_bytes(200),
          operational_key: key,
          ipk: ipk,
          label: "A" * 33 # Too long
        )
      end
    end

    it "validates fabric_id is not zero" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      expect_raises(ArgumentError, /fabric_id must not be 0/) do
        Matter::Fabric.new(
          fabric_id: 0_u64,
          fabric_index: 1_u8,
          node_id: 0x1_u64,
          root_public_key: Random::Secure.random_bytes(65),
          operational_cert: Random::Secure.random_bytes(200),
          operational_key: key,
          ipk: ipk
        )
      end
    end

    it "validates node_id is not zero" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      expect_raises(ArgumentError, /node_id must not be 0/) do
        Matter::Fabric.new(
          fabric_id: 0x1_u64,
          fabric_index: 1_u8,
          node_id: 0_u64,
          root_public_key: Random::Secure.random_bytes(65),
          operational_cert: Random::Secure.random_bytes(200),
          operational_key: key,
          ipk: ipk
        )
      end
    end
  end

  describe "serialization" do
    it "serializes to hash" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      fabric = Matter::Fabric.new(
        fabric_id: 0x1234567890ABCDEF_u64,
        fabric_index: 1_u8,
        node_id: 0x1122334455667788_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk,
        vendor_id: 0xFFF1_u16,
        label: "Test"
      )

      document = fabric.to_document
      document["fabric_id"].should eq(0x1234567890ABCDEF_u64)
      document["fabric_index"].should eq(1_i64)
      document["vendor_id"].should eq(0xFFF1_i64)
      document["label"].should eq("Test")
      document["operational_private_key"].should eq(key.private_bits)
      document["operational_public_key"].should eq(key.public_bits)
      document.has_key?("intermediate_cert").should be_false
      document.has_key?("root_cert").should be_false
    end

    it "deserializes from hash" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)
      root_pk = Random::Secure.random_bytes(65)
      op_cert = Random::Secure.random_bytes(200)

      original = Matter::Fabric.new(
        fabric_id: 0x1234567890ABCDEF_u64,
        fabric_index: 1_u8,
        node_id: 0x1122334455667788_u64,
        root_public_key: root_pk,
        operational_cert: op_cert,
        operational_key: key,
        ipk: ipk,
        vendor_id: 0xFFF1_u16,
        label: "Test"
      )

      restored = Matter::Fabric.from_document(original.to_document)

      restored.fabric_id.should eq(original.fabric_id)
      restored.operational_key.private_bits.should eq(key.private_bits)
      restored.operational_key.public_bits.should eq(key.public_bits)
      restored.created_at.should eq(original.created_at)
      restored.last_used_at.should eq(original.last_used_at)
      restored.fabric_index.should eq(original.fabric_index)
      restored.node_id.should eq(original.node_id)
      restored.vendor_id.should eq(original.vendor_id)
      restored.label.should eq(original.label)
      restored.ipk.should eq(original.ipk)
    end
  end

  describe "helper methods" do
    it "generates compressed fabric ID using HKDF" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      # Create a known root public key (65 bytes: 0x04 || x || y)
      root_pub_key = Bytes.new(65)
      root_pub_key[0] = 0x04_u8 # Uncompressed point indicator

      fabric = Matter::Fabric.new(
        fabric_id: 0x1234567890ABCDEF_u64,
        fabric_index: 1_u8,
        node_id: 0xAABBCCDDEEFF0011_u64,
        root_public_key: root_pub_key,
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk
      )

      compressed = fabric.compressed_fabric_id

      # Compressed fabric ID should be 8 bytes
      compressed.size.should eq(8)

      # Verify it's deterministic (same inputs produce same output)
      compressed2 = fabric.compressed_fabric_id
      compressed.should eq(compressed2)
    end

    it "compressed fabric ID uses HKDF with correct parameters" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      # Create root public key
      root_pub_key = Bytes.new(65)
      root_pub_key[0] = 0x04_u8 # Uncompressed point indicator
      # Fill with test data
      (1...65).each { |i| root_pub_key[i] = (i % 256).to_u8 }

      fabric_id = 0x1234567890ABCDEF_u64

      fabric = Matter::Fabric.new(
        fabric_id: fabric_id,
        fabric_index: 1_u8,
        node_id: 0xAABBCCDDEEFF0011_u64,
        root_public_key: root_pub_key,
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk
      )

      compressed = fabric.compressed_fabric_id

      # Manually calculate what it should be using HKDF
      # Key: root public key without first byte
      hkdf_key = root_pub_key[1..-1]

      # Salt: fabric_id as 8 bytes (big-endian per Matter spec 4.3.2.2)
      salt = Bytes.new(8)
      IO::ByteFormat::BigEndian.encode(fabric_id, salt)

      # Info: "CompressedFabric"
      info = "CompressedFabric".to_slice

      # Calculate expected value
      expected = Matter::Crypto.create_hkdf_key(hkdf_key, salt, info, 8)

      compressed.should eq(expected)
    end

    it "marks fabric as used" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      # Create fabric with an old timestamp
      old_time = Time.utc - 100.seconds
      fabric = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk,
        last_used_at: old_time
      )

      fabric.last_used_at.should eq(old_time)
      fabric.mark_used
      fabric.last_used_at.should be > old_time
    end

    it "checks if fabric is expired" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      # Create fabric with old timestamp
      fabric = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk,
        last_used_at: Time.utc - Matter::Fabric::EXPIRY - 1.second
      )

      fabric.expired?.should be_true

      # Fresh fabric should not be expired
      fresh = Matter::Fabric.new(
        fabric_id: 0x2_u64,
        fabric_index: 2_u8,
        node_id: 0x2_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk
      )

      fresh.expired?.should be_false
    end
  end

  describe "CaseAuthenticatedTag (CAT) support" do
    it "creates fabric with CATs" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      cats = [
        Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32),
        Matter::DataType::CaseAuthenticatedTag.new(0x56780002_u32),
      ]

      fabric = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk,
        cats: cats
      )

      fabric.cats.size.should eq(2)
      fabric.has_cats?.should be_true
      fabric.cats[0].value.should eq(0x12340001_u32)
      fabric.cats[1].value.should eq(0x56780002_u32)
    end

    it "defaults to empty CATs" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      fabric = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk
      )

      fabric.cats.should be_empty
      fabric.has_cats?.should be_false
    end

    it "validates max 3 CATs" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      cats = [
        Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32),
        Matter::DataType::CaseAuthenticatedTag.new(0x56780002_u32),
        Matter::DataType::CaseAuthenticatedTag.new(0x9ABC0003_u32),
        Matter::DataType::CaseAuthenticatedTag.new(0xDEF00004_u32), # 4th CAT - invalid
      ]

      expect_raises(ArgumentError, /cats must have <= 3 entries/) do
        Matter::Fabric.new(
          fabric_id: 0x1_u64,
          fabric_index: 1_u8,
          node_id: 0x1_u64,
          root_public_key: Random::Secure.random_bytes(65),
          operational_cert: Random::Secure.random_bytes(200),
          operational_key: key,
          ipk: ipk,
          cats: cats
        )
      end
    end

    it "returns CAT-encoded NodeIds" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      cats = [
        Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32),
        Matter::DataType::CaseAuthenticatedTag.new(0x56780002_u32),
      ]

      fabric = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk,
        cats: cats
      )

      cat_node_ids = fabric.cat_node_ids
      cat_node_ids.size.should eq(2)

      # CAT NodeId format: 0xFFFFFFFD + 32-bit CAT value
      cat_node_ids[0].should eq(0xFFFFFFFD12340001_u64)
      cat_node_ids[1].should eq(0xFFFFFFFD56780002_u64)
    end

    it "serializes and deserializes CATs" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      cats = [
        Matter::DataType::CaseAuthenticatedTag.new(0xABCD1234_u32),
        Matter::DataType::CaseAuthenticatedTag.new(0xEF567890_u32),
      ]

      original = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk,
        cats: cats
      )

      document = original.to_document
      document["cats"].should eq([0xABCD1234_i64, 0xEF567890_i64])

      restored = Matter::Fabric.from_document(document)
      restored.cats.size.should eq(2)
      restored.cats[0].value.should eq(0xABCD1234_u32)
      restored.cats[1].value.should eq(0xEF567890_u32)
    end

    it "handles empty CATs in serialization" do
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)

      original = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk
        # No cats specified - defaults to empty
      )

      document = original.to_document
      document["cats"].should eq([] of Matter::Storage::Type)

      restored = Matter::Fabric.from_document(document)
      restored.cats.should be_empty
    end
  end
end
