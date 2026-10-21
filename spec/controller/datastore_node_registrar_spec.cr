require "../spec_helper"
require "../../src/matter/controller"

private alias JfdDatastore = Matter::Cluster::JointFabricDatastore

private class RecordingNodeDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  getter calls = [] of String
  property? fail_refresh = false
  property? fail_remove = false

  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    @calls << "add:#{node_id}:#{friendly_name}"
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
    @calls << "refresh:#{node_id}"
    raise Matter::TransportError.new("offline") if @fail_refresh
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    @calls << "remove:#{node_id}:#{friendly_name}"
    raise Matter::TransportError.new("offline") if @fail_remove
  end
end

private class NodeLifecycleIm < Matter::Controller::ImClient
  alias Datastore = Matter::Cluster::JointFabricDatastore

  getter commands = [] of UInt32
  property nodes = [] of Datastore::DatastoreNodeInformationEntryStruct
  property response_code = Matter::InteractionModel::StatusCode::Success

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(@nodes.to_tlv))
    Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty) : Matter::InteractionModel::InvokeResponseMessage
    @commands << command_id
    if @response_code == Matter::InteractionModel::StatusCode::Success
      case command_id
      when Datastore::CMD_ADD_PENDING_NODE
        request = Datastore::AddPendingNodeRequest.from_slice(fields)
        status = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
        @nodes << Datastore::DatastoreNodeInformationEntryStruct.new(request.node_id, request.friendly_name, status)
      when Datastore::CMD_REMOVE_NODE
        request = Datastore::RemoveNodeRequest.from_slice(fields)
        @nodes = @nodes.reject(&.node_id.==(request.node_id))
      end
    end
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id, command: command_id)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(@response_code.value))
    Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
      Matter::InteractionModel::InvokeResponseIB.new(command_status: status),
    ])
  end
end

private class TestNetworkNodeDelivery < Matter::Controller::DatastoreNodeRegistrar::NetworkDelivery
  def initialize(store : Matter::Controller::StateStore, client : Matter::Controller::Client,
                 @interaction : NodeLifecycleIm)
    super(store, client, 0x100_u64, 1_u16)
  end

  protected def with_datastore(fabric : Matter::Controller::FabricInfo,
                               & : Matter::Controller::ImClient, Matter::Session::SecureContext, Socket::IPAddress ->) : Nil
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    yield @interaction, session, Socket::IPAddress.new("127.0.0.1", 5540)
  end
end

private def registrar_fabric : Matter::Controller::FabricInfo
  Matter::Controller::FabricInfo.new(
    fabric_id: 0x123_u64, controller_node_id: 0x100_u64,
    ipk_value: Bytes.new(16), root_cert: Bytes[1], root_public_key: Bytes[2],
    controller_noc: Bytes[3], controller_private_key: Bytes[4]
  )
end

describe Matter::Controller::DatastoreNodeRegistrar do
  it "persists AddPendingNode before final CASE and removes it on pre-completion failure" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    delivery = RecordingNodeDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)

    registrar.add_pending(fabric, 0x200_u64, "Lamp")
    delivery.calls.should eq(["add:512:Lamp"])
    store.load.pending_datastore_nodes.size.should eq(1)
    registrar.abort(fabric, 0x200_u64)
    delivery.calls.should eq(["add:512:Lamp", "remove:512:Lamp"])
    store.load.pending_datastore_nodes.should be_empty
  end

  it "retains acknowledged completion until RefreshNode succeeds after restart" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    delivery = RecordingNodeDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)

    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    registrar.add_pending(fabric, 0x200_u64, "Lamp", peer: peer)
    registrar.completing(fabric, 0x200_u64)
    registrar.complete(fabric, 0x200_u64)
    delivery.fail_refresh = true
    expect_raises(Matter::TransportError, /offline/) { registrar.refresh(fabric, 0x200_u64) }
    store.load.pending_datastore_nodes.size.should eq(1)
    store.load.nodes_for(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id)[0x200_u64].address.should eq("127.0.0.1")

    delivery.fail_refresh = false
    Matter::Controller::DatastoreNodeRegistrar.new(store, delivery).resume(fabric)
    delivery.calls.should eq(["add:512:Lamp", "refresh:512", "refresh:512"])
    store.load.pending_datastore_nodes.should be_empty
  end

  it "preserves an ambiguous CommissioningComplete attempt for explicit reconciliation" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    delivery = RecordingNodeDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)

    registrar.add_pending(fabric, 0x200_u64, "Lamp")
    registrar.completing(fabric, 0x200_u64)
    expect_raises(Matter::CommissioningError, /ambiguous/) { registrar.resume(fabric) }
    expect_raises(Matter::CommissioningError, /ambiguous/) { registrar.abort(fabric, 0x200_u64) }
    delivery.calls.should eq(["add:512:Lamp"])
    store.load.pending_datastore_nodes.size.should eq(1)
    registrar.abort(fabric, 0x200_u64, confirmed_failure: true)
    delivery.calls.should eq(["add:512:Lamp", "remove:512:Lamp"])
  end

  it "waits for fail-safe expiry before cleaning up an interrupted registration" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    delivery = RecordingNodeDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)

    registrar.add_pending(fabric, 0x200_u64, "Lamp", 200_i64)
    registrar.resume(fabric, 199_i64)
    delivery.calls.should eq(["add:512:Lamp"])
    store.load.pending_datastore_nodes.size.should eq(1)

    delivery.fail_remove = true
    expect_raises(Matter::TransportError, /offline/) { registrar.resume(fabric, 200_i64) }
    store.load.pending_datastore_nodes.size.should eq(1)
    delivery.fail_remove = false
    registrar.resume(fabric, 200_i64)
    store.load.pending_datastore_nodes.should be_empty
  end

  it "recovers an acknowledged completion from saved controller state" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    delivery = RecordingNodeDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)

    registrar.add_pending(fabric, 0x200_u64, "Lamp")
    registrar.completing(fabric, 0x200_u64)
    state = store.load
    state.record_node(fabric.fabric_id, Matter::Controller::NodeInfo.new(0x200_u64),
      fabric.root_public_key, fabric.controller_node_id)
    store.save(state)
    registrar.resume(fabric)
    delivery.calls.should eq(["add:512:Lamp", "refresh:512"])
    store.load.pending_datastore_nodes.should be_empty
  end

  it "uses NodeList to retry Anchor commands without duplicating or deleting a completed node" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    client = Matter::Controller::Client.new
    interaction = NodeLifecycleIm.new(client)
    delivery = TestNetworkNodeDelivery.new(store, client, interaction)
    fabric = registrar_fabric

    delivery.add_pending_node(fabric, 0x200_u64, "Lamp")
    delivery.add_pending_node(fabric, 0x200_u64, "Lamp")
    interaction.commands.should eq([JfdDatastore::CMD_ADD_PENDING_NODE])
    delivery.refresh_node(fabric, 0x200_u64)
    interaction.commands.last.should eq(JfdDatastore::CMD_REFRESH_NODE)

    entry = interaction.nodes.first
    entry.commissioning_status_entry = JfdDatastore::DatastoreStatusEntryStruct.new(
      JfdDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    interaction.nodes = [entry]
    expect_raises(Matter::CommissioningError, /Refusing to remove/) do
      delivery.remove_node(fabric, 0x200_u64, "Lamp")
    end
    interaction.commands.should eq([JfdDatastore::CMD_ADD_PENDING_NODE, JfdDatastore::CMD_REFRESH_NODE])
  ensure
    client.try(&.close)
  end

  it "accepts a failed pending synchronization for cleanup and reports Anchor command errors" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    client = Matter::Controller::Client.new
    interaction = NodeLifecycleIm.new(client)
    delivery = TestNetworkNodeDelivery.new(store, client, interaction)
    fabric = registrar_fabric
    status = JfdDatastore::DatastoreStatusEntryStruct.new(JfdDatastore::DatastoreStateEnum::CommitFailed, 0_u32, 0_u8)
    interaction.nodes = [JfdDatastore::DatastoreNodeInformationEntryStruct.new(0x200_u64, "Lamp", status)]

    delivery.remove_node(fabric, 0x200_u64, "Lamp")
    interaction.nodes.should be_empty
    interaction.response_code = Matter::InteractionModel::StatusCode::Busy
    expect_raises(Matter::CommissioningError, /Datastore command/) do
      delivery.add_pending_node(fabric, 0x200_u64, "Lamp")
    end
  ensure
    client.try(&.close)
  end
end
