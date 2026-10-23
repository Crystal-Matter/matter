require "../spec_helper"
require "../../src/matter/controller"
require "../../src/matter/storage/sqlite"

private class SqliteJointFabricDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  getter added = [] of UInt64
  getter refreshed = [] of UInt64

  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    @added << node_id
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
    @refreshed << node_id
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    raise Matter::CommissioningError.new("A completed Joint Fabric node must not be removed")
  end
end

describe "Joint Fabric controller recovery on opt-in SQLite" do
  it "keeps its fabric identity and pending Datastore completion through rollback and restart" do
    directory = File.join(Dir.tempdir, "matter-sqlite-jfa-#{Random::Secure.hex(6)}")
    path = File.join(directory, "controller.sqlite3")
    backend = Matter::Storage::Sqlite.new(path)
    store = Matter::Controller::StateStore.new(backend)
    fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA100_u64, 0xA102_u64, 0xFFF1_u16).fabric
    node_id = 0xA103_u64
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    backend.open
    backend.transaction do
      state = store.load
      state.install_fabric(fabric)
      store.save(state)
    end

    first_delivery = SqliteJointFabricDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, first_delivery)
    registrar.add_pending(fabric, node_id, "Shared Lamp", Time.utc.to_unix + 60, peer: peer)
    registrar.completing(fabric, node_id)
    registrar.complete(fabric, node_id)
    first_delivery.added.should eq([node_id])

    expect_raises(ArgumentError, /simulated process failure/) do
      backend.transaction do
        changed = store.load
        changed.pending_datastore_nodes.clear
        store.save(changed)
        raise ArgumentError.new("simulated process failure")
      end
    end
    backend.close

    reopened = Matter::Storage::Sqlite.new(path)
    resumed_store = Matter::Controller::StateStore.new(reopened)
    loaded = resumed_store.load
    restored_fabric = loaded.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
    restored_fabric.to_document.should eq(fabric.to_document)
    loaded.nodes_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id).should be_empty
    entry = loaded.pending_datastore_nodes.first
    entry.stage.should eq(Matter::Controller::PendingDatastoreNode::Stage::Completed)
    entry.node_id.should eq(node_id)
    entry.peer_address.should eq("127.0.0.1")
    entry.peer_port.should eq(5540)

    resumed_delivery = SqliteJointFabricDelivery.new
    Matter::Controller::DatastoreNodeRegistrar.new(resumed_store, resumed_delivery).resume(restored_fabric)
    resumed_delivery.added.should be_empty
    resumed_delivery.refreshed.should eq([node_id])
    resumed_store.load.pending_datastore_nodes.should be_empty
    reopened.close

    final_backend = Matter::Storage::Sqlite.new(path)
    final_state = Matter::Controller::StateStore.new(final_backend).load
    final_state.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
      .to_document.should eq(fabric.to_document)
    final_state.nodes_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)[node_id]
      .address.should eq("127.0.0.1")
    final_state.pending_datastore_nodes.should be_empty
    final_backend.destroy!
  ensure
    backend.try(&.close) if backend.try(&.open?)
    reopened.try(&.close) if reopened.try(&.open?)
    final_backend.try(&.destroy!) if final_backend.try(&.open?)
    FileUtils.rm_rf(directory) if directory
  end
end
