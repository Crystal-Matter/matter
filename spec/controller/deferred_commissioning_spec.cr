require "../spec_helper"
require "../../src/matter/controller"

private class DeferredSpecHooks < Matter::Controller::Commissioning::Commissioner::Hooks
  def prepare_credentials(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                          csr_public_key : Bytes, im : Matter::Controller::ImClient,
                          pase_session : Matter::Session::SecureContext,
                          peer : Socket::IPAddress) : Matter::Controller::Commissioning::Commissioner::OperationalCredentials
    raise "not called"
  end

  def before_complete(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                      im : Matter::Controller::ImClient,
                      case_session : Matter::Session::SecureContext,
                      peer : Socket::IPAddress) : Nil
    raise "not called"
  end
end

describe Matter::Controller::Commissioning::Commissioner do
  it "persists a deferred handoff separately from commissioned nodes" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x100_u64, 0xFFF1_u16).fabric
    state = store.load
    state.install_fabric(fabric)
    handoff = Matter::Controller::PendingCommissioningHandoff.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      0x200_u64, "192.0.2.1", 5540, Time.utc.to_unix + 60, "test-nonce")
    state.add_pending_handoff(handoff)
    store.save(state)

    reloaded = store.load
    reloaded.nodes.should be_empty
    reloaded.pending_handoffs.size.should eq(1)
    commissioner = Matter::Controller::Commissioning::Commissioner.new(store)
    expect_raises(Matter::AuthenticationError, /nonce/) do
      commissioner.record_handoff_success(fabric.fabric_id, fabric.root_public_key,
        fabric.controller_node_id, 0x200_u64, "wrong-nonce")
    end
    node = commissioner.record_handoff_success(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 0x200_u64, "test-nonce")
    node.address.should eq("192.0.2.1")
    store.load.pending_handoffs.should be_empty
    store.load.nodes[0x200_u64].port.should eq(5540)
    expect_raises(Matter::ConfigurationError, /No pending/) do
      commissioner.record_handoff_success(fabric.fabric_id, fabric.root_public_key,
        fabric.controller_node_id, 0x200_u64, "test-nonce")
    end
  ensure
    commissioner.try(&.close)
  end

  it "does not defer a JCM hooks flow without an Anchor handoff design" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    commissioner = Matter::Controller::Commissioning::Commissioner.new(store,
      hooks: DeferredSpecHooks.new)
    expect_raises(Matter::ConfigurationError, /explicit Anchor handoff/) do
      commissioner.pairing_code(0x200_u64, "invalid", defer_completion: true)
    end
  ensure
    commissioner.try(&.close)
  end

  it "does not accept a stale JFA completion result" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1235_u64, 0x100_u64, 0xFFF1_u16).fabric
    state = store.load
    state.install_fabric(fabric)
    state.add_pending_handoff(Matter::Controller::PendingCommissioningHandoff.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      0x201_u64, "192.0.2.2", 5540, Time.utc.to_unix - 1, "expired-nonce"))
    store.save(state)
    commissioner = Matter::Controller::Commissioning::Commissioner.new(store)
    expect_raises(Matter::AuthenticationError, /deadline/) do
      commissioner.record_handoff_success(fabric.fabric_id, fabric.root_public_key,
        fabric.controller_node_id, 0x201_u64, "expired-nonce")
    end
    store.load.pending_handoffs.size.should eq(1)
    store.load.nodes.should be_empty
  ensure
    commissioner.try(&.close)
  end
end
