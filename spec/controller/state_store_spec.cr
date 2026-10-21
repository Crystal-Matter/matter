require "../spec_helper"
require "../../src/matter/controller/state_store"
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

describe Matter::Controller::StateStore do
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
