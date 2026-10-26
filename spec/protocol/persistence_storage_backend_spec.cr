require "../spec_helper"
require "../../src/matter/protocol/persistence"

private SESSIONS      = Matter::Storage::Collections::SESSIONS
private SUBSCRIPTIONS = Matter::Storage::Collections::SUBSCRIPTIONS
private DEVICE        = Matter::Storage::Collections::DEVICE

private def build_fabric(fabric_index : UInt8) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: fabric_index.to_u64,
    fabric_index: fabric_index,
    node_id: 0x1_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16)
  )
end

private def case_session(session_id : UInt16, fabric_index : UInt8) : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: session_id,
    peer_session_id: session_id &+ 1_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 1_u8),
    decryption_key: Bytes.new(16, 2_u8),
    initiator: false,
    peer_node_id: Matter::DataType::NodeId.new(0x1234_u64),
    attestation_challenge: Bytes.new(16, 3_u8),
    case_session: true,
    fabric_index: fabric_index
  )
end

private def build_registry(storage : Matter::Storage::Backend) : Matter::Protocol::SessionRegistry
  Matter::Protocol::SessionRegistry.new(
    mrp_cache: Matter::Protocol::MrpCache.new(Matter::Spec::CaptureTransport.new_for_spec),
    persistence: Matter::Protocol::Persistence::StorageBackend.new(storage)
  )
end

# A registry with the stored state loaded into it.
private def restored_registry(storage : Matter::Storage::Backend, fabric_table : Matter::FabricTable) : Matter::Protocol::SessionRegistry
  registry = build_registry(storage)
  Matter::Protocol::Persistence::StorageBackend.new(storage).restore(registry, fabric_table)
  registry
end

private def build_subscription(id : UInt32, session : Matter::Session::SecureContext) : Matter::Protocol::ActiveSubscription
  Matter::Protocol::ActiveSubscription.new(
    subscription_id: id,
    min_interval: 1_u16,
    max_interval: 60_u16,
    peer: Socket::IPAddress.new("192.168.1.20", 5540),
    session: session,
    attribute_paths: [
      Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 6_u32, attribute: 0_u32),
      Matter::InteractionModel::AttributePath.new,
    ],
    exchange_id: 7_u16
  )
end

describe Matter::Protocol::Persistence::StorageBackend do
  describe "sessions" do
    it "writes established CASE sessions as documents and skips PASE sessions" do
      storage = Matter::Storage::Memory.new
      registry = build_registry(storage)
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage)

      session = case_session(111_u16, 1_u8)
      backend.session_established(registry, session)
      document = storage.read(SESSIONS, "111").as(Matter::Storage::Document)
      document["encryption_key"].should eq(Bytes.new(16, 1_u8))
      document["fabric_index"].should eq(1_i64)
      document["session_type"].should eq("Unicast")

      pase = case_session(222_u16, 1_u8)
      pase.case_session = false
      backend.session_established(registry, pase)
      storage.ids(SESSIONS).should eq(["111"])
    end

    it "saves the current fabric identity on a CASE session document" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      table.add_fabric(build_fabric(1_u8))
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage, table)
      registry = build_registry(storage)
      session = case_session(111_u16, 1_u8)

      backend.session_established(registry, session)
      document = storage.read(SESSIONS, "111").as(Matter::Storage::Document)
      document["fabric_identity"].should eq(table.get_fabric(1_u8).as(Matter::Fabric).storage_identity)
      restored_registry(storage, table).sessions.has_key?(111_u16).should be_true
    end

    it "never persists a connection-bound TCP CASE session" do
      storage = Matter::Storage::Memory.new
      registry = build_registry(storage)
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage)
      session = case_session(111_u16, 1_u8)
      session.bind_tcp_peer(Socket::IPAddress.new("fd00::1", 0))

      backend.session_established(registry, session)
      backend.session_updated(registry, session)
      storage.ids(SESSIONS).should be_empty
    end

    it "prunes a legacy saved TCP CASE session on restore" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      table.add_fabric(build_fabric(1_u8))
      session = case_session(111_u16, 1_u8)
      session.bind_tcp_peer(Socket::IPAddress.new("fd00::1", 0))
      storage.write(SESSIONS, "111", session.to_record.to_document)

      restored_registry(storage, table).sessions.should be_empty
      storage.ids(SESSIONS).should be_empty
    end

    it "removes the session document" do
      storage = Matter::Storage::Memory.new
      registry = build_registry(storage)
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage)

      backend.session_established(registry, case_session(111_u16, 1_u8))
      backend.session_removed(registry, 111_u16)
      storage.ids(SESSIONS).should be_empty
    end

    it "defers session updates to the debouncer and drops them for removed sessions" do
      storage = Matter::Storage::Memory.new
      registry = build_registry(storage)
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage)
      debouncer = Matter::Debouncer.new(1.hour) { }
      backend.write_debouncer = debouncer

      session = case_session(111_u16, 1_u8)
      backend.session_established(registry, session)
      session.local_message_counter = 42_u32
      backend.session_updated(registry, session)
      debouncer.pending?.should be_true
      storage.read(SESSIONS, "111").as(Matter::Storage::Document)["local_message_counter"].should_not eq(42_i64)

      backend.flush_pending_writes
      storage.read(SESSIONS, "111").as(Matter::Storage::Document)["local_message_counter"].should eq(42_i64)

      backend.session_updated(registry, session)
      backend.session_removed(registry, 111_u16)
      backend.flush_pending_writes
      storage.ids(SESSIONS).should be_empty
      debouncer.cancel
    end

    it "restores CASE sessions for known fabrics" do
      storage = Matter::Storage::Memory.new
      fabric_table = Matter::FabricTable.new(storage)
      fabric_table.add_fabric(build_fabric(1_u8))

      session = case_session(111_u16, 1_u8)
      session.local_message_counter = 99_u32
      session.peer_message_counter = 7_u32
      session.fabric_identity = fabric_table.get_fabric(1_u8).as(Matter::Fabric).storage_identity
      storage.write(SESSIONS, "111", session.to_record.to_document)

      registry = restored_registry(storage, fabric_table)
      restored = registry.sessions[111_u16]
      restored.local_message_counter.should eq(99_u32)
      restored.peer_message_counter.should eq(7_u32)
      restored.peer_node_id.should eq(Matter::DataType::NodeId.new(0x1234_u64))
      restored.attestation_challenge.should eq(Bytes.new(16, 3_u8))
      restored.fabric_index.should eq(1_u8)
    end

    it "rejects a saved CASE session after the fabric index is reused" do
      storage = Matter::Storage::Memory.new
      fabric_table = Matter::FabricTable.new(storage)
      fabric_table.add_fabric(build_fabric(1_u8))
      session = case_session(111_u16, 1_u8)
      session.fabric_identity = fabric_table.get_fabric(1_u8).as(Matter::Fabric).storage_identity
      storage.write(SESSIONS, "111", session.to_record.to_document)
      fabric_table.remove_fabric(1_u8).should be_true
      fabric_table.add_fabric(build_fabric(1_u8)).should be_true

      restored_registry(storage, fabric_table).sessions.should be_empty
      storage.ids(SESSIONS).should be_empty
    end

    it "fails closed on a legacy CASE session without fabric identity" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      table.add_fabric(build_fabric(1_u8))
      storage.write(SESSIONS, "111", case_session(111_u16, 1_u8).to_record.to_document)

      restored_registry(storage, table).sessions.should be_empty
      storage.ids(SESSIONS).should be_empty
    end

    it "does not restore CASE sessions for missing fabrics (and prunes them)" do
      storage = Matter::Storage::Memory.new
      fabric_table = Matter::FabricTable.new(storage)

      # Persist a CASE session referencing fabric 1, but do not create that fabric.
      storage.write(SESSIONS, "111", case_session(111_u16, 1_u8).to_record.to_document)

      registry = restored_registry(storage, fabric_table)
      registry.sessions.has_key?(111_u16).should be_false
      storage.ids(SESSIONS).should be_empty
    end

    it "prunes undecodable session documents" do
      storage = Matter::Storage::Memory.new
      fabric_table = Matter::FabricTable.new(storage)
      storage.write(SESSIONS, "5", Matter::Storage::Document{"session_id" => "bogus"})

      registry = restored_registry(storage, fabric_table)
      registry.sessions.should be_empty
      storage.ids(SESSIONS).should be_empty
    end
  end

  describe "subscriptions" do
    it "writes the subscription document and the next subscription id" do
      storage = Matter::Storage::Memory.new
      registry = build_registry(storage)
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage)
      registry.next_subscription_id = 11_u32

      backend.subscription_established(registry, build_subscription(10_u32, case_session(111_u16, 1_u8)))

      document = storage.read(SUBSCRIPTIONS, "10").as(Matter::Storage::Document)
      document["session_id"].should eq(111_i64)
      document["peer_address"].should eq("192.168.1.20")
      document["peer_port"].should eq(5540_i64)
      paths = document["attribute_paths"].as(Array(Matter::Storage::Type))
      paths.size.should eq(2)
      paths[0].should eq(Matter::Storage::Document{"endpoint" => 1_i64, "cluster" => 6_i64, "attribute" => 0_i64})
      paths[1].should eq(Matter::Storage::Document.new)

      counters = storage.read(DEVICE, Matter::Protocol::Persistence::StorageBackend::COUNTERS_ID).as(Matter::Storage::Document)
      counters[Matter::Protocol::Persistence::StorageBackend::NEXT_SUBSCRIPTION_ID_KEY].should eq(11_i64)

      backend.subscription_removed(registry, 10_u32)
      storage.ids(SUBSCRIPTIONS).should be_empty
    end

    it "restores subscriptions whose session exists and prunes the rest" do
      storage = Matter::Storage::Memory.new
      fabric_table = Matter::FabricTable.new(storage)
      fabric_table.add_fabric(build_fabric(1_u8))

      session = case_session(111_u16, 1_u8)
      session.fabric_identity = fabric_table.get_fabric(1_u8).as(Matter::Fabric).storage_identity
      storage.write(SESSIONS, "111", session.to_record.to_document)
      storage.write(SUBSCRIPTIONS, "10", build_subscription(10_u32, session).to_record.to_document)
      storage.write(SUBSCRIPTIONS, "20", build_subscription(20_u32, case_session(222_u16, 1_u8)).to_record.to_document)
      storage.write(DEVICE, Matter::Protocol::Persistence::StorageBackend::COUNTERS_ID,
        Matter::Storage::Document{Matter::Protocol::Persistence::StorageBackend::NEXT_SUBSCRIPTION_ID_KEY => 50_i64})

      registry = restored_registry(storage, fabric_table)

      registry.active_subscriptions.keys.should eq([10_u32])
      subscription = registry.active_subscriptions[10_u32]
      subscription.session.should be(registry.sessions[111_u16])
      subscription.peer.should eq(Socket::IPAddress.new("192.168.1.20", 5540))
      subscription.exchange_id.should eq(7_u16)
      subscription.attribute_paths.size.should eq(2)
      subscription.attribute_paths[0].endpoint.should eq(1_u16)
      subscription.attribute_paths[1].cluster.should be_nil
      registry.next_subscription_id.should eq(50_u32)
      storage.ids(SUBSCRIPTIONS).should eq(["10"])
    end
  end
  describe "a closed store" do
    it "drops writes instead of raising, so a sweep or debouncer fiber in flight is harmless" do
      storage = Matter::Storage::Memory.new
      registry = build_registry(storage)
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage)
      session = case_session(111_u16, 1_u8)
      backend.session_established(registry, session)

      storage.close

      # Every hook the background fibers reach is a no-op once the store is shut
      backend.session_established(registry, case_session(222_u16, 1_u8))
      backend.session_updated(registry, session)
      backend.session_removed(registry, 111_u16)
      backend.subscription_established(registry, build_subscription(1_u32, session))
      backend.subscription_removed(registry, 1_u32)
      backend.flush_pending_writes

      storage.open
      storage.ids(SESSIONS).should eq(["111"])
      storage.ids(SUBSCRIPTIONS).should be_empty
    end

    it "drops a debounced flush whose store closed while it was pending" do
      storage = Matter::Storage::Memory.new
      registry = build_registry(storage)
      backend = Matter::Protocol::Persistence::StorageBackend.new(storage)
      debouncer = Matter::Debouncer.new(1.hour) { }
      backend.write_debouncer = debouncer

      session = case_session(111_u16, 1_u8)
      backend.session_established(registry, session)
      session.local_message_counter = 42_u32
      backend.session_updated(registry, session)

      storage.close
      backend.flush_pending_writes
      storage.open

      storage.read(SESSIONS, "111").as(Matter::Storage::Document)["local_message_counter"].should_not eq(42_i64)
      debouncer.cancel
    end
  end
end
