require "../spec_helper"
require "log/spec"
require "../../src/matter/storage/sqlite"

# Behaviour every `Storage::Backend` must share, run against `Memory`,
# `YamlFile` and `JsonFile`; plus the file-only guarantees (atomic flush,
# persistence across reopen, corruption handling, schema versioning).
module BackendContract
  include Matter::Storage

  COLLECTION       = "things"
  OTHER_COLLECTION = "others"
  ID               = "one"
  OTHER_ID         = "two"
  THIRD_ID         = "three"
  SCHEMA_DOCUMENT  = Document{Collections::SCHEMA_VERSION_KEY => Collections::SCHEMA_VERSION}
  NEWER_SCHEMA     = Document{Collections::SCHEMA_VERSION_KEY => Collections::SCHEMA_VERSION + 1}

  SAMPLE_TIME = Time.utc(2026, 9, 10, 1, 2, 3, nanosecond: 123_456_789)
  LOCAL_TIME  = Time.local(2026, 9, 10, 11, 2, 3, nanosecond: 5, location: Time::Location.fixed(10 * 3600))
  BIG_FLOAT   = 1.0e100
  SMALL_FLOAT =  1.5e-7

  INVALID_NAMES = ["", "a/b", "a b", "ünï", "a\nb"]

  # A tiny corrupt payload that neither YAML nor JSON will parse.
  CORRUPT_CONTENT = "{[\n"
  CORRUPT_PATTERN = /\.corrupt-\d{8}T\d{6}\z/

  # Counts `flush` calls on a file backend so specs can pin "one flush per
  # transaction".
  module FlushCounter
    getter flushes = 0

    def flush : Nil
      @flushes += 1
      super
    end
  end

  class CountingYamlFile < Matter::Storage::YamlFile
    include FlushCounter
  end

  class CountingJsonFile < Matter::Storage::JsonFile
    include FlushCounter
  end

  class FailingYamlFile < Matter::Storage::YamlFile
    property? fail_next_flush = false

    protected def flush : Nil
      if @fail_next_flush
        @fail_next_flush = false
        raise Matter::StorageError.new("Interrupted before file rename")
      end
      super
    end
  end

  def self.sample_document : Document
    Document{
      "nil"            => nil,
      "true"           => true,
      "false"          => false,
      "int_min"        => Int64::MIN,
      "int_max"        => Int64::MAX,
      "uint_max"       => UInt64::MAX,
      "zero"           => 0_i64,
      "negative"       => -42_i64,
      "float"          => 3.14159,
      "float_whole"    => 1.0,
      "float_small"    => SMALL_FLOAT,
      "float_big"      => BIG_FLOAT,
      "infinity"       => Float64::INFINITY,
      "neg_infinity"   => -Float64::INFINITY,
      "string"         => "hello world",
      "empty_string"   => "",
      "numeric_string" => "123",
      "float_string"   => "1.5",
      "bool_string"    => "true",
      "null_string"    => "null",
      "tilde_string"   => "~",
      "time_string"    => "2026-09-10T01:02:03Z",
      "yaml_string"    => "- not: a list",
      "multiline"      => "line one\nline two\t\"quoted\" \\ back",
      "bytes"          => Bytes[0, 1, 2, 254, 255],
      "empty_bytes"    => Bytes.new(0),
      "time"           => SAMPLE_TIME,
      "array"          => ([1_i64, "two", nil, ([true, 2.5] of Type).as(Type), Document{"k" => "v"}.as(Type)] of Type).as(Type),
      "hash"           => Document{"nested" => Document{"deep" => ([Bytes[9]] of Type).as(Type)}.as(Type), "n" => 7_i64}.as(Type),
      "empty_array"    => ([] of Type).as(Type),
      "empty_hash"     => Document.new.as(Type),
    }
  end

  def self.with_temp_path(extension : String, & : String ->) : Nil
    directory = File.join(Dir.tempdir, "matter-storage-spec-#{Random::Secure.hex(6)}")
    path = File.join(directory, "nested", "store#{extension}")
    begin
      yield path
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  # Runs the shared examples. *factory* receives a fresh path (unused by
  # `Memory`) and returns an opened backend.
  def self.run(name : String, extension : String, &factory : String -> Matter::Storage::Backend) : Nil
    describe name do
      it "starts with only the schema document" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.open?.should be_true
          backend.collections.should eq([Collections::META])
          backend.read(Collections::META, Collections::META_SCHEMA_ID).should eq(SCHEMA_DOCUMENT)
          backend.destroy!
        end
      end

      it "round trips every document type exactly" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, sample_document)
          read = backend.read(COLLECTION, ID).as(Document)

          read.should eq(sample_document)
          read.keys.should eq(sample_document.keys)
          read["int_min"].should be_a(Int64)
          read["int_max"].should be_a(Int64)
          read["uint_max"].should be_a(UInt64)
          read["float_whole"].should be_a(Float64)
          read["numeric_string"].should be_a(String)
          read["float_string"].should be_a(String)
          read["bool_string"].should be_a(String)
          read["null_string"].should be_a(String)
          read["tilde_string"].should be_a(String)
          read["time_string"].should be_a(String)
          read["empty_bytes"].should be_a(Bytes)
          read["time"].should be_a(Time)
          read["time"].as(Time).nanosecond.should eq(SAMPLE_TIME.nanosecond)
          read["time"].as(Time).utc?.should be_true
          backend.destroy!
        end
      end

      it "stores NaN and non-UTC times" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, Document{"nan" => Float64::NAN, "local" => LOCAL_TIME})
          read = backend.read(COLLECTION, ID).as(Document)
          read["nan"].as(Float64).nan?.should be_true
          read["local"].should eq(LOCAL_TIME)
          read["local"].as(Time).nanosecond.should eq(LOCAL_TIME.nanosecond)
          backend.destroy!
        end
      end

      it "normalises small UInt64 values to Int64" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, Document{"small" => 5_u64, "big" => Int64::MAX.to_u64 + 1})
          read = backend.read(COLLECTION, ID).as(Document)
          read["small"].should be_a(Int64)
          read["big"].should be_a(UInt64)
          backend.destroy!
        end
      end

      it "returns nil for missing documents and collections" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.read(COLLECTION, ID).should be_nil
          backend.ids(COLLECTION).should be_empty
          backend.all(COLLECTION).should be_empty
          backend.destroy!
        end
      end

      it "isolates stored documents from caller mutations" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          original = Document{"list" => ([1_i64] of Type).as(Type), "bytes" => Bytes[1, 2], "nested" => Document{"a" => 1_i64}.as(Type)}
          backend.write(COLLECTION, ID, original)

          original["list"].as(Array(Type)) << 2_i64
          original["bytes"].as(Bytes)[0] = 9_u8
          original["nested"].as(Document)["b"] = 2_i64
          original["extra"] = true

          first = backend.read(COLLECTION, ID).as(Document)
          first.should eq(Document{"list" => ([1_i64] of Type).as(Type), "bytes" => Bytes[1, 2], "nested" => Document{"a" => 1_i64}.as(Type)})

          first["list"].as(Array(Type)) << 3_i64
          first["bytes"].as(Bytes)[1] = 9_u8
          first.delete("nested")

          backend.read(COLLECTION, ID).should eq(Document{"list" => ([1_i64] of Type).as(Type), "bytes" => Bytes[1, 2], "nested" => Document{"a" => 1_i64}.as(Type)})
          backend.all(COLLECTION)[ID]["list"].as(Array(Type)) << 4_i64
          backend.read(COLLECTION, ID).as(Document)["list"].should eq([1_i64] of Type)
          backend.destroy!
        end
      end

      it "overwrites documents" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, Document{"v" => 1_i64})
          backend.write(COLLECTION, ID, Document{"w" => 2_i64})
          backend.read(COLLECTION, ID).should eq(Document{"w" => 2_i64})
          backend.ids(COLLECTION).should eq([ID])
          backend.destroy!
        end
      end

      it "sorts ids and collections and hides empty collections" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, OTHER_ID, Document{"n" => 2_i64})
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          backend.write(COLLECTION, THIRD_ID, Document{"n" => 3_i64})
          backend.write(OTHER_COLLECTION, ID, Document.new)

          backend.ids(COLLECTION).should eq([ID, THIRD_ID, OTHER_ID])
          backend.all(COLLECTION).keys.should eq([ID, THIRD_ID, OTHER_ID])
          backend.all(COLLECTION)[THIRD_ID].should eq(Document{"n" => 3_i64})
          backend.collections.should eq([Collections::META, OTHER_COLLECTION, COLLECTION])

          backend.delete(OTHER_COLLECTION, ID)
          backend.collections.should eq([Collections::META, COLLECTION])
          backend.destroy!
        end
      end

      it "deletes documents and ignores missing ones" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          backend.delete(COLLECTION, ID)
          backend.read(COLLECTION, ID).should be_nil
          backend.delete(COLLECTION, ID)
          backend.delete(OTHER_COLLECTION, OTHER_ID)
          backend.ids(COLLECTION).should be_empty
          backend.destroy!
        end
      end

      it "clears a collection" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          backend.write(OTHER_COLLECTION, ID, Document{"n" => 1_i64})
          backend.clear(COLLECTION)
          backend.clear("never-existed")
          backend.ids(COLLECTION).should be_empty
          backend.ids(OTHER_COLLECTION).should eq([ID])
          backend.destroy!
        end
      end

      it "clears everything except the schema document" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          backend.write(OTHER_COLLECTION, ID, Document{"n" => 1_i64})
          backend.write(Collections::META, "other", Document{"n" => 1_i64})
          backend.clear_all
          backend.collections.should eq([Collections::META])
          backend.ids(Collections::META).should eq([Collections::META_SCHEMA_ID])
          backend.read(Collections::META, Collections::META_SCHEMA_ID).should eq(SCHEMA_DOCUMENT)
          backend.destroy!
        end
      end

      it "supports nested transactions" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.transaction do
            backend.write(COLLECTION, ID, Document{"n" => 1_i64})
            backend.transaction do
              backend.write(COLLECTION, OTHER_ID, Document{"n" => 2_i64})
              backend.read(COLLECTION, ID).should eq(Document{"n" => 1_i64})
            end
            backend.delete(COLLECTION, ID)
          end
          backend.ids(COLLECTION).should eq([OTHER_ID])
          backend.destroy!
        end
      end

      it "rejects invalid collection names and ids" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          INVALID_NAMES.each do |invalid|
            expect_raises(Matter::StorageError, /collection/) { backend.read(invalid, ID) }
            expect_raises(Matter::StorageError, /collection/) { backend.write(invalid, ID, Document.new) }
            expect_raises(Matter::StorageError, /collection/) { backend.delete(invalid, ID) }
            expect_raises(Matter::StorageError, /collection/) { backend.ids(invalid) }
            expect_raises(Matter::StorageError, /collection/) { backend.all(invalid) }
            expect_raises(Matter::StorageError, /collection/) { backend.clear(invalid) }
            expect_raises(Matter::StorageError, /id/) { backend.read(COLLECTION, invalid) }
            expect_raises(Matter::StorageError, /id/) { backend.write(COLLECTION, invalid, Document.new) }
            expect_raises(Matter::StorageError, /id/) { backend.delete(COLLECTION, invalid) }
          end
          backend.collections.should eq([Collections::META])
          backend.destroy!
        end
      end

      it "accepts the full permitted character set" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          name = "Az09_.:-"
          backend.write(name, name, Document.new)
          backend.ids(name).should eq([name])
          backend.destroy!
        end
      end

      it "refuses operations once closed" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.close
          backend.open?.should be_false
          expect_raises(Matter::StorageError, /not open/) { backend.read(COLLECTION, ID) }
          expect_raises(Matter::StorageError, /not open/) { backend.write(COLLECTION, ID, Document.new) }
          expect_raises(Matter::StorageError, /not open/) { backend.transaction { } }
          backend.destroy!
        end
      end

      it "destroys the store" do
        with_temp_path(extension) do |path|
          backend = factory.call(path)
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          backend.destroy!
          backend.open?.should be_false
          backend.path.try { |file| File.exists?(file).should be_false }
          backend.open
          backend.collections.should eq([Collections::META])
          backend.destroy!
        end
      end
    end
  end

  # Guarantees that only make sense when there is a file behind the store.
  # *factory* returns an unopened `FileBackend` that includes `FlushCounter`.
  def self.run_file(name : String, extension : String, &factory : String -> Matter::Storage::FileBackend) : Nil
    describe "#{name} file" do
      it "reports its path and creates the file on first write" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          backend.path.should eq(path)
          File.exists?(path).should be_false
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          File.exists?(path).should be_true
          File.exists?("#{path}#{Matter::Storage::FileBackend::TEMP_SUFFIX}").should be_false
          backend.destroy!
        end
      end

      it "persists across reopen" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          backend.write(COLLECTION, ID, sample_document)
          backend.write(OTHER_COLLECTION, OTHER_ID, Document{"n" => 2_i64})
          backend.close

          reopened = factory.call(path).tap(&.open)
          reopened.read(COLLECTION, ID).should eq(sample_document)
          reopened.read(COLLECTION, ID).as(Document)["uint_max"].should be_a(UInt64)
          reopened.read(COLLECTION, ID).as(Document)["time"].should eq(SAMPLE_TIME)
          reopened.collections.should eq([Collections::META, OTHER_COLLECTION, COLLECTION])
          reopened.read(Collections::META, Collections::META_SCHEMA_ID).should eq(SCHEMA_DOCUMENT)
          reopened.destroy!
        end
      end

      it "flushes once per outermost transaction" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          counter = backend.as(FlushCounter)
          counter.flushes.should eq(0)

          backend.transaction do
            backend.write(COLLECTION, ID, Document{"n" => 1_i64})
            backend.transaction do
              backend.write(COLLECTION, OTHER_ID, Document{"n" => 2_i64})
              backend.delete(COLLECTION, ID)
            end
            counter.flushes.should eq(0)
            File.exists?(path).should be_false
          end
          counter.flushes.should eq(1)

          backend.transaction { }
          counter.flushes.should eq(1)

          backend.write(COLLECTION, ID, Document{"n" => 3_i64})
          counter.flushes.should eq(2)
          backend.destroy!
        end
      end

      it "rolls back writes made before an exception inside a transaction" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          expect_raises(ArgumentError) do
            backend.transaction do
              backend.write(COLLECTION, ID, Document{"n" => 1_i64})
              raise ArgumentError.new("boom")
            end
          end
          backend.as(FlushCounter).flushes.should eq(0)
          backend.read(COLLECTION, ID).should be_nil
          backend.close

          reopened = factory.call(path).tap(&.open)
          reopened.read(COLLECTION, ID).should be_nil
          reopened.destroy!
        end
      end

      it "rolls back only a failed nested transaction" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          backend.transaction do
            backend.write(COLLECTION, ID, Document{"n" => 1_i64})
            expect_raises(ArgumentError) do
              backend.transaction do
                backend.write(COLLECTION, OTHER_ID, Document{"n" => 2_i64})
                raise ArgumentError.new("nested rollback")
              end
            end
            backend.read(COLLECTION, OTHER_ID).should be_nil
            backend.write(COLLECTION, THIRD_ID, Document{"n" => 3_i64})
          end
          backend.as(FlushCounter).flushes.should eq(1)
          backend.close

          reopened = factory.call(path).tap(&.open)
          reopened.ids(COLLECTION).should eq([ID, THIRD_ID])
          reopened.destroy!
        end
      end

      it "quarantines a corrupt file and starts empty" do
        with_temp_path(extension) do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, CORRUPT_CONTENT)

          backend = factory.call(path)
          ::Log.capture(Matter::Storage::Log.source, :error) do |logs|
            backend.open
            logs.check(:error, /corrupt/)
            logs.entry.exception.should_not be_nil
          end

          backend.collections.should eq([Collections::META])
          # Not `Dir.glob`: on Windows the backslashes in a temp path are glob escapes.
          prefix = "#{File.basename(path)}.corrupt-"
          quarantined = Dir.children(File.dirname(path)).select(&.starts_with?(prefix)).sort!
          quarantined.size.should eq(1)
          quarantined.first.should match(CORRUPT_PATTERN)
          File.read(File.join(File.dirname(path), quarantined.first)).should eq(CORRUPT_CONTENT)
          File.exists?(path).should be_false
          backend.destroy!
        end
      end

      it "treats an empty file as an empty store" do
        with_temp_path(extension) do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "")
          backend = factory.call(path).tap(&.open)
          backend.collections.should eq([Collections::META])
          backend.destroy!
        end
      end

      it "refuses a file written by a newer schema" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          backend.write(Collections::META, Collections::META_SCHEMA_ID, NEWER_SCHEMA)
          backend.close

          expect_raises(Matter::StorageError, /schema version/) { factory.call(path).open }
          File.exists?(path).should be_true
          Dir.glob("#{path}.corrupt-*").should be_empty
          FileUtils.rm_rf(File.dirname(path))
        end
      end

      it "keeps a loaded schema document on reopen" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          backend.close

          reopened = factory.call(path).tap(&.open)
          reopened.write(COLLECTION, OTHER_ID, Document{"n" => 2_i64})
          reopened.read(Collections::META, Collections::META_SCHEMA_ID).should eq(SCHEMA_DOCUMENT)
          reopened.destroy!
        end
      end

      it "removes the file on destroy!" do
        with_temp_path(extension) do |path|
          backend = factory.call(path).tap(&.open)
          backend.write(COLLECTION, ID, Document{"n" => 1_i64})
          backend.destroy!
          File.exists?(path).should be_false
          backend.open?.should be_false
          backend.destroy!
        end
      end
    end
  end
end

describe Matter::Storage::Backend do
  BackendContract.run("Memory", ".mem") { Matter::Storage::Memory.new }
  BackendContract.run("YamlFile", ".yml") { |path| Matter::Storage::YamlFile.new(path).tap(&.open) }
  BackendContract.run("JsonFile", ".json") { |path| Matter::Storage::JsonFile.new(path).tap(&.open) }
  BackendContract.run("Sqlite", ".sqlite3") { |path| Matter::Storage::Sqlite.new(path).tap(&.open) }

  BackendContract.run_file("YamlFile", ".yml") { |path| BackendContract::CountingYamlFile.new(path) }
  BackendContract.run_file("JsonFile", ".json") { |path| BackendContract::CountingJsonFile.new(path) }

  it "retains the previous file and in-memory tree when a transaction flush fails before rename" do
    BackendContract.with_temp_path(".yml") do |path|
      backend = BackendContract::FailingYamlFile.new(path).tap(&.open)
      old_document = Matter::Storage::Document{"n" => 1_i64}
      backend.write(BackendContract::COLLECTION, BackendContract::ID, old_document)
      backend.fail_next_flush = true
      expect_raises(Matter::StorageError, "Interrupted before file rename") do
        backend.transaction do
          backend.write(BackendContract::COLLECTION, BackendContract::ID,
            Matter::Storage::Document{"n" => 2_i64})
        end
      end
      backend.read(BackendContract::COLLECTION, BackendContract::ID).should eq(old_document)
      backend.close

      reopened = Matter::Storage::YamlFile.new(path).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(old_document)
      reopened.destroy!
    end
  end
end

describe Matter::Storage::Sqlite do
  it "keeps a relative database path anchored when the working directory changes" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      directory = File.dirname(path)
      original_directory = File.join(directory, "original")
      other_directory = File.join(directory, "other")
      FileUtils.mkdir_p(original_directory)
      FileUtils.mkdir_p(other_directory)

      filename = File.basename(path)
      original_path = File.join(original_directory, filename)
      other_path = File.join(other_directory, filename)
      File.write(other_path, "unrelated database")
      backend = Dir.cd(original_directory) { Matter::Storage::Sqlite.new(filename) }

      Dir.cd(other_directory) do
        backend.open
        backend.write(BackendContract::COLLECTION, BackendContract::ID,
          Matter::Storage::Document{"n" => 1_i64})
        File.exists?(original_path).should be_true
        backend.destroy!
      end

      File.exists?(original_path).should be_false
      File.exists?("#{original_path}-wal").should be_false
      File.exists?("#{original_path}-shm").should be_false
      File.read(other_path).should eq("unrelated database")
    end
  end

  it "preserves maps whose keys resemble file JSON value wrappers" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      wrappers = Matter::Storage::Document{
        "$bytes" => "AQID",
        "$time"  => "2026-09-10T01:02:03Z",
        "$float" => "Infinity",
        "nested" => Matter::Storage::Document{"$bytes" => "AQID"}.as(Matter::Storage::Type),
      }
      backend.write(BackendContract::COLLECTION, BackendContract::ID, wrappers)
      singleton = Matter::Storage::Document{"$bytes" => "AQID"}
      backend.write(BackendContract::COLLECTION, BackendContract::OTHER_ID, singleton)
      backend.close

      reopened = Matter::Storage::Sqlite.new(path).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(wrappers)
      reopened.read(BackendContract::COLLECTION, BackendContract::OTHER_ID).should eq(singleton)
      reopened.destroy!
    end
  end

  it "preserves data and document types after close and reopen" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      backend.write(BackendContract::COLLECTION, BackendContract::ID, BackendContract.sample_document)
      backend.close

      reopened = Matter::Storage::Sqlite.new(path).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(BackendContract.sample_document)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).as(Matter::Storage::Document)["uint_max"].should be_a(UInt64)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).as(Matter::Storage::Document)["time"].as(Time).nanosecond.should eq(BackendContract::SAMPLE_TIME.nanosecond)
      reopened.destroy!
    end
  end

  it "commits the outer transaction and rolls back an exception atomically" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      backend.write(BackendContract::COLLECTION, BackendContract::ID, Matter::Storage::Document{"n" => 1_i64})
      expect_raises(ArgumentError) do
        backend.transaction do
          backend.write(BackendContract::COLLECTION, BackendContract::ID, Matter::Storage::Document{"n" => 2_i64})
          backend.transaction { backend.write(BackendContract::COLLECTION, BackendContract::OTHER_ID, Matter::Storage::Document{"n" => 3_i64}) }
          raise ArgumentError.new("rollback")
        end
      end
      backend.close

      reopened = Matter::Storage::Sqlite.new(path).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(Matter::Storage::Document{"n" => 1_i64})
      reopened.read(BackendContract::COLLECTION, BackendContract::OTHER_ID).should be_nil
      reopened.destroy!
    end
  end

  it "rolls back only a failed nested transaction" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      backend.transaction do
        backend.write(BackendContract::COLLECTION, BackendContract::ID, Matter::Storage::Document{"n" => 1_i64})
        expect_raises(ArgumentError) do
          backend.transaction do
            backend.write(BackendContract::COLLECTION, BackendContract::OTHER_ID, Matter::Storage::Document{"n" => 2_i64})
            raise ArgumentError.new("nested rollback")
          end
        end
        backend.write(BackendContract::COLLECTION, BackendContract::THIRD_ID, Matter::Storage::Document{"n" => 3_i64})
      end
      backend.ids(BackendContract::COLLECTION).should eq([BackendContract::ID, BackendContract::THIRD_ID])
      backend.destroy!
    end
  end

  it "keeps an existing document when a failed write is caught inside a transaction" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      original = Matter::Storage::Document{"n" => 1_i64}
      backend.write(BackendContract::COLLECTION, BackendContract::ID, original)
      backend.close

      DB.open("sqlite3://#{URI.encode_path(path)}") do |database|
        database.exec(<<-SQL)
          CREATE TRIGGER fail_storage_insert BEFORE INSERT ON matter_storage_documents
          WHEN NEW.collection = '#{BackendContract::COLLECTION}' AND NEW.id = '#{BackendContract::ID}'
          BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
          SQL
      end

      reopened = Matter::Storage::Sqlite.new(path).tap(&.open)
      reopened.transaction do
        expect_raises(Matter::StorageError, /SQL storage operation failed/) do
          reopened.write(BackendContract::COLLECTION, BackendContract::ID,
            Matter::Storage::Document{"n" => 2_i64})
        end
      end
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(original)
      reopened.destroy!
    end
  end

  it "refuses a newer document schema without changing the database" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      backend.write(Matter::Storage::Collections::META, Matter::Storage::Collections::META_SCHEMA_ID, BackendContract::NEWER_SCHEMA)
      backend.close

      expect_raises(Matter::StorageError, /schema version/) { Matter::Storage::Sqlite.new(path).open }
      File.exists?(path).should be_true
      backend.destroy!
    end
  end

  it "refuses a newer physical SQL schema without changing its version" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      backend.close
      DB.open("sqlite3://#{URI.encode_path(path)}") do |database|
        database.exec("UPDATE matter_storage_schema SET version = ?", Matter::Storage::SqlSchema::VERSION + 1)
      end

      expect_raises(Matter::StorageError, /SQL storage schema version/) { Matter::Storage::Sqlite.new(path).open }
      DB.open("sqlite3://#{URI.encode_path(path)}") do |database|
        database.scalar("SELECT version FROM matter_storage_schema").should eq(Matter::Storage::SqlSchema::VERSION + 1)
      end
      backend.destroy!
    end
  end

  it "applies the first physical SQL migration to a version-zero store" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      backend.close
      DB.open("sqlite3://#{URI.encode_path(path)}") do |database|
        database.exec("DROP TABLE matter_storage_documents")
        database.exec("UPDATE matter_storage_schema SET version = ?", 0_i64)
      end

      reopened = Matter::Storage::Sqlite.new(path).tap(&.open)
      reopened.read(Matter::Storage::Collections::META, Matter::Storage::Collections::META_SCHEMA_ID)
        .should eq(BackendContract::SCHEMA_DOCUMENT)
      reopened.destroy!
    end
  end

  it "lets independent backends open the same new database" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      ready = Channel(Nil).new
      start = Channel(Nil).new
      done = Channel(Exception?).new
      8.times do
        spawn do
          ready.send(nil)
          start.receive
          backend = Matter::Storage::Sqlite.new(path).tap(&.open)
          backend.read(Matter::Storage::Collections::META, Matter::Storage::Collections::META_SCHEMA_ID)
            .should eq(BackendContract::SCHEMA_DOCUMENT)
          backend.close
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end
      8.times { ready.receive }
      8.times { start.send(nil) }
      8.times { done.receive.should be_nil }

      Matter::Storage::Sqlite.new(path).tap(&.open).destroy!
    end
  end

  it "serializes concurrent writes from fibers" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      done = Channel(Exception?).new
      8.times do |worker|
        spawn do
          20.times do |item|
            backend.write(BackendContract::COLLECTION, "#{worker}:#{item}", Matter::Storage::Document{"worker" => worker.to_i64})
          end
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end
      8.times { done.receive.should be_nil }
      backend.ids(BackendContract::COLLECTION).size.should eq(160)
      backend.destroy!
    end
  end

  it "serializes read-modify-write transactions across fibers" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      backend = Matter::Storage::Sqlite.new(path).tap(&.open)
      backend.write(BackendContract::COLLECTION, BackendContract::ID, Matter::Storage::Document{"count" => 0_i64})
      done = Channel(Exception?).new
      8.times do
        spawn do
          20.times do
            backend.transaction do
              current = backend.read(BackendContract::COLLECTION, BackendContract::ID).as(Matter::Storage::Document)
              count = current["count"].as(Int64)
              Fiber.yield
              backend.write(BackendContract::COLLECTION, BackendContract::ID,
                Matter::Storage::Document{"count" => count + 1})
            end
          end
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end
      8.times { done.receive.should be_nil }
      backend.read(BackendContract::COLLECTION, BackendContract::ID).should eq(Matter::Storage::Document{"count" => 160_i64})
      backend.destroy!
    end
  end

  it "registers an opt-in sqlite migrator scheme" do
    BackendContract.with_temp_path(".sqlite3") do |path|
      source = Matter::Storage::Memory.new
      source.write(BackendContract::COLLECTION, BackendContract::ID, BackendContract.sample_document)
      target = Matter::Storage::Migrator.open("sqlite:#{path}")
      Matter::Storage::Migrator.copy(source, target).should eq({BackendContract::COLLECTION => 1})
      target.close

      reopened = Matter::Storage::Sqlite.new(path).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(BackendContract.sample_document)
      reopened.destroy!
    end
  end
end
