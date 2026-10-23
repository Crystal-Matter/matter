require "../spec_helper"

module MigratorSpec
  include Matter::Storage

  FABRIC_ONE = "1"
  FABRIC_TWO = "2"
  SESSION    = "s1"
  CUSTOM     = "custom-scheme"

  SAMPLE_TIME = Time.utc(2026, 9, 10, 1, 2, 3, nanosecond: 987_654_321)

  class CountingJsonFile < Matter::Storage::JsonFile
    getter flushes = 0

    def flush : Nil
      @flushes += 1
      super
    end
  end

  def self.fabric(id : Int64) : Document
    Document{
      "fabric_id" => id,
      "node_id"   => UInt64::MAX - id.to_u64,
      "label"     => "fabric #{id}",
      "ipk"       => Bytes[id.to_u8, 0xAA, 0xBB],
      "joined"    => SAMPLE_TIME,
      "tags"      => ([1_i64, "two", nil] of Type).as(Type),
      "nested"    => Document{"ratio" => 0.5, "quoted" => "42"}.as(Type),
    }
  end

  def self.with_temp_dir(& : String ->) : Nil
    directory = File.join(Dir.tempdir, "matter-migrator-spec-#{Random::Secure.hex(6)}")
    begin
      yield directory
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  def self.seed(backend : Backend) : Nil
    backend.write(Collections::FABRICS, FABRIC_ONE, fabric(1_i64))
    backend.write(Collections::FABRICS, FABRIC_TWO, fabric(2_i64))
    backend.write(Collections::SESSIONS, SESSION, Document{"counter" => 7_i64})
    backend.write(Collections::META, "extra", Document{"ignored" => true})
  end

  def self.expect_seeded(backend : Backend) : Nil
    backend.collections.should eq([Collections::FABRICS, Collections::META, Collections::SESSIONS])
    backend.read(Collections::FABRICS, FABRIC_ONE).should eq(fabric(1_i64))
    backend.read(Collections::FABRICS, FABRIC_TWO).should eq(fabric(2_i64))
    backend.read(Collections::FABRICS, FABRIC_ONE).as(Document)["node_id"].should be_a(UInt64)
    backend.read(Collections::FABRICS, FABRIC_ONE).as(Document)["joined"].should eq(SAMPLE_TIME)
    backend.read(Collections::SESSIONS, SESSION).should eq(Document{"counter" => 7_i64})
    backend.ids(Collections::META).should eq([Collections::META_SCHEMA_ID])
  end
end

describe Matter::Storage::Migrator do
  describe ".copy" do
    it "copies YAML to JSON to memory losslessly, skipping meta" do
      MigratorSpec.with_temp_dir do |directory|
        yaml = Matter::Storage::YamlFile.new(File.join(directory, "store.yml")).tap(&.open)
        MigratorSpec.seed(yaml)

        json = MigratorSpec::CountingJsonFile.new(File.join(directory, "store.json")).tap(&.open)
        counts = Matter::Storage::Migrator.copy(yaml, json)
        counts.should eq({Matter::Storage::Collections::FABRICS => 2, Matter::Storage::Collections::SESSIONS => 1})
        json.flushes.should eq(1)
        MigratorSpec.expect_seeded(json)
        json.close

        reopened = Matter::Storage::JsonFile.new(File.join(directory, "store.json")).tap(&.open)
        memory = Matter::Storage::Memory.new
        Matter::Storage::Migrator.copy(reopened, memory).should eq(counts)
        MigratorSpec.expect_seeded(memory)

        yaml.destroy!
        reopened.destroy!
      end
    end

    it "copies an empty store" do
      source = Matter::Storage::Memory.new
      target = Matter::Storage::Memory.new
      Matter::Storage::Migrator.copy(source, target).should be_empty
      target.collections.should eq([Matter::Storage::Collections::META])
    end
  end

  describe ".open" do
    it "opens a memory store" do
      backend = Matter::Storage::Migrator.open("memory:")
      backend.should be_a(Matter::Storage::Memory)
      backend.open?.should be_true
      backend.path.should be_nil
    end

    it "opens YAML and JSON stores by path" do
      MigratorSpec.with_temp_dir do |directory|
        yaml_path = File.join(directory, "a.yml")
        json_path = File.join(directory, "b.json")

        yaml = Matter::Storage::Migrator.open("yaml:#{yaml_path}")
        yaml.should be_a(Matter::Storage::YamlFile)
        yaml.open?.should be_true
        yaml.path.should eq(yaml_path)

        json = Matter::Storage::Migrator.open("json:#{json_path}")
        json.should be_a(Matter::Storage::JsonFile)
        json.open?.should be_true
        json.path.should eq(json_path)

        yaml.destroy!
        json.destroy!
      end
    end

    it "rejects URIs without a scheme or path" do
      expect_raises(Matter::StorageError, /no scheme/) { Matter::Storage::Migrator.open("store.yml") }
      expect_raises(Matter::StorageError, /no scheme/) { Matter::Storage::Migrator.open("") }
      expect_raises(Matter::StorageError, /file path/) { Matter::Storage::Migrator.open("yaml:") }
      expect_raises(Matter::StorageError, /file path/) { Matter::Storage::Migrator.open("json:") }
    end

    it "rejects unknown schemes" do
      expect_raises(Matter::StorageError, /Unknown storage URI scheme "unregistered"/) { Matter::Storage::Migrator.open("unregistered:store.db") }
    end

    it "raises for the legacy scheme when the importer is not loaded or the file is missing" do
      # Without `require "matter/storage/legacy"` the message explains how to enable the scheme;
      # with it loaded (as in the full suite) the importer reports the missing file.
      expect_raises(Matter::StorageError, /legacy/i) { Matter::Storage::Migrator.open("legacy:old.json") }
    end

    it "dispatches registered schemes" do
      received = nil
      registered = Matter::Storage::Memory.new
      Matter::Storage::Migrator.register_scheme(MigratorSpec::CUSTOM) do |rest|
        received = rest
        registered
      end

      Matter::Storage::Migrator.open("#{MigratorSpec::CUSTOM}:some/where:else").should be(registered)
      received.should eq("some/where:else")
    end
  end
end
