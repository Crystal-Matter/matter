require "../spec_helper"

private alias AtomicIcd = Matter::Cluster::IcdManagement
private alias AtomicIcdStatus = Matter::InteractionModel::StatusCode

private def atomic_icd_register(cluster : AtomicIcd, node_id : UInt64) : Matter::InteractionModel::Status | Matter::Cluster::CommandResponse
  request = AtomicIcd::RegisterClientRequest.new(node_id, node_id, Bytes.new(16, 1_u8),
    nil, AtomicIcd::ClientType::Permanent)
  invoke(cluster, AtomicIcd::CMD_REGISTER_CLIENT, request, is_case_session: true,
    fabric_index: Matter::Fabric::MIN_FABRIC_INDEX)
end

private def atomic_icd_unregister(cluster : AtomicIcd, node_id : UInt64) : Matter::InteractionModel::Status | Matter::Cluster::CommandResponse
  request = AtomicIcd::UnregisterClientRequest.new(node_id, nil)
  invoke(cluster, AtomicIcd::CMD_UNREGISTER_CLIENT, request, is_case_session: true,
    fabric_index: Matter::Fabric::MIN_FABRIC_INDEX)
end

describe "ICD Management registration durability" do
  it "keeps registration state and notifications unchanged when RegisterClient persistence fails" do
    cluster = build(AtomicIcd, 0, feature_map: AtomicIcd::Feature::CheckInProtocolSupport)
    cluster.request_administer_privilege = true
    versions = 0
    attributes = 0
    modes = 0
    cluster.on_version_changed = -> { versions += 1; nil }
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) do
      attribute.should eq(AtomicIcd::ATTR_REGISTERED_CLIENTS)
      attributes += 1
      nil
    end
    cluster.on_operating_mode_changed = -> { modes += 1; nil }
    cluster.on_persist_registration = -> { false }
    before_state = cluster.save_state
    before_version = cluster.data_version

    expect_status(atomic_icd_register(cluster, 123_u64), AtomicIcdStatus::Failure)

    cluster.registered_clients(Matter::Fabric::MIN_FABRIC_INDEX).should be_empty
    cluster.save_state.should eq(before_state)
    cluster.data_version.should eq(before_version)
    versions.should eq(0)
    attributes.should eq(0)
    modes.should eq(0)
  end

  it "keeps a client registered and emits no change when UnregisterClient persistence fails" do
    cluster = build(AtomicIcd, 0, feature_map: AtomicIcd::Feature::CheckInProtocolSupport)
    cluster.request_administer_privilege = true
    atomic_icd_register(cluster, 123_u64).should be_a(Matter::Cluster::CommandResponse)
    versions = 0
    attributes = 0
    modes = 0
    cluster.on_version_changed = -> { versions += 1; nil }
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) do
      attribute.should eq(AtomicIcd::ATTR_REGISTERED_CLIENTS)
      attributes += 1
      nil
    end
    cluster.on_operating_mode_changed = -> { modes += 1; nil }
    cluster.on_persist_registration = -> { false }
    before_state = cluster.save_state
    before_version = cluster.data_version

    expect_status(atomic_icd_unregister(cluster, 123_u64), AtomicIcdStatus::Failure)

    cluster.registered_clients(Matter::Fabric::MIN_FABRIC_INDEX).map(&.check_in_node_id).should eq([123_u64])
    cluster.save_state.should eq(before_state)
    cluster.data_version.should eq(before_version)
    versions.should eq(0)
    attributes.should eq(0)
    modes.should eq(0)
  end
end
