require "../spec_helper"
require "../../src/matter/controller/bridged_commissioning_host"
require "../../src/matter/storage/memory"

private alias BridgeHost = Matter::Controller::BridgedCommissioningHost
private alias BridgeCluster = Matter::Cluster::BridgedAdministratorCommissioning
private alias Admin = Matter::Cluster::AdministratorCommissioning
private alias Status = Matter::InteractionModel::Status

describe Matter::Controller::BridgedCommissioningHost do
  it "does not reuse a pending consent grant for a replacement fabric or CASE node" do
    target_fabric_index = Matter::Fabric::MIN_FABRIC_INDEX
    target_node_id = 0xB801_u64
    caller_fabric_index = Matter::Fabric::MIN_FABRIC_INDEX
    approved_node_id = 0xCA11_u64
    original_fabric = {0xA1_u64, Bytes.new(65, 0x11_u8)}
    current_fabric = original_fabric
    approved = BridgeHost::CallerIdentity.new(caller_fabric_index,
      original_fabric[0], original_fabric[1], approved_node_id)
      .consent_token(target_node_id, :revoke)

    endpoint = Matter::DataType::EndpointNumber.new(1_u16)
    cluster = BridgeCluster.new(endpoint, target_fabric_index, target_node_id,
      ->(_tf : UInt8, _tn : UInt64, _cf : UInt8, _cn : UInt64, _r : Admin::OpenCommissioningWindowRequest) { Status.success },
      ->(_tf : UInt8, _tn : UInt64, _cf : UInt8, _cn : UInt64) { Status.success })
    backend = Matter::Storage::Memory.new
    backend.write(BridgeHost::COLLECTION, BridgeHost::BINDING_ID,
      BridgeHost::Binding.new(0xB800_u64, Bytes.new(65, 0xBB_u8), 0xB802_u64,
        target_node_id, target_fabric_index, "127.0.0.1", 1).to_document)
    lookup = ->(_index : UInt8) { current_fabric.as(Tuple(UInt64, Bytes)?) }
    consent = ->(caller : BridgeHost::CallerIdentity, target : UInt64, operation : Symbol) do
      caller.consent_token(target, operation) == approved
    end
    host = BridgeHost.new(Matter::Controller::StateStore.new(backend), cluster, lookup, consent)

    current_fabric = {0xA2_u64, Bytes.new(65, 0x22_u8)}
    host.revoke(target_fabric_index, target_node_id, caller_fabric_index, approved_node_id)
      .should eq(Status.unsupported_access)

    current_fabric = original_fabric
    host.revoke(target_fabric_index, target_node_id, caller_fabric_index, approved_node_id + 1_u64)
      .should eq(Status.unsupported_access)
  end
end
