require "../spec_helper"
require "../../src/matter/controller/state_store"
require "../../src/matter/storage/sqlite"
require "../../examples/chip-tool/context"

private def with_temp_file(& : String ->) : Nil
  path = File.join(Dir.tempdir, "matter-controller-#{Random::Secure.hex(6)}.yml")
  yield path
ensure
  File.delete?(path) if path
end

private def sample_fabric : Matter::Controller::FabricInfo
  Matter::Controller::FabricInfo.new(
    fabric_id: 0x1111_u64,
    controller_node_id: 0x2222_u64,
    ipk_value: Bytes.new(16, 0xAA_u8),
    root_cert: Bytes[0x15, 0x30, 0x01, 0x01],
    root_public_key: Bytes[0x04_u8] + Bytes.new(64, 0xBB_u8),
    controller_noc: Bytes[0x15, 0x30, 0x01, 0x02],
    controller_private_key: Bytes.new(32, 0xCC_u8),
    admin_vendor_id: 0xFFF1_u16
  )
end

private class FailingControllerYamlFile < Matter::Storage::YamlFile
  property? fail_credential_delete = false

  def delete(collection : String, id : String) : Nil
    if @fail_credential_delete && collection == Matter::Session::Case::ResumptionStore::COLLECTION
      raise Matter::StorageError.new("injected controller credential deletion failure")
    end
    super
  end
end

private class FailingControllerSqlite < Matter::Storage::Sqlite
  property? fail_credential_delete = false

  def delete(collection : String, id : String) : Nil
    if @fail_credential_delete && collection == Matter::Session::Case::ResumptionStore::COLLECTION
      raise Matter::StorageError.new("injected controller credential deletion failure")
    end
    super
  end
end

private def seed_controller_credentials(backend : Matter::Storage::Backend,
                                        fabric : Matter::Controller::FabricInfo) : Bytes
  id = Bytes.new(16, 0x11_u8)
  Matter::Session::Case::ResumptionStore.new(backend).save(
    Matter::Session::Case::ResumptionStore::Record.new(fabric.fabric_id,
      fabric.root_public_key, fabric.controller_node_id, 0x3333_u64,
      id, Bytes.new(32, 0x22_u8), [0x3333_u64]))
  Matter::Controller::IcdPeerStore.new(backend).save(
    Matter::Controller::IcdPeerStore::Record.new(fabric.fabric_id,
      fabric.root_public_key, fabric.controller_node_id, 0x3333_u64,
      Bytes.new(16, 0x55_u8), 10_u32, 11_u32))
  id
end

private def assert_atomic_controller_removal(backend : Matter::Storage::Backend,
                                             reopen : Proc(Matter::Storage::Backend)) : Nil
  fabric = sample_fabric
  store = Matter::Controller::StateStore.new(backend)
  store.save(Matter::Controller::State.new(fabric: fabric))
  id = seed_controller_credentials(backend, fabric)
  state = store.load
  state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)

  expect_raises(Matter::StorageError, /injected controller credential deletion/) { store.save(state) }
  backend.close

  recovered = reopen.call
  recovered_store = Matter::Controller::StateStore.new(recovered)
  recovered_store.load.fabric_for(fabric.fabric_id, fabric.root_public_key,
    fabric.controller_node_id).should eq(fabric)
  Matter::Session::Case::ResumptionStore.new(recovered).find_by_id(id).should_not be_nil
  Matter::Controller::IcdPeerStore.new(recovered).find_peer(fabric.fabric_id,
    fabric.root_public_key, fabric.controller_node_id, 0x3333_u64).should_not be_nil

  retry_state = recovered_store.load
  retry_state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
  recovered_store.save(retry_state)
  recovered.close

  completed = reopen.call
  completed_store = Matter::Controller::StateStore.new(completed)
  completed_store.load.fabric.should be_nil
  Matter::Session::Case::ResumptionStore.new(completed).find_by_id(id).should be_nil
  Matter::Controller::IcdPeerStore.new(completed).find_peer(fabric.fabric_id,
    fabric.root_public_key, fabric.controller_node_id, 0x3333_u64).should be_nil

  # A pre-fix crash could have committed the removed state before deleting
  # either secret. Loading that legacy state must repair its orphan records.
  seed_controller_credentials(completed, fabric)
  completed.close
  legacy = reopen.call
  legacy_store = Matter::Controller::StateStore.new(legacy)
  legacy_store.load.fabric.should be_nil
  Matter::Session::Case::ResumptionStore.new(legacy).find_by_id(id).should be_nil
  Matter::Controller::IcdPeerStore.new(legacy).find_peer(fabric.fabric_id,
    fabric.root_public_key, fabric.controller_node_id, 0x3333_u64).should be_nil

  legacy_store.save(Matter::Controller::State.new(fabric: fabric))
  Matter::Session::Case::ResumptionStore.new(legacy).find_by_peer(fabric.fabric_id,
    fabric.root_public_key, fabric.controller_node_id, 0x3333_u64).should be_nil
  Matter::Controller::IcdPeerStore.new(legacy).find_peer(fabric.fabric_id,
    fabric.root_public_key, fabric.controller_node_id, 0x3333_u64).should be_nil
  legacy.close
end

describe Matter::Controller::StateStore do
  it "rejects a stale full-state save and preserves an intervening journal update" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = sample_fabric
    store.save(Matter::Controller::State.new(fabric: fabric))
    stale = store.load
    store.update do |current|
      current.pending_datastore_nodes << Matter::Controller::PendingDatastoreNode.new(
        fabric.fabric_id, fabric.root_public_key.dup, fabric.controller_node_id,
        0x3333_u64, "Lamp", Time.utc.to_unix + 60)
    end
    stale.unsecured_message_counter = 42_u32

    expect_raises(Matter::StorageError, /changed since load/) { store.save(stale) }
    store.load.pending_datastore_nodes.size.should eq(1)
    store.load.unsecured_message_counter.should eq(0_u32)
  end

  it "rejects a second save from a copied loaded snapshot" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    store.save(Matter::Controller::State.new(fabric: sample_fabric))
    first = store.load
    second = first
    first.unsecured_message_counter = 1_u32
    store.save(first)
    second.unsecured_message_counter = 2_u32

    expect_raises(Matter::StorageError, /changed since load/) { store.save(second) }
    store.load.unsecured_message_counter.should eq(1_u32)
  end

  it "persists replaced IPK epochs without losing the controller's peers" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = sample_fabric
    state = Matter::Controller::State.new(fabric: fabric)
    state.record_node(fabric.fabric_id, Matter::Controller::NodeInfo.new(0x3333_u64, "127.0.0.1", 5540))
    store.save(state)

    loaded = store.load
    rotated = loaded.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
    rotated.ipk_epoch_keys = [fabric.ipk_value, Bytes.new(16, 0xBB_u8), Bytes.new(16, 0xCC_u8)]
    loaded.replace_fabric(rotated)
    store.save(loaded)

    restored = store.load
    restored.fabric.as(Matter::Controller::FabricInfo).ipk_epoch_keys.should eq(rotated.ipk_epoch_keys)
    restored.nodes.has_key?(0x3333_u64).should be_true
  end

  it "persists controller fabric credentials in SQLite across restart" do
    path = File.join(Dir.tempdir, "matter-controller-#{Random::Secure.hex(6)}.sqlite3")
    begin
      backend = Matter::Storage::Sqlite.new(path)
      fabric = sample_fabric
      Matter::Controller::StateStore.new(backend).save(Matter::Controller::State.new(fabric: fabric))
      backend.close

      reopened = Matter::Storage::Sqlite.new(path)
      loaded = Matter::Controller::StateStore.new(reopened).load
      loaded.fabric.as(Matter::Controller::FabricInfo).to_document.should eq(fabric.to_document)
      reopened.destroy!
    ensure
      File.delete?(path)
    end
  end

  it "erases controller ICD Check-In keys when their fabric is removed" do
    backend = Matter::Storage::Memory.new
    state_store = Matter::Controller::StateStore.new(backend)
    fabric = sample_fabric
    state_store.save(Matter::Controller::State.new(fabric: fabric))
    icd_store = Matter::Controller::IcdPeerStore.new(backend)
    icd_store.save(Matter::Controller::IcdPeerStore::Record.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      0x3333_u64, Bytes.new(16, 0x55_u8), 10_u32, 11_u32))

    state = state_store.load
    state.remove_fabric(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id)
    state_store.save(state)

    icd_store.find_peer(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 0x3333_u64).should be_nil
  end

  it "deletes CASE resumption secrets when a controller fabric is removed" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::StateStore.new(backend)
    fabric = sample_fabric
    store.save(Matter::Controller::State.new(fabric: fabric))
    resume_store = Matter::Session::Case::ResumptionStore.new(backend)
    id = Bytes.new(16, 0x11_u8)
    resume_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      0x3333_u64, id, Bytes.new(32, 0x22_u8), [0x3333_u64]))

    state = store.load
    state.remove_fabric(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id)
    store.save(state)

    resume_store.find_by_id(id).should be_nil
  end

  it "rolls back a YAML controller removal if credential cleanup fails and repairs legacy orphans" do
    with_temp_file do |path|
      backend = FailingControllerYamlFile.new(path)
      backend.fail_credential_delete = true
      assert_atomic_controller_removal(backend,
        -> { Matter::Storage::YamlFile.new(path).as(Matter::Storage::Backend) })
    end
  end

  it "rolls back a SQLite controller removal if credential cleanup fails and repairs legacy orphans" do
    path = File.join(Dir.tempdir, "matter-controller-#{Random::Secure.hex(6)}.sqlite3")
    begin
      backend = FailingControllerSqlite.new(path)
      backend.fail_credential_delete = true
      assert_atomic_controller_removal(backend,
        -> { Matter::Storage::Sqlite.new(path).as(Matter::Storage::Backend) })
    ensure
      File.delete?(path)
    end
  end

  it "retains device CASE resumptions when a JFA shares its backend with the controller" do
    backend = Matter::Storage::Memory.new
    fabric = sample_fabric
    device_fabric = Matter::Fabric.new(fabric_id: fabric.fabric_id,
      fabric_index: 1_u8, node_id: fabric.controller_node_id,
      root_public_key: fabric.root_public_key,
      operational_cert: fabric.controller_noc,
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: fabric.ipk_value)
    backend.write(Matter::Storage::Collections::FABRICS, "1", device_fabric.to_document)
    resume_store = Matter::Session::Case::ResumptionStore.new(backend)
    responder_id = Bytes.new(16, 0x22_u8)
    initiator_id = Bytes.new(16, 0x33_u8)
    resume_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      0x3333_u64, responder_id, Bytes.new(32, 0x22_u8), [0x3333_u64],
      role: Matter::Session::Case::Role::Responder))
    Matter::Controller::IcdPeerStore.new(backend).save(
      Matter::Controller::IcdPeerStore::Record.new(fabric.fabric_id,
        fabric.root_public_key, fabric.controller_node_id, 0x3333_u64,
        Bytes.new(16, 0x55_u8), 10_u32, 11_u32))
    store = Matter::Controller::StateStore.new(backend)

    store.load.fabric.should be_nil
    resume_store.find_by_id(responder_id, Matter::Session::Case::Role::Responder).should_not be_nil
    store.save(Matter::Controller::State.new(fabric: fabric))
    resume_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      0x3333_u64, initiator_id, Bytes.new(32, 0x44_u8), [0x3333_u64],
      role: Matter::Session::Case::Role::Initiator))
    resume_store.find_by_id(initiator_id, Matter::Session::Case::Role::Initiator).should_not be_nil
    resume_store.find_by_id(responder_id, Matter::Session::Case::Role::Responder).should_not be_nil
    state = store.load
    state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
    store.save(state)

    resume_store.find_by_id(initiator_id).should be_nil
    resume_store.find_by_id(responder_id, Matter::Session::Case::Role::Responder).should_not be_nil
    Matter::Controller::IcdPeerStore.new(backend).find_peer(fabric.fabric_id,
      fabric.root_public_key, fabric.controller_node_id, 0x3333_u64).should be_nil
  end

  it "preserves an ambiguous legacy CASE record if a device has the same fabric identity" do
    backend = Matter::Storage::Memory.new
    fabric = sample_fabric
    device_fabric = Matter::Fabric.new(fabric_id: fabric.fabric_id,
      fabric_index: 1_u8, node_id: fabric.controller_node_id,
      root_public_key: fabric.root_public_key,
      operational_cert: fabric.controller_noc,
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: fabric.ipk_value)
    backend.write(Matter::Storage::Collections::FABRICS, "1", device_fabric.to_document)
    id = seed_controller_credentials(backend, fabric)
    store = Matter::Controller::StateStore.new(backend)

    store.load.fabric.should be_nil
    resume_store = Matter::Session::Case::ResumptionStore.new(backend)
    resume_store.find_by_id(id).should_not be_nil
    resume_store.find_by_id(id, Matter::Session::Case::Role::Responder).should be_nil
    store.save(Matter::Controller::State.new(fabric: fabric))
    state = store.load
    state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
    store.save(state)
    resume_store.find_by_id(id).should_not be_nil
  end

  it "keeps ambiguous device secrets when a device fabric document is unreadable" do
    backend = Matter::Storage::Memory.new
    fabric = sample_fabric
    backend.write(Matter::Storage::Collections::FABRICS, "1",
      Matter::Storage::Document{"fabric_id" => fabric.fabric_id})
    store = Matter::Controller::StateStore.new(backend)
    resume_store = Matter::Session::Case::ResumptionStore.new(backend)
    id = Bytes.new(16, 0x44_u8)
    resume_store.save(Matter::Session::Case::ResumptionStore::Record.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      0x3333_u64, id, Bytes.new(32, 0x55_u8), [0x3333_u64],
      role: Matter::Session::Case::Role::Responder))

    store.load.fabric.should be_nil
    resume_store.find_by_id(id, Matter::Session::Case::Role::Responder).should_not be_nil
    store.save(Matter::Controller::State.new(fabric: fabric))
    resume_store.find_by_id(id, Matter::Session::Case::Role::Responder).should_not be_nil
  end

  it "continues controller state operations past malformed credential documents" do
    backend = Matter::Storage::Memory.new
    fabric = sample_fabric
    store = Matter::Controller::StateStore.new(backend)
    store.save(Matter::Controller::State.new(fabric: fabric))
    malformed = Matter::Storage::Document{"invalid" => true}
    backend.write(Matter::Session::Case::ResumptionStore::COLLECTION, "broken", malformed)
    backend.write(Matter::Controller::IcdPeerStore::COLLECTION, "broken", malformed)

    store.load.fabric.should_not be_nil
    state = store.load
    state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
    store.save(state)
    store.load.fabric.should be_nil
    backend.read(Matter::Session::Case::ResumptionStore::COLLECTION, "broken").should_not be_nil
    backend.read(Matter::Controller::IcdPeerStore::COLLECTION, "broken").should_not be_nil
  end

  it "matches the device's operational discovery fabric identifier" do
    info = sample_fabric
    device_fabric = Matter::Fabric.new(
      fabric_id: info.fabric_id,
      fabric_index: 1_u8,
      node_id: info.controller_node_id,
      root_public_key: info.root_public_key,
      operational_cert: info.controller_noc,
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: info.ipk_value
    )

    IO::ByteFormat::BigEndian.decode(UInt64, device_fabric.compressed_fabric_id).should eq(info.compressed_fabric_id)
    info.compressed_fabric_id.should_not eq(info.fabric_id)
  end

  it "loads empty state when nothing is stored" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.fabric.should be_nil
    state.nodes.should be_empty
    state.commissioner_node_id.should_not eq(0_u64)
    state.unsecured_message_counter.should eq(0_u32)
  end

  it "does not write a generated commissioner id until saved" do
    backend = Matter::Storage::Memory.new
    Matter::Controller::StateStore.new(backend).load
    backend.collections.should eq([Matter::Storage::Collections::META])
  end

  it "round-trips fabric and nodes through a YAML file" do
    with_temp_file do |path|
      store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))

      nodes = {
        0x1_u64 => Matter::Controller::NodeInfo.new(node_id: 0x1_u64, address: "192.168.1.10", port: 5540),
        0x2_u64 => Matter::Controller::NodeInfo.new(node_id: 0x2_u64, address: nil, port: 5540),
      }

      store.save(Matter::Controller::State.new(fabric: sample_fabric, nodes: nodes))
      store.backend.close

      loaded = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path)).load
      loaded.commissioner_node_id.should eq(0x2222_u64)
      loaded.unsecured_message_counter.should eq(0_u32)
      fabric = loaded.fabric.as(Matter::Controller::FabricInfo)
      fabric.fabric_id.should eq(0x1111_u64)
      fabric.controller_node_id.should eq(0x2222_u64)
      fabric.ipk_value.should eq(Bytes.new(16, 0xAA_u8))
      fabric.root_public_key.size.should eq(65)
      fabric.controller_private_key.should eq(Bytes.new(32, 0xCC_u8))

      loaded.nodes.size.should eq(2)
      loaded.nodes[0x1_u64].address.should eq("192.168.1.10")
      loaded.nodes[0x1_u64].port.should eq(5540)
      loaded.nodes[0x2_u64].address.should be_nil
    end
  end

  it "stores the state as the controller/state document" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::StateStore.new(backend)
    store.save(Matter::Controller::State.new(fabric: sample_fabric, commissioner_node_id: 0x2222_u64, unsecured_message_counter: 9_u32))

    document = backend.read(Matter::Controller::StateStore::COLLECTION, Matter::Controller::StateStore::DOCUMENT_ID).as(Matter::Storage::Document)
    document["commissioner_node_id"].should eq(0x2222_i64)
    document["unsecured_message_counter"].should eq(9_i64)
    document["fabric"].as(Matter::Storage::Document)["ipk_value"].should eq(Bytes.new(16, 0xAA_u8))
    document["nodes"].should eq(Matter::Storage::Document.new)
  end

  it "aligns a stored commissioner id with the fabric and writes it back" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::StateStore.new(backend)
    store.save(Matter::Controller::State.new(fabric: sample_fabric, commissioner_node_id: 0x9999_u64))

    store.load.commissioner_node_id.should eq(0x2222_u64)
    document = backend.read(Matter::Controller::StateStore::COLLECTION, Matter::Controller::StateStore::DOCUMENT_ID).as(Matter::Storage::Document)
    document["commissioner_node_id"].should eq(0x2222_i64)
  end

  it "persists an optional intermediate certificate for a shared fabric" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::StateStore.new(backend)
    original = sample_fabric
    fabric = Matter::Controller::FabricInfo.new(
      fabric_id: original.fabric_id,
      controller_node_id: original.controller_node_id,
      ipk_value: original.ipk_value,
      root_cert: original.root_cert,
      root_public_key: original.root_public_key,
      controller_noc: original.controller_noc,
      controller_private_key: original.controller_private_key,
      intermediate_cert: Bytes[0x15, 0x18]
    )
    store.save(Matter::Controller::State.new(fabric: fabric))

    store.load.fabric.as(Matter::Controller::FabricInfo).intermediate_cert.should eq(Bytes[0x15, 0x18])
  end

  it "keeps peers separate across fabrics and persists the selected fabric" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::StateStore.new(backend)
    first = sample_fabric
    second = Matter::Controller::FabricInfo.new(
      fabric_id: first.fabric_id,
      controller_node_id: 0x3333_u64,
      ipk_value: Bytes.new(16, 0xDD_u8),
      root_cert: first.root_cert,
      root_public_key: Bytes[0x04_u8] + Bytes.new(64, 0xEE_u8),
      controller_noc: first.controller_noc,
      controller_private_key: first.controller_private_key
    )
    state = Matter::Controller::State.new
    state.install_fabric(first)
    state.record_node(first.fabric_id, Matter::Controller::NodeInfo.new(0x10_u64, "192.0.2.1"), first.root_public_key)
    state.install_fabric(second)
    state.record_node(second.fabric_id, Matter::Controller::NodeInfo.new(0x10_u64, "192.0.2.2"), second.root_public_key)

    expect_raises(Matter::ConfigurationError, /ambiguous/) { state.fabric_for(first.fabric_id) }
    state.select_fabric(second.fabric_id, second.root_public_key)
    state.commissioner_node_id.should eq(second.controller_node_id)
    store.save(state)

    loaded = store.load
    loaded.fabric.as(Matter::Controller::FabricInfo).root_public_key.should eq(second.root_public_key)
    loaded.nodes[0x10_u64].address.should eq("192.0.2.2")
    loaded.nodes_for(first.fabric_id, first.root_public_key)[0x10_u64].address.should eq("192.0.2.1")
    loaded.select_fabric(first.fabric_id, first.root_public_key)
    loaded.nodes[0x10_u64].address.should eq("192.0.2.1")
  end

  it "removes one controller identity and its remembered peers" do
    first = sample_fabric
    second = Matter::Controller::FabricInfo.new(
      fabric_id: 0x4444_u64,
      controller_node_id: 0x5555_u64,
      ipk_value: first.ipk_value,
      root_cert: first.root_cert,
      root_public_key: first.root_public_key,
      controller_noc: first.controller_noc,
      controller_private_key: first.controller_private_key
    )
    state = Matter::Controller::State.new
    state.install_fabric(first)
    state.install_fabric(second)
    state.record_node(first.fabric_id, Matter::Controller::NodeInfo.new(0x10_u64), first.root_public_key)
    state.record_node(second.fabric_id, Matter::Controller::NodeInfo.new(0x20_u64), second.root_public_key)

    state.remove_fabric(first.fabric_id, first.root_public_key, first.controller_node_id).should eq(first)
    state.fabric.should eq(second)
    state.commissioner_node_id.should eq(second.controller_node_id)
    state.nodes.keys.should eq([0x20_u64])
    expect_raises(Matter::ConfigurationError) { state.fabric_for(first.fabric_id, first.root_public_key) }
  end

  it "normalizes the active commissioner ID without losing other fabrics" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    first = sample_fabric
    second = Matter::Controller::FabricInfo.new(
      fabric_id: 0x4444_u64,
      controller_node_id: 0x5555_u64,
      ipk_value: first.ipk_value,
      root_cert: first.root_cert,
      root_public_key: first.root_public_key,
      controller_noc: first.controller_noc,
      controller_private_key: first.controller_private_key
    )
    state = Matter::Controller::State.new
    state.install_fabric(first)
    state.install_fabric(second)
    state.commissioner_node_id = 0x9999_u64
    store.save(state)

    loaded = store.load
    loaded.commissioner_node_id.should eq(first.controller_node_id)
    loaded.fabric_for(second.fabric_id).controller_node_id.should eq(second.controller_node_id)
    store.load.fabric_for(second.fabric_id).controller_node_id.should eq(second.controller_node_id)
  end

  it "loads and extends a legacy single-fabric document" do
    backend = Matter::Storage::Memory.new
    legacy = Matter::Controller::State.new(
      fabric: sample_fabric,
      nodes: {0x10_u64 => Matter::Controller::NodeInfo.new(0x10_u64, "192.0.2.1")}
    ).to_document
    legacy.delete("other_fabrics")
    legacy.delete("other_nodes")
    backend.write(Matter::Controller::StateStore::COLLECTION, Matter::Controller::StateStore::DOCUMENT_ID, legacy)

    state = Matter::Controller::StateStore.new(backend).load
    state.fabrics.size.should eq(1)
    state.nodes_for(sample_fabric.fabric_id, sample_fabric.root_public_key)[0x10_u64].address.should eq("192.0.2.1")
  end

  it "selects a controller identity from global CLI options" do
    directory = File.join(Dir.tempdir, "matter-controller-cli-#{Random::Secure.hex(6)}")
    context = ChipTool::Context.new(directory)
    first = sample_fabric
    second = Matter::Controller::FabricInfo.new(
      fabric_id: first.fabric_id,
      controller_node_id: 0x3333_u64,
      ipk_value: first.ipk_value,
      root_cert: first.root_cert,
      root_public_key: first.root_public_key,
      controller_noc: first.controller_noc,
      controller_private_key: first.controller_private_key
    )
    state = Matter::Controller::State.new
    state.install_fabric(first)
    state.install_fabric(second)
    context.state_store.save(state)

    selected_context, args = ChipTool::Context.parse([
      "pairing", "fabrics", "--storage-directory", directory,
      "--fabric-id", "0x#{first.fabric_id.to_s(16)}",
      "--root-public-key", first.root_public_key.hexstring,
      "--controller-node-id", "0x#{second.controller_node_id.to_s(16)}",
    ])
    args.should eq(["pairing", "fabrics"])
    selected_context.state_store.load.fabric.as(Matter::Controller::FabricInfo).controller_node_id.should eq(second.controller_node_id)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "wraps decode failures in a StorageError" do
    backend = Matter::Storage::Memory.new
    backend.write(Matter::Controller::StateStore::COLLECTION, Matter::Controller::StateStore::DOCUMENT_ID, Matter::Storage::Document{"nodes" => "bogus"})

    expect_raises(Matter::StorageError, /nodes/) do
      Matter::Controller::StateStore.new(backend).load
    end
  end
end
