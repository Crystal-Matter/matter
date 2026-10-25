require "./spec_helper"
require "log/spec"
require "../src/matter/controller/joint_commissioning"
require "../src/matter/storage/sqlite"

private def build_fabric(fabric_index : UInt8, fabric_id : UInt64 = fabric_index.to_u64) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: fabric_id,
    fabric_index: fabric_index,
    node_id: 0x1_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16),
    label: "Fabric #{fabric_index}"
  )
end

private def with_temp_file(extension : String, & : String ->) : Nil
  path = File.join(Dir.tempdir, "matter-fabric-table-#{Random::Secure.hex(6)}#{extension}")
  yield path
ensure
  File.delete?(path) if path
end

private class FailFabricDeleteYamlFile < Matter::Storage::YamlFile
  property? fail_next_fabric_delete : Bool = false

  def delete(collection : String, id : String) : Nil
    if @fail_next_fabric_delete && collection == Matter::FabricTable::COLLECTION
      @fail_next_fabric_delete = false
      raise Matter::StorageError.new("Injected fabric delete failure")
    end
    super
  end
end

# A fabric id above Int64::MAX exercises the UInt64 path of every backend.
private HUGE_FABRIC_ID = 0xFFFF_FFFF_FFFF_FFF0_u64

private def round_trips_through(backend : Matter::Storage::Backend) : Nil
  fabric = build_fabric(1_u8, HUGE_FABRIC_ID)
  backend.open
  table = Matter::FabricTable.new(backend)
  table.add_fabric(fabric).should be_true
  backend.close

  backend.open
  reloaded = Matter::FabricTable.new(backend).get_fabric(1_u8).as(Matter::Fabric)
  reloaded.fabric_id.should eq(HUGE_FABRIC_ID)
  reloaded.label.should eq("Fabric 1")
  reloaded.operational_key.private_bits.should eq(fabric.operational_key.private_bits)
  reloaded.operational_key.public_bits.should eq(fabric.operational_key.public_bits)
  reloaded.ipk.should eq(fabric.ipk)
  reloaded.created_at.should eq(fabric.created_at)
  backend.close
end

describe Matter::FabricTable do
  describe "initialization" do
    it "creates empty fabric table" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      table.size.should eq(0)
      table.empty?.should be_true
      table.full?.should be_false
    end

    it "validates max_fabrics minimum" do
      storage = Matter::Storage::Memory.new
      expect_raises(ArgumentError, /must be >= 5/) do
        Matter::FabricTable.new(storage, max_fabrics: 4_u8)
      end
    end

    it "validates max_fabrics maximum" do
      storage = Matter::Storage::Memory.new
      expect_raises(ArgumentError, /must be <= 254/) do
        Matter::FabricTable.new(storage, max_fabrics: 255_u8)
      end
    end
  end

  describe "adding fabrics" do
    it "adds a fabric" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table.add_fabric(build_fabric(1_u8)).should be_true
      table.size.should eq(1)
      table.empty?.should be_false
    end

    it "adds fabric with auto index" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      fabric = table.add_fabric_auto_index(
        fabric_id: 0x1_u64,
        node_id: 0x1_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: Matter::Crypto::Key.generate_key_pair,
        ipk: Random::Secure.random_bytes(16),
        label: "Auto"
      )

      fabric.should_not be_nil
      fabric.as(Matter::Fabric).fabric_index.should eq(1_u8)
      table.size.should eq(1)
    end

    it "retains NOC CATs when adding and reloading an automatically indexed fabric" do
      bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
        0xA100_u64, 0xA101_u64, 0xFFF1_u16)
      key = Matter::Crypto::Key.generate_key_pair
      noc = bootstrap.issue_anchor_administrator_noc(0xA102_u64, key.public_key)
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      fabric = table.add_fabric_auto_index(
        fabric_id: bootstrap.fabric.fabric_id,
        node_id: 0xA102_u64,
        root_public_key: bootstrap.fabric.root_public_key,
        operational_cert: noc,
        operational_key: key,
        ipk: bootstrap.fabric.ipk_value,
        intermediate_cert: bootstrap.fabric.intermediate_cert,
        root_cert: bootstrap.fabric.root_cert
      ).as(Matter::Fabric)
      fabric.cats.map(&.value).should eq([0xFFFF_0001_u32, 0xFFFE_0001_u32])
      Matter::FabricTable.new(storage).get_fabric(fabric.fabric_index).as(Matter::Fabric)
        .cats.map(&.value).should eq([0xFFFF_0001_u32, 0xFFFE_0001_u32])
    end

    it "prevents duplicate fabric indices" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table.add_fabric(build_fabric(1_u8, 0x1_u64)).should be_true
      table.add_fabric(build_fabric(1_u8, 0x2_u64)).should be_false
      table.size.should eq(1)
    end

    it "allows duplicate fabric IDs across different roots" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table.add_fabric(build_fabric(1_u8, 0x1_u64)).should be_true
      table.add_fabric(build_fabric(2_u8, 0x1_u64)).should be_true
      table.size.should eq(2)
    end

    it "prevents duplicate fabric identities (same root_public_key + fabric_id)" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)
      key = Matter::Crypto::Key.generate_key_pair
      ipk = Random::Secure.random_bytes(16)
      root_key = Random::Secure.random_bytes(65)

      fabric1 = Matter::Fabric.new(
        fabric_id: 0x1_u64,
        fabric_index: 1_u8,
        node_id: 0x1_u64,
        root_public_key: root_key,
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk
      )

      fabric2 = Matter::Fabric.new(
        fabric_id: 0x1_u64, # Same fabric ID
        fabric_index: 2_u8,
        node_id: 0x2_u64,
        root_public_key: root_key, # Same root key
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: key,
        ipk: ipk
      )

      table.add_fabric(fabric1).should be_true
      table.add_fabric(fabric2).should be_false
      table.size.should eq(1)
    end

    it "respects max_fabrics limit" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 5_u8) # Matter spec minimum

      (1..5).each do |i|
        table.add_fabric(build_fabric(i.to_u8)).should be_true
      end

      table.full?.should be_true
      table.size.should eq(5)

      table.add_fabric(build_fabric(6_u8)).should be_false # At capacity
      table.size.should eq(5)
    end
  end

  describe "removing fabrics" do
    it "keeps a fabric index reserved when its stored document cannot be deleted" do
      with_temp_file(".yml") do |path|
        storage = FailFabricDeleteYamlFile.new(path)
        storage.open
        table = Matter::FabricTable.new(storage)
        original = build_fabric(1_u8)
        table.add_fabric(original).should be_true

        storage.fail_next_fabric_delete = true
        expect_raises(Matter::StorageError, /Injected fabric delete failure/) do
          table.remove_fabric(1_u8)
        end

        table.get_fabric(1_u8).should eq(original)
        table.next_available_index.should eq(2_u8)
        table.add_fabric(build_fabric(1_u8)).should be_false

        reloaded = Matter::Storage::YamlFile.new(path)
        reloaded.open
        reloaded.read(Matter::FabricTable::COLLECTION, "1").should_not be_nil
        Matter::FabricTable.new(reloaded).get_fabric(1_u8).should_not be_nil
        reloaded.close

        table.remove_fabric(1_u8).should be_true
        table.next_available_index.should eq(1_u8)
        storage.read(Matter::FabricTable::COLLECTION, "1").should be_nil
        storage.close
      end
    end

    it "removes fabric by index" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table.add_fabric(build_fabric(1_u8))
      table.size.should eq(1)

      table.remove_fabric(1_u8).should be_true
      table.size.should eq(0)
      storage.ids(Matter::FabricTable::COLLECTION).should be_empty
    end

    it "removes fabric by fabric ID" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table.add_fabric(build_fabric(1_u8, 0xAABBCCDD_u64))
      table.remove_fabric_by_id(0xAABBCCDD_u64).should be_true
      table.size.should eq(0)
    end

    it "returns false when removing non-existent fabric" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)
      table.remove_fabric(99_u8).should be_false
    end
  end

  describe "lookups" do
    it "gets fabric by index" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table.add_fabric(build_fabric(5_u8, 0x1_u64))
      found = table.get_fabric(5_u8)
      found.should_not be_nil
      found.as(Matter::Fabric).fabric_id.should eq(0x1_u64)
    end

    it "finds fabric by fabric ID" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table.add_fabric(build_fabric(1_u8, 0xDEADBEEF_u64))
      found = table.find_by_fabric_id(0xDEADBEEF_u64)
      found.should_not be_nil
      found.as(Matter::Fabric).fabric_index.should eq(1_u8)
    end
  end

  describe "persistence" do
    it "writes one document per fabric and loads them" do
      storage = Matter::Storage::Memory.new
      table1 = Matter::FabricTable.new(storage, max_fabrics: 10_u8)

      table1.add_fabric(build_fabric(1_u8, 0x123_u64))
      table1.add_fabric(build_fabric(3_u8, 0x456_u64))

      storage.ids(Matter::FabricTable::COLLECTION).should eq(["1", "3"])
      document = storage.read(Matter::FabricTable::COLLECTION, "1").as(Matter::Storage::Document)
      document["fabric_id"].should eq(0x123_i64)
      document["label"].should eq("Fabric 1")

      table2 = Matter::FabricTable.new(storage, max_fabrics: 10_u8)
      table2.size.should eq(2)
      table2.get_fabric(3_u8).as(Matter::Fabric).fabric_id.should eq(0x456_u64)
    end

    it "updates the fabric document" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      fabric = build_fabric(1_u8)
      table.add_fabric(fabric)

      fabric.label = "Renamed"
      table.update_fabric(fabric).should be_true
      storage.read(Matter::FabricTable::COLLECTION, "1").as(Matter::Storage::Document)["label"].should eq("Renamed")
    end

    it "clears the collection on clear_all" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      table.add_fabric(build_fabric(1_u8))
      table.add_fabric(build_fabric(2_u8))

      table.clear_all
      table.empty?.should be_true
      storage.ids(Matter::FabricTable::COLLECTION).should be_empty
    end

    it "writes mark_fabric_used immediately without a debouncer" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      fabric = build_fabric(1_u8)
      fabric.last_used_at = Time.utc(2020, 1, 1)
      table.add_fabric(fabric)

      table.mark_fabric_used(1_u8).should be_true
      stored = storage.read(Matter::FabricTable::COLLECTION, "1").as(Matter::Storage::Document)["last_used_at"].as(Time)
      stored.should be > Time.utc(2020, 1, 1)
    end

    it "defers mark_fabric_used writes to the debouncer" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      triggers = 0
      debouncer = Matter::Debouncer.new(1.hour) { }
      table.write_debouncer = debouncer
      fabric = build_fabric(1_u8)
      fabric.last_used_at = Time.utc(2020, 1, 1)
      table.add_fabric(fabric)

      table.mark_fabric_used(1_u8).should be_true
      triggers += 1 if debouncer.pending?
      triggers.should eq(1)
      storage.read(Matter::FabricTable::COLLECTION, "1").as(Matter::Storage::Document)["last_used_at"].should eq(Time.utc(2020, 1, 1))

      table.flush_pending_writes
      stored = storage.read(Matter::FabricTable::COLLECTION, "1").as(Matter::Storage::Document)["last_used_at"].as(Time)
      stored.should be > Time.utc(2020, 1, 1)
      debouncer.cancel
    end

    it "does not resurrect a removed fabric from a pending write" do
      storage = Matter::Storage::Memory.new
      table = Matter::FabricTable.new(storage)
      table.write_debouncer = Matter::Debouncer.new(1.hour) { }
      table.add_fabric(build_fabric(1_u8))

      table.mark_fabric_used(1_u8)
      table.remove_fabric(1_u8)
      table.flush_pending_writes
      storage.ids(Matter::FabricTable::COLLECTION).should be_empty
    end

    it "round trips a fabric id above Int64::MAX through a YAML file" do
      with_temp_file(".yml") do |path|
        round_trips_through(Matter::Storage::YamlFile.new(path))
      end
    end

    it "round trips a fabric id above Int64::MAX through a JSON file" do
      with_temp_file(".json") do |path|
        round_trips_through(Matter::Storage::JsonFile.new(path))
      end
    end

    it "round trips a fabric id above Int64::MAX through SQLite" do
      with_temp_file(".sqlite3") do |path|
        round_trips_through(Matter::Storage::Sqlite.new(path))
      end
    end
  end

  describe "loading" do
    it "skips a malformed document with a warning and loads the rest" do
      storage = Matter::Storage::Memory.new
      good = build_fabric(1_u8)
      bad = build_fabric(2_u8).to_document
      bad["fabric_id"] = "not a number"

      storage.write(Matter::FabricTable::COLLECTION, "1", good.to_document)
      storage.write(Matter::FabricTable::COLLECTION, "2", bad)

      table = nil
      ::Log.capture(Matter::FabricTable::Log.source, :warn) do |logs|
        table = Matter::FabricTable.new(storage)
        logs.check(:warn, /Skipping fabric document fabrics\/2/)
        logs.entry.exception.should be_a(Matter::StorageError)
      end

      table.as(Matter::FabricTable).size.should eq(1)
      table.as(Matter::FabricTable).get_fabric(1_u8).try(&.label).should eq("Fabric 1")
      table.as(Matter::FabricTable).get_fabric(2_u8).should be_nil
    end

    it "skips a document missing a required field" do
      storage = Matter::Storage::Memory.new
      incomplete = build_fabric(2_u8).to_document
      incomplete.delete("ipk")
      storage.write(Matter::FabricTable::COLLECTION, "1", build_fabric(1_u8).to_document)
      storage.write(Matter::FabricTable::COLLECTION, "2", incomplete)

      table = Matter::FabricTable.new(storage)
      table.size.should eq(1)
      table.get_fabric(1_u8).should_not be_nil
    end
  end
end
