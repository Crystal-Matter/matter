require "../spec_helper"
require "../../src/matter/controller/anchor_datastore_subscription"
require "../../src/matter/controller/joint_commissioning"

private alias Store = Matter::Cluster::JointFabricDatastore

describe Matter::Controller::AnchorDatastoreSubscription do
  it "extracts only the new Anchor Datastore Status path from a priming report" do
    status = Store::DatastoreStatusEntryStruct.new(Store::DatastoreStateEnum::Committed, 3_u32, 0_u8)
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: Store::CLUSTER_ID, attribute: Store::ATTR_STATUS)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.from_slice(status.to_slice))
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 5_u32,
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])

    parsed = Matter::Controller::AnchorDatastoreSubscription.status_from_reports([report], 1_u16)
    parsed.state.should eq(Store::DatastoreStateEnum::Committed)
    parsed.update_timestamp.should eq(3_u32)
    expect_raises(Matter::ProtocolError, /unique Status/) do
      Matter::Controller::AnchorDatastoreSubscription.status_from_reports([report], 2_u16)
    end
  end

  it "rejects a missing Anchor identity before discovery" do
    scanner = Matter::Controller::Scanner.new
    fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1000_u64, 0x100_u64, 0xFFF1_u16).fabric
    verifier = ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress) { nil }
    expect_raises(Matter::ConfigurationError, /Node ID/) do
      Matter::Controller::AnchorDatastoreSubscription.new(scanner, fabric, 0_u64, 1_u16, verifier)
    end
  ensure
    scanner.try(&.close)
  end

  it "accepts identity-only reports and rejects an Anchor identity change" do
    fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1000_u64, 0x100_u64, 0xFFF1_u16).fabric
    root_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: Store::CLUSTER_ID, attribute: Store::ATTR_ANCHOR_ROOT_CA)
    node_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: Store::CLUSTER_ID, attribute: Store::ATTR_ANCHOR_NODE_ID)
    root_data = Matter::InteractionModel::AttributeDataIB.new(root_path,
      TLV::Any.from_slice(fabric.root_cert.to_tlv))
    node_data = Matter::InteractionModel::AttributeDataIB.new(node_path,
      TLV::Any.from_slice(0x100_u64.to_tlv))
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 5_u32,
      attribute_reports: [
        Matter::InteractionModel::AttributeReportIB.new(attribute_data: root_data),
        Matter::InteractionModel::AttributeReportIB.new(attribute_data: node_data),
      ])
    watcher = Matter::Controller::AnchorDatastoreSubscription
    watcher.status_from_reports?([report], 1_u16).should be_nil
    watcher.verify_identity!([report], 1_u16, fabric.root_public_key, 0x100_u64)
    watcher.verify_identity_updates!([report], 1_u16, fabric.root_public_key, 0x100_u64)
    expect_raises(Matter::AuthenticationError, /Node ID changed/) do
      watcher.verify_identity_updates!([report], 1_u16, fabric.root_public_key, 0x101_u64)
    end
  end

  it "retains the latest Pending status across quiet polls and identity-only reports" do
    watcher = Matter::Controller::AnchorDatastoreSubscription
    committed = Store::DatastoreStatusEntryStruct.new(Store::DatastoreStateEnum::Committed, 3_u32, 0_u8)
    pending = Store::DatastoreStatusEntryStruct.new(Store::DatastoreStateEnum::Pending, 4_u32, 0_u8)
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: Store::CLUSTER_ID, attribute: Store::ATTR_STATUS)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.from_slice(pending.to_slice))
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 5_u32,
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
    latest = watcher.updated_status(committed, [report], 1_u16)
    latest.state.should eq(Store::DatastoreStateEnum::Pending)
    watcher.updated_status(latest, nil, 1_u16).state.should eq(Store::DatastoreStateEnum::Pending)
    identity_only = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 5_u32)
    watcher.updated_status(latest, [identity_only], 1_u16).state.should eq(Store::DatastoreStateEnum::Pending)
  end
end
