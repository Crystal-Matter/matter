require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/protocol/im_handler"

# These tests isolate Access Control TLV round-tripping from IM authorization.
# A fabric-less PASE write is rejected by IM before reaching this decoder.
private def encoding_write(cluster : Matter::Cluster::AccessControl, attribute : UInt32, value) : Matter::InteractionModel::Status
  cluster.write_attribute(attribute, TLV::Serializable.serialize_value(value, nil))
end

private def extension_payload(value : UInt8) : Bytes
  TLV::Any.new(TLV::List{TLV::Any.new(value, {1_u16, 1_u16})}).to_slice
end

describe Matter::Cluster::AccessControl do
  describe "iPhone ACL write request" do
    # This is the actual decrypted WriteRequest payload captured from an iPhone during commissioning
    # The full TLV payload from the log is:
    # 1528002801360215370124020024031f2404001836021524010524020236030701001d32fdffffff060498fabe183404181524010324020236030701002b4ffdffffff18340418181818280324ff0c18
    it "parses ACL write request from iPhone" do
      # Full WriteRequest TLV payload (without the protocol header)
      write_request_hex = "1528002801360215370124020024031f2404001836021524010524020236030701001d32fdffffff060498fabe183404181524010324020236030701002b4ffdffffff18340418181818280324ff0c18"
      write_request_bytes = write_request_hex.hexbytes

      # Parse the WriteRequest using im_handler
      request = Matter::Protocol::IMHandler.parse_write_request(write_request_bytes)
      request.should_not be_nil
      write_req = request.as(Matter::InteractionModel::WriteRequestMessage)

      # Should have 1 write request
      write_requests = write_req.write_requests || [] of Matter::InteractionModel::AttributeDataIB
      write_requests.size.should eq(1)

      # Extract the value that will be passed to write_attribute (convert TLV::Any to bytes)
      acl_value = write_requests[0].data

      # Now try to decode it with the access control cluster
      cluster = build(Matter::Cluster::AccessControl, 0)

      status = encoding_write(cluster, Matter::Cluster::AccessControl::ATTR_ACL, acl_value)

      status.status.should eq(Matter::InteractionModel::StatusCode::Success)

      # Verify we got 2 ACL entries
      cluster.acl.size.should eq(2)

      # First entry should be Administer privilege
      cluster.acl[0].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer)
      cluster.acl[0].auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)

      # Second entry should be Operate privilege
      cluster.acl[1].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate)
      cluster.acl[1].auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)
    end

    it "decodes ACL TLV value directly" do
      # This is a minimal test case - just the ACL array portion encoded as TLV
      # Two entries: Administer with subject, Operate with subject
      cluster = build(Matter::Cluster::AccessControl, 0)

      # First, let's see what the encoded format looks like for a known entry
      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x12345678_u64],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)

      # Try round-trip
      cluster2 = build(Matter::Cluster::AccessControl, 0)
      status = encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_ACL, encoded)
      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster2.acl.size.should eq(1)
    end
  end

  describe "TLV encoding/decoding" do
    describe "ACL list" do
      it "encodes and decodes empty ACL list" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Read empty ACL list
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)

        # Write it back
        status = encoding_write(cluster, Matter::Cluster::AccessControl::ATTR_ACL, encoded)
        status.status.should eq(Matter::InteractionModel::StatusCode::Success)
        cluster.acl.should be_empty
      end

      it "encodes and decodes single ACL entry" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Add ACL entry
        entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [0x1111_u64],
          targets: nil,
          fabric_index: 1_u8
        )
        cluster.acl << entry

        # Encode
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)
        encoded.to_slice.size.should be > 0

        # Decode into new cluster
        cluster2 = build(Matter::Cluster::AccessControl, 0)
        status = encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_ACL, encoded)
        status.status.should eq(Matter::InteractionModel::StatusCode::Success)

        # Verify decoded entry
        cluster2.acl.size.should eq(1)
        decoded_entry = cluster2.acl[0]
        decoded_entry.privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer)
        decoded_entry.auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)
        decoded_entry.subjects.should eq([0x1111_u64])
        decoded_entry.targets.should be_nil
        decoded_entry.fabric_index.should eq(1_u8)
      end

      it "encodes and decodes ACL entry with multiple subjects" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Add ACL entry with multiple subjects
        entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [0x1111_u64, 0x2222_u64, 0x3333_u64],
          targets: nil,
          fabric_index: 2_u8
        )
        cluster.acl << entry

        # Round-trip
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)
        cluster2 = build(Matter::Cluster::AccessControl, 0)
        encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_ACL, encoded)

        # Verify
        cluster2.acl.size.should eq(1)
        cluster2.acl[0].subjects.try(&.size).should eq(3)
        cluster2.acl[0].subjects.should eq([0x1111_u64, 0x2222_u64, 0x3333_u64])
      end

      it "encodes and decodes ACL entry with targets" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Add ACL entry with targets
        targets = [
          Matter::Cluster::AccessControl::Target.new(
            cluster: 0x0006_u32,
            endpoint: 1_u16,
            device_type: nil
          ),
          Matter::Cluster::AccessControl::Target.new(
            cluster: nil,
            endpoint: nil,
            device_type: 0x0100_u32
          ),
        ]

        entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [0x4444_u64],
          targets: targets,
          fabric_index: 1_u8
        )
        cluster.acl << entry

        # Round-trip
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)
        cluster2 = build(Matter::Cluster::AccessControl, 0)
        encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_ACL, encoded)

        # Verify
        cluster2.acl.size.should eq(1)
        decoded_targets = cluster2.acl[0].targets
        decoded_targets.should_not be_nil
        targets_array = decoded_targets.as(Array)
        targets_array.size.should eq(2)

        # First target
        targets_array[0].cluster.should eq(0x0006_u32)
        targets_array[0].endpoint.should eq(1_u16)
        targets_array[0].device_type.should be_nil

        # Second target
        targets_array[1].cluster.should be_nil
        targets_array[1].endpoint.should be_nil
        targets_array[1].device_type.should eq(0x0100_u32)
      end

      it "encodes and decodes multiple ACL entries" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Add multiple entries
        3.times do |i|
          entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
            privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
            auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
            subjects: [(i + 1).to_u64 * 0x1111],
            targets: nil,
            fabric_index: 1_u8
          )
          cluster.acl << entry
        end

        # Round-trip
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)
        cluster2 = build(Matter::Cluster::AccessControl, 0)
        encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_ACL, encoded)

        # Verify
        cluster2.acl.size.should eq(3)
        cluster2.acl[0].subjects.should eq([0x1111_u64])
        cluster2.acl[1].subjects.should eq([0x2222_u64])
        cluster2.acl[2].subjects.should eq([0x3333_u64])
      end

      it "handles invalid TLV data gracefully" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Try to write invalid data
        invalid_data = Bytes[0xFF, 0xFF, 0xFF]
        status = encoding_write(cluster, Matter::Cluster::AccessControl::ATTR_ACL, invalid_data)

        status.status.should eq(Matter::InteractionModel::StatusCode::InvalidDataType)
      end
    end

    describe "Extension list" do
      it "encodes and decodes empty extension list" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Read empty extension list
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_EXTENSION)

        # Write it back
        status = encoding_write(cluster, Matter::Cluster::AccessControl::ATTR_EXTENSION, encoded)
        status.status.should eq(Matter::InteractionModel::StatusCode::Success)
        cluster.extension.should be_empty
      end

      it "encodes and decodes single extension entry" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Add extension entry
        extension = Matter::Cluster::AccessControl::ExtensionEntry.new(
          data: extension_payload(0x01_u8),
          fabric_index: 1_u8
        )
        cluster.extension << extension

        # Round-trip
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_EXTENSION)
        cluster2 = build(Matter::Cluster::AccessControl, 0)
        status = encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_EXTENSION, encoded)
        status.status.should eq(Matter::InteractionModel::StatusCode::Success)

        # Verify
        cluster2.extension.size.should eq(1)
        cluster2.extension[0].data.should eq(extension_payload(0x01_u8))
        cluster2.extension[0].fabric_index.should eq(1_u8)
      end

      it "encodes and decodes multiple extension entries" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Add multiple extensions
        cluster.extension << Matter::Cluster::AccessControl::ExtensionEntry.new(
          data: extension_payload(0xAA_u8),
          fabric_index: 1_u8
        )
        cluster.extension << Matter::Cluster::AccessControl::ExtensionEntry.new(
          data: extension_payload(0xCC_u8),
          fabric_index: 2_u8
        )

        # Round-trip
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_EXTENSION)
        cluster2 = build(Matter::Cluster::AccessControl, 0)
        encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_EXTENSION, encoded)

        # Verify
        cluster2.extension.size.should eq(2)
        cluster2.extension[0].data.should eq(extension_payload(0xAA_u8))
        cluster2.extension[0].fabric_index.should eq(1_u8)
        cluster2.extension[1].data.should eq(extension_payload(0xCC_u8))
        cluster2.extension[1].fabric_index.should eq(2_u8)
      end

      it "handles invalid TLV data gracefully" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Try to write invalid data
        invalid_data = Bytes[0xFF, 0xFF, 0xFF]
        status = encoding_write(cluster, Matter::Cluster::AccessControl::ATTR_EXTENSION, invalid_data)

        status.status.should eq(Matter::InteractionModel::StatusCode::InvalidDataType)
      end
    end

    describe "fabric-scoped encoding" do
      it "preserves fabric index in ACL entries" do
        cluster = build(Matter::Cluster::AccessControl, 0)

        # Add entries for different fabrics
        cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [0x1111_u64],
          targets: nil,
          fabric_index: 1_u8
        )
        cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [0x2222_u64],
          targets: nil,
          fabric_index: 2_u8
        )

        # Round-trip
        encoded = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)
        cluster2 = build(Matter::Cluster::AccessControl, 0)
        encoding_write(cluster2, Matter::Cluster::AccessControl::ATTR_ACL, encoded)

        # Verify fabric isolation is preserved
        cluster2.acl.size.should eq(2)
        cluster2.acl[0].fabric_index.should eq(1_u8)
        cluster2.acl[1].fabric_index.should eq(2_u8)
      end
    end
  end
end
