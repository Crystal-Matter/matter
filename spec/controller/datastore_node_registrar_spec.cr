require "../spec_helper"
require "../../src/matter/controller"

private alias JfdDatastore = Matter::Cluster::JointFabricDatastore

private class RecordingNodeDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  getter calls = [] of String
  property? fail_add = false
  property? fail_refresh = false
  property? fail_remove = false
  property? remote_absent = false
  property before_remove : Proc(Nil)?

  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    @calls << "add:#{node_id}:#{friendly_name}"
    raise Matter::TransportError.new("offline") if @fail_add
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
    @calls << "refresh:#{node_id}"
    raise Matter::TransportError.new("offline") if @fail_refresh
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    @calls << "remove:#{node_id}:#{friendly_name}"
    @before_remove.try(&.call)
    raise Matter::TransportError.new("offline") if @fail_remove
    @remote_absent = true
  end

  def node_absent?(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Bool
    @remote_absent
  end
end

private class BlockingRetryDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  getter entered = Channel(Nil).new
  getter release = Channel(Nil).new
  @attempts = 0

  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    @attempts += 1
    raise Matter::TransportError.new("offline") if @attempts == 1
    @entered.send(nil)
    @release.receive
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
  end
end

private class BlockingFirstRetryDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  getter entered = Channel(Nil).new
  getter release = Channel(Nil).new
  getter calls = [] of UInt64

  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
    @calls << node_id
    if @calls.size == 1
      @entered.send(nil)
      @release.receive
    end
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
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

  it "retries a failed AddPendingNode from the durable journal after controller startup" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    delivery = RecordingNodeDelivery.new
    delivery.fail_add = true
    original = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)
    deadline = Time.utc.to_unix + 60_i64
    expect_raises(Matter::TransportError, /offline/) do
      original.add_pending(fabric, 0x200_u64, "Lamp", deadline)
    end
    store.load.pending_datastore_nodes.first.stage.should eq(Matter::Controller::PendingDatastoreNode::Stage::Pending)

    delivery.fail_add = false
    restarted = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery,
      retry_interval: 10.milliseconds)
    commissioner = Matter::Controller::Commissioning::Commissioner.new(store,
      datastore_registrar: restarted)
    begin
      wait_until = Time.instant + 1.second
      until store.load.pending_datastore_nodes.first.stage.registered? || Time.instant >= wait_until
        sleep 10.milliseconds
      end
      store.load.pending_datastore_nodes.first.stage.should eq(Matter::Controller::PendingDatastoreNode::Stage::Registered)
      delivery.calls.should eq(["add:512:Lamp", "add:512:Lamp"])
    ensure
      commissioner.close
    end
  end

  it "keeps a foreground Completing save after an overlapping retry" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    delivery = BlockingRetryDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)
    expect_raises(Matter::TransportError, /offline/) do
      registrar.add_pending(fabric, 0x200_u64, "Lamp", Time.utc.to_unix + 60_i64)
    end

    retry_finished = Channel(Nil).new
    spawn do
      registrar.retry_pending_once
      retry_finished.send(nil)
    end
    delivery.entered.receive
    foreground_started = Channel(Nil).new
    foreground_finished = Channel(Nil).new
    spawn do
      foreground_started.send(nil)
      registrar.completing(fabric, 0x200_u64)
      foreground_finished.send(nil)
    end
    foreground_started.receive
    finished_early = select
    when foreground_finished.receive?
      true
    when timeout(20.milliseconds)
      false
    end
    delivery.release.send(nil)
    retry_finished.receive
    foreground_finished.receive unless finished_early
    finished_early.should be_false
    store.load.pending_datastore_nodes.first.stage.should eq(Matter::Controller::PendingDatastoreNode::Stage::Completing)
  end

  it "does not retry a node on a fabric removed after the retry scan" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    first = registrar_fabric
    second = Matter::Controller::FabricInfo.new(
      fabric_id: 0x124_u64, controller_node_id: 0x101_u64,
      ipk_value: Bytes.new(16), root_cert: Bytes[1], root_public_key: Bytes[5],
      controller_noc: Bytes[3], controller_private_key: Bytes[4])
    store.update do |state|
      state.install_fabric(first)
      state.install_fabric(second)
      state.pending_datastore_nodes << Matter::Controller::PendingDatastoreNode.new(
        first.fabric_id, first.root_public_key.dup, first.controller_node_id,
        0x200_u64, "First", Time.utc.to_unix + 60_i64)
      state.pending_datastore_nodes << Matter::Controller::PendingDatastoreNode.new(
        second.fabric_id, second.root_public_key.dup, second.controller_node_id,
        0x201_u64, "Second", Time.utc.to_unix + 60_i64)
    end
    delivery = BlockingFirstRetryDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)
    finished = Channel(Nil).new
    spawn do
      registrar.retry_pending_once
      finished.send(nil)
    end
    delivery.entered.receive
    store.update { |state| state.remove_fabric(second.fabric_id, second.root_public_key, second.controller_node_id) }
    delivery.release.send(nil)
    finished.receive

    delivery.calls.should eq([0x200_u64])
    store.load.pending_datastore_nodes.last.stage.should eq(Matter::Controller::PendingDatastoreNode::Stage::Pending)
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
    registrar.retry_pending_once
    store.load.pending_datastore_nodes.first.stage.should eq(Matter::Controller::PendingDatastoreNode::Stage::Completing)
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
    expect_raises(Matter::CommissioningError, /absence reconciliation/) { registrar.resume(fabric, 200_i64) }
    delivery.remote_absent = true
    registrar.resume(fabric, 200_i64)
    store.load.pending_datastore_nodes.should be_empty
  end

  it "fences a delayed RemoveNode against a new writer and a same-identity retry" do
    backend = Matter::Storage::Memory.new
    first_store = Matter::Controller::StateStore.new(backend)
    second_store = Matter::Controller::StateStore.new(backend)
    fabric = registrar_fabric
    first_store.update { |state| state.install_fabric(fabric) }
    delivery = RecordingNodeDelivery.new
    owner = Matter::Controller::DatastoreNodeRegistrar.new(first_store, delivery)
    replacement = Matter::Controller::DatastoreNodeRegistrar.new(second_store, delivery)
    owner.add_pending(fabric, 0x200_u64, "Lamp")

    delivery.before_remove = -> do
      expect_raises(Matter::CommissioningError, /previous attempt/) do
        replacement.add_pending(fabric, 0x200_u64, "Lamp")
      end
      nil
    end
    owner.abort(fabric, 0x200_u64)
    delivery.before_remove = nil
    replacement.add_pending(fabric, 0x200_u64, "Lamp")
    stale = Matter::Controller::DatastoreNodeRegistrar.new(first_store, delivery, owner.attempt_id)
    expect_raises(Matter::CommissioningError, /another attempt/) do
      stale.abort(fabric, 0x200_u64)
    end
    second_store.load.pending_datastore_nodes.first.attempt_id.should eq(replacement.attempt_id)
    delivery.calls.count("remove:512:Lamp").should eq(1)
  end

  it "holds a durable removal guard after a lost response until authenticated absence" do
    backend = Matter::Storage::Memory.new
    first_store = Matter::Controller::StateStore.new(backend)
    second_store = Matter::Controller::StateStore.new(backend)
    fabric = registrar_fabric
    first_store.update { |state| state.install_fabric(fabric) }
    delivery = RecordingNodeDelivery.new
    first = Matter::Controller::DatastoreNodeRegistrar.new(first_store, delivery)
    first.add_pending(fabric, 0x200_u64, "Lamp")
    delivery.fail_remove = true
    expect_raises(Matter::TransportError, /offline/) { first.abort(fabric, 0x200_u64) }
    second_store.load.pending_datastore_nodes.first.stage.should eq(
      Matter::Controller::PendingDatastoreNode::Stage::Removing)

    second = Matter::Controller::DatastoreNodeRegistrar.new(second_store, delivery)
    expect_raises(Matter::CommissioningError, /previous attempt/) do
      second.add_pending(fabric, 0x200_u64, "Lamp")
    end
    recovered = Matter::Controller::DatastoreNodeRegistrar.new(second_store, delivery, first.attempt_id)
    expect_raises(Matter::CommissioningError, /absence reconciliation/) do
      recovered.reconcile_removal(fabric, 0x200_u64)
    end
    delivery.remote_absent = true
    recovered.reconcile_removal(fabric, 0x200_u64)
    second.add_pending(fabric, 0x200_u64, "Lamp")
    second_store.load.pending_datastore_nodes.first.attempt_id.should eq(second.attempt_id)
    delivery.calls.count("remove:512:Lamp").should eq(1)
  end

  it "claims a legacy pending record once across two StateStore writers" do
    backend = Matter::Storage::Memory.new
    first_store = Matter::Controller::StateStore.new(backend)
    second_store = Matter::Controller::StateStore.new(backend)
    fabric = registrar_fabric
    first_store.update do |state|
      state.install_fabric(fabric)
      state.pending_datastore_nodes << Matter::Controller::PendingDatastoreNode.new(
        fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
        0x200_u64, "Lamp", Time.utc.to_unix - 1_i64)
    end
    delivery = RecordingNodeDelivery.new
    first = Matter::Controller::DatastoreNodeRegistrar.new(first_store, delivery)
    second = Matter::Controller::DatastoreNodeRegistrar.new(second_store, delivery)
    first.claim_legacy(fabric, 0x200_u64, "Lamp", nil, Matter::Controller::NodeInfo::DEFAULT_PORT)
    expect_raises(Matter::CommissioningError, /another attempt/) do
      second.claim_legacy(fabric, 0x200_u64, "Lamp", nil, Matter::Controller::NodeInfo::DEFAULT_PORT)
    end
    second_store.load.pending_datastore_nodes.first.attempt_id.should eq(first.attempt_id)
    first.resume(fabric)
    second_store.load.pending_datastore_nodes.should be_empty
  end

  it "recovers a legacy completed record through RefreshNode" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    store.update do |state|
      state.install_fabric(fabric)
      state.pending_datastore_nodes << Matter::Controller::PendingDatastoreNode.new(
        fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
        0x200_u64, "Lamp", Time.utc.to_unix, "127.0.0.1",
        Matter::Controller::NodeInfo::DEFAULT_PORT,
        Matter::Controller::PendingDatastoreNode::Stage::Completed)
    end
    delivery = RecordingNodeDelivery.new
    Matter::Controller::DatastoreNodeRegistrar.new(store, delivery).resume(fabric)
    delivery.calls.should eq(["refresh:512"])
    store.load.pending_datastore_nodes.should be_empty
  end

  it "recovers legacy registered and completing records" do
    [Matter::Controller::PendingDatastoreNode::Stage::Registered,
     Matter::Controller::PendingDatastoreNode::Stage::Completing].each do |stage|
      store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
      fabric = registrar_fabric
      store.update do |state|
        state.install_fabric(fabric)
        state.pending_datastore_nodes << Matter::Controller::PendingDatastoreNode.new(
          fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
          0x200_u64, "Lamp", Time.utc.to_unix - 1_i64, "127.0.0.1",
          Matter::Controller::NodeInfo::DEFAULT_PORT, stage)
        if stage.completing?
          state.record_node(fabric.fabric_id,
            Matter::Controller::NodeInfo.new(0x200_u64, "127.0.0.1"),
            fabric.root_public_key, fabric.controller_node_id)
        end
      end
      delivery = RecordingNodeDelivery.new
      Matter::Controller::DatastoreNodeRegistrar.new(store, delivery).resume(fabric)
      if stage.registered?
        delivery.calls.should eq(["remove:512:Lamp"])
      else
        delivery.calls.should eq(["refresh:512"])
      end
      store.load.pending_datastore_nodes.should be_empty
    end
  end

  it "stages a pre-ordering migrated node only with its verified commissioned peer" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = registrar_fabric
    store.update do |state|
      state.install_fabric(fabric)
      state.record_node(fabric.fabric_id,
        Matter::Controller::NodeInfo.new(0x200_u64, "127.0.0.1"),
        fabric.root_public_key, fabric.controller_node_id)
    end
    delivery = RecordingNodeDelivery.new
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery, "legacy-migration")
    peer = Socket::IPAddress.new("127.0.0.1", Matter::Controller::NodeInfo::DEFAULT_PORT)
    expect_raises(Matter::CommissioningError, /already has a commissioned/) do
      registrar.add_pending(fabric, 0x200_u64, "Lamp", peer: peer)
    end
    wrong_peer = Socket::IPAddress.new("127.0.0.2", Matter::Controller::NodeInfo::DEFAULT_PORT)
    expect_raises(Matter::CommissioningError, /already has a commissioned/) do
      registrar.add_pending(fabric, 0x200_u64, "Lamp", peer: wrong_peer, allow_commissioned: true)
    end
    registrar.add_pending(fabric, 0x200_u64, "Lamp", peer: peer, allow_commissioned: true)
    delivery.calls.should eq(["add:512:Lamp"])
    registrar.confirm_remote_committed(fabric, 0x200_u64)
    store.load.pending_datastore_nodes.should be_empty
    store.load.nodes_for(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id).has_key?(0x200_u64).should be_true
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
    delivery.remove_committed_node(fabric, 0x200_u64, "Lamp")
    interaction.nodes.should be_empty
    interaction.commands.last.should eq(JfdDatastore::CMD_REMOVE_NODE)
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

  it "removes a matching Committed entry after confirmed commissioning failure" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    client = Matter::Controller::Client.new
    interaction = NodeLifecycleIm.new(client)
    delivery = TestNetworkNodeDelivery.new(store, client, interaction)
    fabric = registrar_fabric
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, delivery)
    store.update do |state|
      state.install_fabric(fabric)
      state.pending_datastore_nodes << Matter::Controller::PendingDatastoreNode.new(
        fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
        0x200_u64, "Lamp", Time.utc.to_unix, nil,
        Matter::Controller::NodeInfo::DEFAULT_PORT,
        Matter::Controller::PendingDatastoreNode::Stage::Completing,
        registrar.attempt_id)
    end
    status = JfdDatastore::DatastoreStatusEntryStruct.new(JfdDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    interaction.nodes = [JfdDatastore::DatastoreNodeInformationEntryStruct.new(0x200_u64, "Lamp", status)]
    expect_raises(Matter::CommissioningError, /ambiguous/) { registrar.abort(fabric, 0x200_u64) }
    registrar.abort(fabric, 0x200_u64, confirmed_failure: true, allow_committed: true)
    interaction.commands.should eq([JfdDatastore::CMD_REMOVE_NODE])
    interaction.nodes.should be_empty
    store.load.pending_datastore_nodes.should be_empty
  ensure
    client.try(&.close)
  end
end
