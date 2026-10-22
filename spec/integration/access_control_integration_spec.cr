require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/operational_credentials"
require "../../src/matter/fabric_table"

# Integration tests demonstrating real-world Access Control usage patterns
#
# These tests show how the Access Control cluster integrates with:
# - Operational Credentials (fabric management)
# - Attribute read/write enforcement
# - Multi-fabric isolation
# - Commissioning workflows

describe "Access Control Integration" do
  describe "commissioning workflow" do
    it "creates default ACL entry during commissioning" do
      # Setup: Create a device with Access Control cluster
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      # Initially no ACL entries
      acl_cluster.acl.should be_empty

      # Simulate commissioning: Add first fabric with admin subject
      admin_subject = 0x1122334455667788_u64
      fabric_index = 1_u8

      # During AddNOC, a default ACL entry is created
      default_acl = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [admin_subject],
        targets: nil, # All clusters/endpoints
        fabric_index: fabric_index
      )
      acl_cluster.acl << default_acl

      # Verify administrator has full access
      acl_cluster.check_access(
        subject: admin_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_true

      # Administrator can read any cluster
      acl_cluster.check_access(
        subject: admin_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
        cluster: 0x001D_u32 # Descriptor cluster
      ).should be_true

      # Administrator can write any cluster
      acl_cluster.check_access(
        subject: admin_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0006_u32 # On/Off cluster
      ).should be_true
    end

    it "enforces ACL for non-admin subjects" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      fabric_index = 1_u8
      admin_subject = 0x1111_u64
      viewer_subject = 0x2222_u64

      # Create admin ACL
      admin_acl = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [admin_subject],
        targets: nil,
        fabric_index: fabric_index
      )
      acl_cluster.acl << admin_acl

      # Create view-only ACL for another subject
      viewer_acl = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [viewer_subject],
        targets: nil,
        fabric_index: fabric_index
      )
      acl_cluster.acl << viewer_acl

      # Viewer can read
      acl_cluster.check_access(
        subject: viewer_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_true

      # Viewer cannot write
      acl_cluster.check_access(
        subject: viewer_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage
      ).should be_false

      # Admin can still do everything
      acl_cluster.check_access(
        subject: admin_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_true
    end
  end

  describe "multi-fabric isolation" do
    it "isolates ACLs between fabrics" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      # Same subject ID on two different fabrics
      subject = 0x1111_u64
      fabric1 = 1_u8
      fabric2 = 2_u8

      # Subject is admin on fabric 1
      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [subject],
        targets: nil,
        fabric_index: fabric1
      )

      # Subject is view-only on fabric 2
      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [subject],
        targets: nil,
        fabric_index: fabric2
      )

      # On fabric 1, subject has admin rights
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric1,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_true

      # On fabric 2, subject only has view rights
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric2,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
      ).should be_true

      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric2,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage
      ).should be_false

      # Subject on fabric 1 cannot access fabric 2's resources
      # (This would be enforced at a higher level by filtering ACLs by fabric)
      fabric1_acls = acl_cluster.get_acl_for_fabric(fabric1)
      fabric1_acls.size.should eq(1)
      fabric1_acls[0].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer)

      fabric2_acls = acl_cluster.get_acl_for_fabric(fabric2)
      fabric2_acls.size.should eq(1)
      fabric2_acls[0].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View)
    end

    it "removes fabric ACLs when fabric is removed" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      # Add ACLs for three fabrics
      3.times do |i|
        fabric_index = (i + 1).to_u8
        acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [0x1111_u64],
          targets: nil,
          fabric_index: fabric_index
        )
      end

      acl_cluster.acl.size.should eq(3)

      # Remove fabric 2
      acl_cluster.remove_fabric_acl(2_u8)

      # Should only have 2 ACLs left
      acl_cluster.acl.size.should eq(2)
      acl_cluster.acl.none? { |entry| entry.fabric_index == 2_u8 }.should be_true

      # Fabric 1 and 3 should still be present
      acl_cluster.get_acl_for_fabric(1_u8).size.should eq(1)
      acl_cluster.get_acl_for_fabric(3_u8).size.should eq(1)
    end
  end

  describe "target-specific access control" do
    it "restricts access to specific clusters" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      subject = 0x1111_u64
      fabric_index = 1_u8

      # Subject can only manage the On/Off cluster (0x0006)
      on_off_target = Matter::Cluster::AccessControl::Target.new(
        cluster: 0x0006_u32,
        endpoint: nil,
        device_type: nil
      )

      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [subject],
        targets: [on_off_target],
        fabric_index: fabric_index
      )

      # Can manage On/Off cluster
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0006_u32
      ).should be_true

      # Cannot manage Level Control cluster (0x0008)
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0008_u32
      ).should be_false
    end

    it "restricts access to specific endpoints" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      subject = 0x2222_u64
      fabric_index = 1_u8

      # Subject can only access endpoint 1
      endpoint_target = Matter::Cluster::AccessControl::Target.new(
        cluster: nil,
        endpoint: 1_u16,
        device_type: nil
      )

      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [subject],
        targets: [endpoint_target],
        fabric_index: fabric_index
      )

      # Can operate on endpoint 1
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        endpoint: 1_u16
      ).should be_true

      # Cannot operate on endpoint 2
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        endpoint: 2_u16
      ).should be_false
    end

    it "allows multiple targets in single ACL entry" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      subject = 0x3333_u64
      fabric_index = 1_u8

      # Subject can manage On/Off (0x0006) and Level Control (0x0008) on endpoint 1
      targets = [
        Matter::Cluster::AccessControl::Target.new(
          cluster: 0x0006_u32,
          endpoint: 1_u16,
          device_type: nil
        ),
        Matter::Cluster::AccessControl::Target.new(
          cluster: 0x0008_u32,
          endpoint: 1_u16,
          device_type: nil
        ),
      ]

      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [subject],
        targets: targets,
        fabric_index: fabric_index
      )

      # Can manage On/Off on endpoint 1
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0006_u32,
        endpoint: 1_u16
      ).should be_true

      # Can manage Level Control on endpoint 1
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0008_u32,
        endpoint: 1_u16
      ).should be_true

      # Cannot manage On/Off on endpoint 2
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0006_u32,
        endpoint: 2_u16
      ).should be_false

      # Cannot manage Color Control cluster
      acl_cluster.check_access(
        subject: subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0300_u32,
        endpoint: 1_u16
      ).should be_false
    end
  end

  describe "ACL attribute read/write via TLV" do
    it "allows admin to read and update ACL list" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      fabric_index = 1_u8
      admin_subject = 0xAAAA_u64

      # Create initial ACL
      initial_acl = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [admin_subject],
        targets: nil,
        fabric_index: fabric_index
      )
      acl_cluster.acl << initial_acl

      # Admin reads ACL list
      read_tlv(acl_cluster, Matter::Cluster::AccessControl::ATTR_ACL).to_slice.size.should be > 0

      # Admin adds a new user with Operate privilege
      new_user_subject = 0xBBBB_u64

      # Create new ACL list with both entries
      new_acl_list = [
        initial_acl,
        Matter::Cluster::AccessControl::AccessControlEntry.new(
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
          auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [new_user_subject],
          targets: nil,
          fabric_index: fabric_index
        ),
      ]

      # Encode the new ACL list
      acl_cluster.acl.clear
      new_acl_list.each { |entry| acl_cluster.acl << entry }
      encoded_new_acl = read_tlv(acl_cluster, Matter::Cluster::AccessControl::ATTR_ACL)

      # Write the updated ACL list
      acl_cluster.acl.clear
      status = write(acl_cluster, Matter::Cluster::AccessControl::ATTR_ACL, encoded_new_acl,
        is_case_session: true, fabric_index: fabric_index, peer_subject_ids: [admin_subject])
      status.status.should eq(Matter::InteractionModel::StatusCode::Success)

      # Verify both users now have access
      acl_cluster.acl.size.should eq(2)

      acl_cluster.check_access(
        subject: admin_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_true

      acl_cluster.check_access(
        subject: new_user_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate
      ).should be_true

      # New user cannot administer
      acl_cluster.check_access(
        subject: new_user_subject,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_false
    end

    it "persists ACL across encode/decode cycles" do
      endpoint_id = endpoint(0)
      cluster1 = Matter::Cluster::AccessControl.new(endpoint_id)

      # Create complex ACL with multiple entries and targets
      cluster1.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64, 0x2222_u64],
        targets: nil,
        fabric_index: 1_u8
      )

      targets = [
        Matter::Cluster::AccessControl::Target.new(
          cluster: 0x0006_u32,
          endpoint: 1_u16,
          device_type: nil
        ),
      ]

      cluster1.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x3333_u64],
        targets: targets,
        fabric_index: 1_u8
      )

      # Encode
      encoded = read_tlv(cluster1, Matter::Cluster::AccessControl::ATTR_ACL)

      # Decode into new cluster
      cluster2 = Matter::Cluster::AccessControl.new(endpoint_id)
      status = write(cluster2, Matter::Cluster::AccessControl::ATTR_ACL, encoded,
        is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1111_u64])
      status.status.should eq(Matter::InteractionModel::StatusCode::Success)

      # Verify all entries match
      cluster2.acl.size.should eq(2)

      # First entry
      cluster2.acl[0].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer)
      cluster2.acl[0].auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)
      cluster2.acl[0].subjects.should eq([0x1111_u64, 0x2222_u64])
      cluster2.acl[0].targets.should be_nil
      cluster2.acl[0].fabric_index.should eq(1_u8)

      # Second entry
      cluster2.acl[1].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage)
      cluster2.acl[1].auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)
      cluster2.acl[1].subjects.should eq([0x3333_u64])
      cluster2.acl[1].targets.as(Array(Matter::Cluster::AccessControl::Target)).size.should eq(1)
      cluster2.acl[1].targets.as(Array(Matter::Cluster::AccessControl::Target))[0].cluster.should eq(0x0006_u32)
      cluster2.acl[1].fabric_index.should eq(1_u8)

      # Access control decisions should be identical
      cluster2.check_access(
        subject: 0x1111_u64,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_true

      cluster2.check_access(
        subject: 0x3333_u64,
        fabric_index: 1_u8,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        cluster: 0x0006_u32,
        endpoint: 1_u16
      ).should be_true
    end
  end

  describe "privilege hierarchy" do
    it "demonstrates privilege levels in practice" do
      endpoint_id = endpoint(0)
      acl_cluster = Matter::Cluster::AccessControl.new(endpoint_id)

      fabric_index = 1_u8

      # Create users with different privilege levels
      admin = 0x1111_u64
      manager = 0x2222_u64
      operator = 0x3333_u64
      viewer = 0x4444_u64

      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [admin],
        targets: nil,
        fabric_index: fabric_index
      )

      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [manager],
        targets: nil,
        fabric_index: fabric_index
      )

      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [operator],
        targets: nil,
        fabric_index: fabric_index
      )

      acl_cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [viewer],
        targets: nil,
        fabric_index: fabric_index
      )

      # View privilege: Everyone can view
      [admin, manager, operator, viewer].each do |subject|
        acl_cluster.check_access(
          subject: subject,
          fabric_index: fabric_index,
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
        ).should be_true
      end

      # Operate privilege: Admin, Manager, Operator can operate (not Viewer)
      [admin, manager, operator].each do |subject|
        acl_cluster.check_access(
          subject: subject,
          fabric_index: fabric_index,
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate
        ).should be_true
      end

      acl_cluster.check_access(
        subject: viewer,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate
      ).should be_false

      # Manage privilege: Admin and Manager can manage (not Operator or Viewer)
      [admin, manager].each do |subject|
        acl_cluster.check_access(
          subject: subject,
          fabric_index: fabric_index,
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage
        ).should be_true
      end

      [operator, viewer].each do |subject|
        acl_cluster.check_access(
          subject: subject,
          fabric_index: fabric_index,
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage
        ).should be_false
      end

      # Administer privilege: Only Admin can administer
      acl_cluster.check_access(
        subject: admin,
        fabric_index: fabric_index,
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
      ).should be_true

      [manager, operator, viewer].each do |subject|
        acl_cluster.check_access(
          subject: subject,
          fabric_index: fabric_index,
          privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer
        ).should be_false
      end
    end
  end
end
