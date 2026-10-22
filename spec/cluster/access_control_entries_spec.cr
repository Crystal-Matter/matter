require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/protocol/im_handler"

describe Matter::Cluster::AccessControl do
  describe "initialization" do
    it "creates access control cluster" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      cluster.cluster_id.id.should eq(0x001F_u32)
      cluster.name.should eq("AccessControl")
      cluster.acl.should be_empty
      cluster.extension.should be_empty
      cluster.subjects_per_access_control_entry.should eq(4_u16)
      cluster.targets_per_access_control_entry.should eq(3_u16)
      cluster.access_control_entries_per_fabric.should eq(4_u16)
    end
  end

  describe "attributes" do
    it "reads ACL attribute when empty" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      value = read_tlv(cluster, Matter::Cluster::AccessControl::ATTR_ACL)
      # Empty list should be encoded as empty TLV array (not just Bytes.new(0))
      value.to_slice.size.should be > 0
    end

    it "reads Extension attribute" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      value = cluster.read_attribute(Matter::Cluster::AccessControl::ATTR_EXTENSION)
      value.should be_a(TLV::Any)
    end

    it "reads SubjectsPerAccessControlEntry attribute" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      read(cluster, Matter::Cluster::AccessControl::ATTR_SUBJECTS_PER_ACCESS_CONTROL_ENTRY).should eq(4_u16)
    end

    it "reads TargetsPerAccessControlEntry attribute" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      read(cluster, Matter::Cluster::AccessControl::ATTR_TARGETS_PER_ACCESS_CONTROL_ENTRY).should eq(3_u16)
    end

    it "reads AccessControlEntriesPerFabric attribute" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      read(cluster, Matter::Cluster::AccessControl::ATTR_ACCESS_CONTROL_ENTRIES_PER_FABRIC).should eq(4_u16)
    end

    it "returns status for unsupported attribute write" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      status = write(cluster,
        Matter::Cluster::AccessControl::ATTR_SUBJECTS_PER_ACCESS_CONTROL_ENTRY,
        Bytes[10, 0]
      )

      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  describe "metadata" do
    it "provides attribute metadata" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      attributes = cluster.attributes
      attributes.should_not be_empty
      attributes.size.should be >= 5

      acl_attr = attributes.find { |attr| attr.id.id == Matter::Cluster::AccessControl::ATTR_ACL }
      acl_attr.should_not be_nil
      acl_attribute = acl_attr.as(Matter::Cluster::AttributeMetadata)
      acl_attribute.name.should eq("acl")
      acl_attribute.writable?.should be_true
    end
  end

  describe "AccessControlEntry" do
    it "creates access control entry" do
      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1122334455667788_u64],
        targets: nil,
        fabric_index: 1_u8
      )

      entry.privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer)
      entry.auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)
      entry.subjects.should eq([0x1122334455667788_u64])
      entry.targets.should be_nil
      entry.fabric_index.should eq(1_u8)
    end

    it "creates entry with multiple subjects" do
      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64, 0x2222_u64, 0x3333_u64],
        targets: nil,
        fabric_index: 1_u8
      )

      entry.subjects.try(&.size).should eq(3)
    end

    it "creates entry with targets" do
      target = Matter::Cluster::AccessControl::Target.new(
        cluster: 0x0006_u32,
        endpoint: 1_u16,
        device_type: nil
      )

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x4444_u64],
        targets: [target],
        fabric_index: 1_u8
      )

      targets = entry.targets
      targets.should_not be_nil
      targets.as(Array).size.should eq(1)
    end
  end

  describe "Target" do
    it "creates cluster target" do
      target = Matter::Cluster::AccessControl::Target.new(
        cluster: 0x0006_u32,
        endpoint: nil,
        device_type: nil
      )

      target.cluster.should eq(0x0006_u32)
      target.endpoint.should be_nil
      target.device_type.should be_nil
    end

    it "creates endpoint target" do
      target = Matter::Cluster::AccessControl::Target.new(
        cluster: nil,
        endpoint: 1_u16,
        device_type: nil
      )

      target.cluster.should be_nil
      target.endpoint.should eq(1_u16)
      target.device_type.should be_nil
    end

    it "creates device type target" do
      target = Matter::Cluster::AccessControl::Target.new(
        cluster: nil,
        endpoint: nil,
        device_type: 0x0100_u32
      )

      target.cluster.should be_nil
      target.endpoint.should be_nil
      target.device_type.should eq(0x0100_u32)
    end
  end

  describe "AccessControlEntryPrivilege" do
    it "defines privilege levels" do
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View.value.should eq(1_u8)
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::ProxyView.value.should eq(2_u8)
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate.value.should eq(3_u8)
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage.value.should eq(4_u8)
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer.value.should eq(5_u8)
    end
  end

  describe "AccessControlEntryAuthMode" do
    it "defines auth modes" do
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::PASE.value.should eq(1_u8)
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE.value.should eq(2_u8)
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::Group.value.should eq(3_u8)
    end
  end

  describe "ACL management" do
    it "adds ACL entry" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64],
        targets: nil,
        fabric_index: 1_u8
      )

      cluster.acl << entry
      cluster.acl.size.should eq(1)
    end

    it "tracks multiple ACL entries" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      3.times do |i|
        entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [(i + 1).to_u64],
          targets: nil,
          fabric_index: 1_u8
        )
        cluster.acl << entry
      end

      cluster.acl.size.should eq(3)
    end
  end

  describe "extension entries" do
    it "stores extension entries" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      extension = Matter::Cluster::AccessControl::ExtensionEntry.new(
        data: Bytes[0x01, 0x02, 0x03],
        fabric_index: 1_u8
      )

      cluster.extension << extension
      cluster.extension.size.should eq(1)
    end
  end

  describe "access checking" do
    it "checks if subject has access" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      has_access = cluster.check_access(
        subject: 0x1111_u64,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      )

      has_access.should be_true
    end

    it "denies access for non-matching subject" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      has_access = cluster.check_access(
        subject: 0x2222_u64,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      )

      has_access.should be_false
    end

    it "checks privilege hierarchy" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      # User has Operate privilege
      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      # Should have View access (lower privilege)
      cluster.check_access(
        subject: 0x1111_u64,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_true

      # Should NOT have Administer access (higher privilege)
      cluster.check_access(
        subject: 0x1111_u64,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_false
    end
  end

  describe "CaseAuthenticatedTag (CAT) subject matching" do
    it "matches CAT subjects with same identity and version" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      # Create CAT-encoded subject (identity=0x1234, version=0x0001)
      cat = Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32)
      cat_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(cat)

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [cat_node_id.id],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      # Should match with same identity and version
      cluster.check_access(
        subject: cat_node_id.id,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_true
    end

    it "matches CAT subjects when incoming version is higher" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      # ACL has CAT with version 0x0001
      acl_cat = Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32)
      acl_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(acl_cat)

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [acl_node_id.id],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      # Incoming request has CAT with version 0x0005 (higher than ACL version)
      incoming_cat = Matter::DataType::CaseAuthenticatedTag.new(0x12340005_u32)
      incoming_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(incoming_cat)

      cluster.check_access(
        subject: incoming_node_id.id,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_true
    end

    it "denies CAT subjects when incoming version is lower" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      # ACL has CAT with version 0x0005
      acl_cat = Matter::DataType::CaseAuthenticatedTag.new(0x12340005_u32)
      acl_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(acl_cat)

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [acl_node_id.id],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      # Incoming request has CAT with version 0x0001 (lower than ACL version)
      incoming_cat = Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32)
      incoming_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(incoming_cat)

      cluster.check_access(
        subject: incoming_node_id.id,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_false
    end

    it "denies CAT subjects with different identity" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      # ACL has CAT with identity 0x1234
      acl_cat = Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32)
      acl_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(acl_cat)

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [acl_node_id.id],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      # Incoming request has CAT with different identity 0x5678
      incoming_cat = Matter::DataType::CaseAuthenticatedTag.new(0x56780001_u32)
      incoming_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(incoming_cat)

      cluster.check_access(
        subject: incoming_node_id.id,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_false
    end

    it "requires exact match when mixing CAT and regular NodeIds" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      # ACL has regular NodeId
      regular_node_id = 0x1122334455667788_u64

      entry = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [regular_node_id],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry

      # Incoming request with CAT-encoded NodeId should not match
      cat = Matter::DataType::CaseAuthenticatedTag.new(0x12340001_u32)
      cat_node_id = Matter::DataType::NodeId.from_case_authenticated_tag(cat)

      cluster.check_access(
        subject: cat_node_id.id,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_false

      # Regular NodeId should still match exactly
      cluster.check_access(
        subject: regular_node_id,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_true
    end
  end

  describe "fabric isolation" do
    it "isolates ACL entries by fabric" do
      cluster = build(Matter::Cluster::AccessControl, 0)

      # Entry for fabric 1
      entry1 = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64],
        targets: nil,
        fabric_index: 1_u8
      )
      cluster.acl << entry1

      # Entry for fabric 2
      entry2 = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64],
        targets: nil,
        fabric_index: 2_u8
      )
      cluster.acl << entry2

      # Subject should have different privileges on different fabrics
      cluster.check_access(
        subject: 0x1111_u64,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_true

      cluster.check_access(
        subject: 0x1111_u64,
        fabric_index: 2_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_false
    end
  end
end
