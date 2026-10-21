require "../../spec_helper"
require "../../../src/matter/session/case/resumption_store"
require "../../../src/matter/storage/yaml_file"
require "file_utils"

private def stored_case_record(root : Bytes, id : Bytes, peer : UInt64 = 0x2222_u64) : Matter::Session::Case::ResumptionStore::Record
  Matter::Session::Case::ResumptionStore::Record.new(
    fabric_id: 0x1234_u64,
    root_public_key: root,
    local_node_id: 0x1111_u64,
    peer_node_id: peer,
    resumption_id: id,
    shared_secret: Bytes.new(32, 0x33_u8),
    peer_subject_ids: [peer, 0xFFFF_FFFD_0001_0002_u64])
end

describe Matter::Session::Case::ResumptionStore do
  it "restores a record by ID and fabric/peer after restart, then rotates its ID" do
    backend = Matter::Storage::Memory.new
    backend.open
    root = Bytes.new(65, 0x04_u8)
    first_id = Bytes.new(16, 0x11_u8)
    next_id = Bytes.new(16, 0x22_u8)
    store = Matter::Session::Case::ResumptionStore.new(backend)
    store.save(stored_case_record(root, first_id))

    restarted = Matter::Session::Case::ResumptionStore.new(backend)
    restarted.find_by_id(first_id).try(&.peer_node_id).should eq(0x2222_u64)
    restarted.find_by_peer(0x1234_u64, root, 0x1111_u64, 0x2222_u64)
      .try(&.resumption_id).should eq(first_id)

    restarted.save(stored_case_record(root, next_id))
    restarted.find_by_id(first_id).should be_nil
    restarted.find_by_id(next_id).should_not be_nil
  end

  it "removes records with their fabric and does not reuse them for another root" do
    backend = Matter::Storage::Memory.new
    backend.open
    root = Bytes.new(65, 0x04_u8)
    other_root = Bytes.new(65, 0x05_u8)
    id = Bytes.new(16, 0x11_u8)
    store = Matter::Session::Case::ResumptionStore.new(backend)
    store.save(stored_case_record(root, id))

    store.find_by_peer(0x1234_u64, other_root, 0x1111_u64, 0x2222_u64).should be_nil
    store.find_by_peer(0x1234_u64, root, 0x1111_u64, 0x9999_u64).should be_nil
    store.remove_fabric(0x1234_u64, root, 0x1111_u64)
    store.find_by_id(id).should be_nil
    Matter::Session::Case::ResumptionStore.new(backend).find_by_id(id).should be_nil
  end

  it "persists the rotated secret in a file-backed store across process restarts" do
    directory = File.join(Dir.tempdir, "matter-case-resume-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    begin
      path = File.join(directory, "state.yml")
      root = Bytes.new(65, 0x04_u8)
      first_id = Bytes.new(16, 0x11_u8)
      rotated_id = Bytes.new(16, 0x22_u8)
      backend = Matter::Storage::YamlFile.new(path)
      store = Matter::Session::Case::ResumptionStore.new(backend)
      store.save(stored_case_record(root, first_id))
      backend.close

      backend = Matter::Storage::YamlFile.new(path)
      store = Matter::Session::Case::ResumptionStore.new(backend)
      store.find_by_id(first_id).try(&.shared_secret).should eq(Bytes.new(32, 0x33_u8))
      store.save(stored_case_record(root, rotated_id))
      backend.close

      backend = Matter::Storage::YamlFile.new(path)
      store = Matter::Session::Case::ResumptionStore.new(backend)
      store.find_by_id(first_id).should be_nil
      store.find_by_id(rotated_id).try(&.peer_subject_ids)
        .should eq([0x2222_u64, 0xFFFF_FFFD_0001_0002_u64])
      backend.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
