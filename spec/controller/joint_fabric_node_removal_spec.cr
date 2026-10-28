require "../spec_helper"
require "../../src/matter/controller/joint_fabric_node_removal"

private alias Removal = Matter::Controller::JointFabricNodeRemoval
private alias Datastore = Matter::Cluster::JointFabricDatastore

private class RemovalPort < Removal::Port
  getter calls = [] of String
  property? cleanup_present : Bool = true
  property? cleanup_failed : Bool = false
  property? lose_cleanup_response : Bool = false
  property? grants_present : Bool = true
  property? node_present : Bool = true
  property? lose_remove_response : Bool = false

  def snapshot_cleanup(journal : Removal::Journal) : Removal::CleanupSnapshot
    @calls << "snapshot-cleanup"
    Removal::CleanupSnapshot.new(
      [Removal::GroupCleanup.new(journal.node_id, 1_u16, 7_u16)],
      [Removal::BindingCleanup.new(0xA202_u64, 1_u16, 9_u16,
        Datastore::DatastoreBindingTargetStruct.new(node: journal.node_id, endpoint: 1_u16), Bytes[3])],
      [7_u16])
  end

  def cleanup!(journal : Removal::Journal) : Nil
    @calls << "cleanup"
    if @lose_cleanup_response
      @cleanup_present = false
      @lose_cleanup_response = false
      raise Matter::TransportError.new("Cleanup response lost")
    end
  end

  def cleanup_complete?(journal : Removal::Journal) : Bool
    @calls << "verify-cleanup"
    !@cleanup_present && !@cleanup_failed
  end

  def revoke_direct_access!(journal : Removal::Journal) : Nil
    @calls << "revoke"
  end

  def access_revoked?(journal : Removal::Journal) : Bool
    @calls << "verify-revoked"
    !@grants_present
  end

  def remove_node!(journal : Removal::Journal) : Nil
    @calls << "remove"
    @node_present = false
    raise Matter::TransportError.new("RemoveNode response lost") if @lose_remove_response
  end

  def node_absent?(journal : Removal::Journal) : Bool
    @calls << "verify-absent"
    !@node_present
  end
end

describe Removal do
  it "includes bindings owned by or pointing to the removed node" do
    status = Datastore::DatastoreStatusEntryStruct.new(
      Datastore::DatastoreStateEnum::Committed, 1_u32, Datastore::NO_FAILURE_CODE)
    target_id = 0xA201_u64
    own = Datastore::DatastoreEndpointBindingEntryStruct.new(target_id, 1_u16, 1_u16,
      Datastore::DatastoreBindingTargetStruct.new(node: 0xA202_u64), status)
    incoming = Datastore::DatastoreEndpointBindingEntryStruct.new(0xA202_u64, 1_u16, 2_u16,
      Datastore::DatastoreBindingTargetStruct.new(node: target_id), status)
    unrelated = Datastore::DatastoreEndpointBindingEntryStruct.new(0xA202_u64, 1_u16, 3_u16,
      Datastore::DatastoreBindingTargetStruct.new(node: 0xA203_u64), status)
    Removal::NetworkPort.cleanup_binding?(own, target_id).should be_true
    Removal::NetworkPort.cleanup_binding?(incoming, target_id).should be_true
    Removal::NetworkPort.cleanup_binding?(unrelated, target_id).should be_false
  end

  it "waits for non-IPK key sets while leaving IPK cleanup to RemoveNode" do
    status = Datastore::DatastoreStatusEntryStruct.new(
      Datastore::DatastoreStateEnum::Committed, 1_u32, Datastore::NO_FAILURE_CODE)
    ipk = Datastore::DatastoreNodeKeySetEntryStruct.new(0xA201_u64, Datastore::IPK_KEY_SET_ID, status)
    group_key = Datastore::DatastoreNodeKeySetEntryStruct.new(0xA201_u64, 7_u16, status)
    Removal::NetworkPort.cleanup_key_set?(ipk, 0xA201_u64).should be_false
    Removal::NetworkPort.cleanup_key_set?(group_key, 0xA201_u64).should be_true
  end

  it "never treats a numeric Group subject as a direct Node ID grant" do
    node_id = 0xA201_u64
    group_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::Group,
      [node_id], nil)
    case_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE,
      [node_id], nil)
    Removal::NetworkPort.direct_grant?(group_acl, node_id).should be_false
    Removal::NetworkPort.direct_grant?(case_acl, node_id).should be_true
  end

  it "waits for access revocation before sending RemoveNode" do
    backend = Matter::Storage::Memory.new
    store = Removal::JournalStore.new(backend)
    journal = store.load_or_create(Removal::Journal.new(0xA001_u64, Bytes[1],
      0xA101_u64, 0xA102_u64, 0xA201_u64, "Lamp", Bytes[2]))
    port = RemovalPort.new
    workflow = Removal::Workflow.new(journal, port, store)
    expect_raises(Matter::CommissioningError, /cleanup.*pending/) { workflow.run }
    port.calls.should eq(["snapshot-cleanup", "cleanup", "verify-cleanup"])
    store.load_or_create(journal).cleanup_recorded?.should be_true

    port.cleanup_present = false
    expect_raises(Matter::CommissioningError, /pending delivery/) { workflow.run }
    port.calls.last(4).should eq(["cleanup", "verify-cleanup", "revoke", "verify-revoked"])
    store.load_or_create(journal).stage.should eq(Removal::Stage::Revoking)

    port.grants_present = false
    workflow.run
    port.calls.last(6).should eq(["cleanup", "verify-cleanup", "revoke", "verify-revoked", "remove", "verify-absent"])
    workflow.journal.stage.should eq(Removal::Stage::Complete)
  end

  it "reconciles a committed RemoveNode after its response is lost without replay" do
    path = File.join(Dir.tempdir, "matter-node-removal-#{Random::Secure.hex(8)}.json")
    begin
      first_backend = Matter::Storage::JsonFile.new(path)
      store = Removal::JournalStore.new(first_backend)
      initial = Removal::Journal.new(0xA001_u64, Bytes[1],
        0xA101_u64, 0xA102_u64, 0xA201_u64, "Lamp", Bytes[2])
      journal = store.load_or_create(initial)
      port = RemovalPort.new
      port.grants_present = false
      port.cleanup_present = false
      port.lose_remove_response = true
      workflow = Removal::Workflow.new(journal, port, store)
      expect_raises(Matter::TransportError, /response lost/) { workflow.run }
      workflow.journal.stage.should eq(Removal::Stage::Removing)
      first_backend.close

      second_backend = Matter::Storage::JsonFile.new(path)
      restarted_store = Removal::JournalStore.new(second_backend)
      recovered = restarted_store.load(initial.fabric_id, initial.root_public_key,
        initial.controller_node_id, initial.node_id).as(Removal::Journal)
      restarted = Removal::Workflow.new(recovered, port, restarted_store)
      expect_raises(Matter::CommissioningError, /authenticated reconciliation/) { restarted.run }
      restarted.reconcile_removed!
      restarted.journal.stage.should eq(Removal::Stage::Complete)
      port.calls.count("remove").should eq(1)
      second_backend.close
    ensure
      File.delete?(path)
    end
  end

  it "keeps a failed cleanup deletion ahead of ACL and RemoveNode across restart" do
    path = File.join(Dir.tempdir, "matter-node-cleanup-#{Random::Secure.hex(8)}.json")
    begin
      first = Matter::Storage::JsonFile.new(path)
      first_store = Removal::JournalStore.new(first)
      initial = Removal::Journal.new(0xA001_u64, Bytes[1],
        0xA101_u64, 0xA102_u64, 0xA201_u64, "Lamp", Bytes[2])
      journal = first_store.load_or_create(initial)
      port = RemovalPort.new
      port.cleanup_failed = true
      expect_raises(Matter::CommissioningError, /cleanup.*pending/) do
        Removal::Workflow.new(journal, port, first_store).run
      end
      port.calls.should_not contain("revoke")
      port.calls.should_not contain("remove")
      first.close

      second = Matter::Storage::JsonFile.new(path)
      second_store = Removal::JournalStore.new(second)
      resumed = second_store.load(initial.fabric_id, initial.root_public_key,
        initial.controller_node_id, initial.node_id).as(Removal::Journal)
      resumed.cleanup_recorded?.should be_true
      resumed.cleanup_groups.size.should eq(1)
      resumed.cleanup_bindings.size.should eq(1)
      resumed.cleanup_bindings.first.binding.node.should eq(initial.node_id)
      resumed.cleanup_key_set_ids.should eq([7_u16])
      port.cleanup_failed = false
      port.cleanup_present = false
      port.grants_present = false
      Removal::Workflow.new(resumed, port, second_store).run
      port.calls.count("snapshot-cleanup").should eq(1)
      port.calls.count("remove").should eq(1)
      second.close
    ensure
      File.delete?(path)
    end
  end

  it "recovers after a lost cleanup response without repeating the snapshot" do
    path = File.join(Dir.tempdir, "matter-cleanup-response-#{Random::Secure.hex(8)}.json")
    begin
      first = Matter::Storage::JsonFile.new(path)
      first_store = Removal::JournalStore.new(first)
      initial = Removal::Journal.new(0xA001_u64, Bytes[1],
        0xA101_u64, 0xA102_u64, 0xA201_u64, "Lamp", Bytes[2])
      journal = first_store.load_or_create(initial)
      port = RemovalPort.new
      port.lose_cleanup_response = true
      expect_raises(Matter::TransportError, /response lost/) do
        Removal::Workflow.new(journal, port, first_store).run
      end
      port.calls.should_not contain("remove")
      first.close

      second = Matter::Storage::JsonFile.new(path)
      second_store = Removal::JournalStore.new(second)
      resumed = second_store.load(initial.fabric_id, initial.root_public_key,
        initial.controller_node_id, initial.node_id).as(Removal::Journal)
      port.grants_present = false
      Removal::Workflow.new(resumed, port, second_store).run
      port.calls.count("snapshot-cleanup").should eq(1)
      port.calls.count("remove").should eq(1)
      second.close
    ensure
      File.delete?(path)
    end
  end

  it "rejects another node identity for the same durable removal" do
    backend = Matter::Storage::Memory.new
    store = Removal::JournalStore.new(backend)
    store.load_or_create(Removal::Journal.new(0xA001_u64, Bytes[1],
      0xA101_u64, 0xA102_u64, 0xA201_u64, "Lamp", Bytes[2]))
    expect_raises(Matter::StorageError, /identity changed/) do
      store.load_or_create(Removal::Journal.new(0xA001_u64, Bytes[1],
        0xA101_u64, 0xA102_u64, 0xA201_u64, "Replacement", Bytes[2]))
    end
  end
end
