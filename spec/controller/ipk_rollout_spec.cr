require "../spec_helper"
require "../../src/matter/controller"

private alias Rollout = Matter::Controller::IpkRollout
private alias RolloutStore = Matter::Cluster::JointFabricDatastore

private def rollout_key_set(first : UInt8, second : UInt8, third : UInt8? = nil) : RolloutStore::DatastoreGroupKeySetStruct
  RolloutStore::DatastoreGroupKeySetStruct.new(0_u16,
    RolloutStore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
    Bytes.new(16, first), 1_u64, Bytes.new(16, second), 2_u64,
    third.try { |value| Bytes.new(16, value) }, third ? 3_u64 : nil)
end

private def rollout_status(state : RolloutStore::DatastoreStateEnum) : RolloutStore::DatastoreStatusEntryStruct
  RolloutStore::DatastoreStatusEntryStruct.new(state, 1_u32, 0_u8)
end

private def rollout_store(state : RolloutStore::DatastoreStateEnum) : RolloutStore
  store = RolloutStore.new(Matter::DataType::EndpointNumber.new(1_u16))
  store.anchor_root_ca = Bytes.new(8, 0xAB_u8)
  store.anchor_node_id = 1_u64
  store.group_key_set_list = [rollout_key_set(0x11_u8, 0x22_u8)]
  store.node_list = [RolloutStore::DatastoreNodeInformationEntryStruct.new(2_u64, "target", rollout_status(RolloutStore::DatastoreStateEnum::Committed))]
  store.node_key_set_list = [RolloutStore::DatastoreNodeKeySetEntryStruct.new(2_u64, 0_u16, rollout_status(state))]
  store.admin_list = [
    RolloutStore::DatastoreAdministratorInformationEntryStruct.new(1_u64, "Anchor", 1_u16, Bytes.empty),
    RolloutStore::DatastoreAdministratorInformationEntryStruct.new(3_u64, "peer", 1_u16, Bytes.empty),
  ]
  store
end

describe Rollout do
  it "blocks eviction while an offline ordinary node has CommitFailed and allows retry after delivery" do
    store = rollout_store(RolloutStore::DatastoreStateEnum::CommitFailed)
    current = store.group_key_set_list.first
    ack = Rollout.acknowledgment(3_u64, 0x1234_u64, store.anchor_root_ca, current)
    candidate = rollout_key_set(0x22_u8, 0x33_u8, 0x44_u8)

    expect_raises(Matter::ConfigurationError, /node 2/) do
      Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate, [ack])
    end
    store.node_key_set_list = [RolloutStore::DatastoreNodeKeySetEntryStruct.new(2_u64, 0_u16,
      rollout_status(RolloutStore::DatastoreStateEnum::Committed))]
    Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate, [ack])
  end

  it "blocks eviction until every Administrator has acknowledged the exact current key set" do
    store = rollout_store(RolloutStore::DatastoreStateEnum::Committed)
    store.admin_list += [RolloutStore::DatastoreAdministratorInformationEntryStruct.new(
      4_u64, "offline peer", 1_u16, Bytes.empty)]
    candidate = rollout_key_set(0x22_u8, 0x33_u8, 0x44_u8)
    expect_raises(Matter::ConfigurationError, /Administrator 3/) do
      Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate,
        [] of Rollout::AdministratorAcknowledgment)
    end

    stale = Rollout.acknowledgment(3_u64, 0x1234_u64, store.anchor_root_ca,
      rollout_key_set(0x11_u8, 0x33_u8))
    expect_raises(Matter::ConfigurationError, /Administrator 3/) do
      Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate, [stale])
    end
    wrong_fabric = Rollout.acknowledgment(3_u64, 0x5678_u64, store.anchor_root_ca,
      store.group_key_set_list.first)
    expect_raises(Matter::ConfigurationError, /Administrator 3/) do
      Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate, [wrong_fabric])
    end
    wrong_root = Rollout.acknowledgment(3_u64, 0x1234_u64, Bytes.new(8, 0xCD_u8),
      store.group_key_set_list.first)
    expect_raises(Matter::ConfigurationError, /Administrator 3/) do
      Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate, [wrong_root])
    end
    current = Rollout.acknowledgment(3_u64, 0x1234_u64, store.anchor_root_ca,
      store.group_key_set_list.first)
    expect_raises(Matter::ConfigurationError, /Administrator 4/) do
      Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate, [current])
    end
    reconnected = Rollout.acknowledgment(4_u64, 0x1234_u64, store.anchor_root_ca,
      store.group_key_set_list.first)
    Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca, candidate, [current, reconnected])
  end

  it "does not require acknowledgments when an update retains all existing epochs" do
    store = rollout_store(RolloutStore::DatastoreStateEnum::CommitFailed)
    Rollout.preflight_eviction!(store, 0x1234_u64, store.anchor_root_ca,
      rollout_key_set(0x11_u8, 0x22_u8, 0x33_u8), [] of Rollout::AdministratorAcknowledgment)
  end

  it "does not invoke the host update until offline participants are ready" do
    store = rollout_store(RolloutStore::DatastoreStateEnum::CommitFailed)
    updates = 0
    store.on_ipk_key_set_updated = ->(_datastore : RolloutStore, _key_set : RolloutStore::DatastoreGroupKeySetStruct) do
      updates += 1
    end
    original = store.group_key_set_list.first
    candidate = rollout_key_set(0x22_u8, 0x33_u8, 0x44_u8)
    ack = Rollout.acknowledgment(3_u64, 0x1234_u64, store.anchor_root_ca, original)
    expect_raises(Matter::ConfigurationError, /node 2/) do
      Rollout.update_key_set_safely(store, 0x1234_u64, store.anchor_root_ca, candidate, [ack])
    end
    updates.should eq(0)
    store.group_key_set_list.first.should eq(original)

    store.node_key_set_list = [RolloutStore::DatastoreNodeKeySetEntryStruct.new(2_u64, 0_u16,
      rollout_status(RolloutStore::DatastoreStateEnum::Committed))]
    Rollout.update_key_set_safely(store, 0x1234_u64, store.anchor_root_ca, candidate, [ack]).success?.should be_true
    updates.should eq(1)
    store.group_key_set_list.first.should eq(candidate)
  end
end
