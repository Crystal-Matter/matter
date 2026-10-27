require "uri"
require "../spec/storage/backend_contract_spec"
require "../src/matter/storage/postgres"
require "../src/matter/controller/state_store"

# This suite is intentionally outside spec/: ordinary `crystal spec` never
# loads the optional PostgreSQL driver or needs a running database. CI and
# applications opt in with MATTER_TEST_POSTGRES_URL and run this file directly.
private def fresh_postgres(url : String) : Matter::Storage::Postgres
  backend = Matter::Storage::Postgres.new(url)
  backend.destroy!
  backend.open
  backend
end

private class PausedControllerPostgres < Matter::Storage::Postgres
  def initialize(url : String, @ready : Channel(Nil), @release : Channel(Nil))
    super(url)
  end

  def compare_and_swap(collection : String, id : String,
                       expected : Matter::Storage::Document?,
                       document : Matter::Storage::Document) : Bool
    @ready.send(nil)
    @release.receive
    super
  end
end

private class PausedControllerLoadPostgres < Matter::Storage::Postgres
  @pause_once = true

  def initialize(url : String, @ready : Channel(Nil), @release : Channel(Nil))
    super(url)
  end

  def compare_and_swap(collection : String, id : String,
                       expected : Matter::Storage::Document?, document : Matter::Storage::Document) : Bool
    if @pause_once && collection == Matter::Controller::StateStore::COLLECTION &&
       id == Matter::Controller::StateStore::DOCUMENT_ID
      @pause_once = false
      @ready.send(nil)
      @release.receive
    end
    super
  end
end

if url = ENV["MATTER_TEST_POSTGRES_URL"]?
  raise "PostgreSQL integration tests require a dedicated *_test database" unless URI.parse(url).path.ends_with?("_test")

  BackendContract.run("Postgres", ".postgres") { |_path| fresh_postgres(url) }

  describe Matter::Storage::Postgres do
    it "retries clean and normalized loads without purging newly owned CASE credentials" do
      [false, true].each do |needs_normalization|
        seed = fresh_postgres(url)
        initial_id = needs_normalization ? Matter::DataType::NodeId::UNSPECIFIED : 0x7777_u64
        Matter::Controller::StateStore.new(seed).save(
          Matter::Controller::State.new(commissioner_node_id: initial_id))
        seed.close

        ready = Channel(Nil).new
        release = Channel(Nil).new
        paused_backend = PausedControllerLoadPostgres.new(url, ready, release).tap(&.open)
        paused_store = Matter::Controller::StateStore.new(paused_backend)
        result = Channel(Matter::Controller::State | Exception).new
        spawn do
          result.send(paused_store.load)
        rescue ex
          result.send(ex)
        end
        ready.receive

        fabric = Matter::Controller::FabricInfo.new(
          fabric_id: 0x1111_u64, controller_node_id: 0x2222_u64,
          ipk_value: Bytes.new(16, 0xAA_u8), root_cert: Bytes.empty,
          root_public_key: Bytes.new(65, 0xBB_u8), controller_noc: Bytes.empty,
          controller_private_key: Bytes.empty)
        writer = Matter::Storage::Postgres.new(url).tap(&.open)
        Matter::Controller::StateStore.new(writer).save(Matter::Controller::State.new(fabric: fabric))
        credential_id = Bytes.new(16, 0x11_u8)
        Matter::Session::Case::ResumptionStore.new(writer).save(
          Matter::Session::Case::ResumptionStore::Record.new(fabric.fabric_id,
            fabric.root_public_key, fabric.controller_node_id, 0x3333_u64,
            credential_id, Bytes.new(32, 0x22_u8), [0x3333_u64],
            role: Matter::Session::Case::Role::Initiator))
        release.send(nil)

        result.receive.as(Matter::Controller::State).fabric.as(Matter::Controller::FabricInfo).fabric_id.should eq(fabric.fabric_id)
        Matter::Session::Case::ResumptionStore.new(writer).find_by_id(credential_id).should_not be_nil
        paused_backend.close
        writer.destroy!
      end
    end

    it "rejects one of two independent controller writes that read the same SQL row" do
      seed = fresh_postgres(url)
      seed_store = Matter::Controller::StateStore.new(seed)
      seed_store.save(Matter::Controller::State.new)
      seed.close
      ready = Channel(Nil).new
      release = Channel(Nil).new
      first_backend = PausedControllerPostgres.new(url, ready, release).tap(&.open)
      second_backend = PausedControllerPostgres.new(url, ready, release).tap(&.open)
      first_store = Matter::Controller::StateStore.new(first_backend)
      second_store = Matter::Controller::StateStore.new(second_backend)
      first = first_store.load
      second = second_store.load
      first.unsecured_message_counter = 1_u32
      second.unsecured_message_counter = 2_u32
      finished = Channel(Exception?).new
      spawn do
        first_store.save(first)
        finished.send(nil)
      rescue ex
        finished.send(ex)
      end
      spawn do
        second_store.save(second)
        finished.send(nil)
      rescue ex
        finished.send(ex)
      end
      2.times { ready.receive }
      2.times { release.send(nil) }
      results = 2.times.map { finished.receive }
      results.count(&.nil?).should eq(1)
      unless results.count { |result| result.is_a?(Matter::StorageError) && result.message.to_s.includes?("changed since load") } == 1
        raise "Unexpected competing-writer results: #{results.map { |result| result.try { |error| {error.class.name, error.message} } }}"
      end
      results.count { |result| result.is_a?(Matter::StorageError) && result.message.to_s.includes?("changed since load") }.should eq(1)
      first_backend.close
      second_backend.close
      persisted = Matter::Controller::StateStore.new(Matter::Storage::Postgres.new(url))
      persisted.load.unsecured_message_counter.in?(1_u32, 2_u32).should be_true
      persisted.backend.destroy!
    end

    it "allows only one independent controller insert when both saw no row" do
      Matter::Storage::Postgres.new(url).destroy!
      ready = Channel(Nil).new
      release = Channel(Nil).new
      first_backend = PausedControllerPostgres.new(url, ready, release).tap(&.open)
      second_backend = PausedControllerPostgres.new(url, ready, release).tap(&.open)
      first_store = Matter::Controller::StateStore.new(first_backend)
      second_store = Matter::Controller::StateStore.new(second_backend)
      first = first_store.load
      second = second_store.load
      first.unsecured_message_counter = 1_u32
      second.unsecured_message_counter = 2_u32
      finished = Channel(Exception?).new
      spawn do
        first_store.save(first)
        finished.send(nil)
      rescue ex
        finished.send(ex)
      end
      spawn do
        second_store.save(second)
        finished.send(nil)
      rescue ex
        finished.send(ex)
      end
      2.times { ready.receive }
      2.times { release.send(nil) }
      results = 2.times.map { finished.receive }
      results.count(&.nil?).should eq(1)
      unless results.count { |result| result.is_a?(Matter::StorageError) && result.message.to_s.includes?("changed since load") } == 1
        raise "Unexpected competing-insert results: #{results.map { |result| result.try { |error| {error.class.name, error.message} } }}"
      end
      results.count { |result| result.is_a?(Matter::StorageError) && result.message.to_s.includes?("changed since load") }.should eq(1)
      first_backend.close
      second_backend.close
      Matter::Storage::Postgres.new(url).destroy!
    end

    it "rejects a non-PostgreSQL connection URL" do
      expect_raises(Matter::StorageError, /postgres/) { Matter::Storage::Postgres.new("") }
      expect_raises(Matter::StorageError, /postgres/) { Matter::Storage::Postgres.new("sqlite3:///tmp/matter.db") }
    end

    it "preserves wrapper-like user keys and every encoded document type across restart" do
      backend = fresh_postgres(url)
      wrappers = Matter::Storage::Document{
        "$bytes" => "AQID",
        "$time"  => "2026-09-10T01:02:03Z",
        "$float" => "Infinity",
        "nested" => Matter::Storage::Document{"$bytes" => "AQID"}.as(Matter::Storage::Type),
      }
      backend.write(BackendContract::COLLECTION, BackendContract::ID, BackendContract.sample_document)
      backend.write(BackendContract::COLLECTION, BackendContract::OTHER_ID, wrappers)
      backend.close

      reopened = Matter::Storage::Postgres.new(url).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(BackendContract.sample_document)
      reopened.read(BackendContract::COLLECTION, BackendContract::OTHER_ID).should eq(wrappers)
      reopened.destroy!
    end

    it "commits an outer transaction and rolls back an exception atomically" do
      backend = fresh_postgres(url)
      original = Matter::Storage::Document{"n" => 1_i64}
      backend.write(BackendContract::COLLECTION, BackendContract::ID, original)
      expect_raises(ArgumentError) do
        backend.transaction do
          backend.write(BackendContract::COLLECTION, BackendContract::ID, Matter::Storage::Document{"n" => 2_i64})
          backend.transaction do
            backend.write(BackendContract::COLLECTION, BackendContract::OTHER_ID, Matter::Storage::Document{"n" => 3_i64})
          end
          raise ArgumentError.new("rollback")
        end
      end
      backend.close

      reopened = Matter::Storage::Postgres.new(url).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(original)
      reopened.read(BackendContract::COLLECTION, BackendContract::OTHER_ID).should be_nil
      reopened.destroy!
    end

    it "rolls back only a failed nested savepoint" do
      backend = fresh_postgres(url)
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

    it "keeps an outer transaction usable after a caught SQL write error" do
      backend = fresh_postgres(url)
      original = Matter::Storage::Document{"n" => 1_i64}
      backend.write(BackendContract::COLLECTION, BackendContract::ID, original)
      DB.open(url) do |database|
        database.exec(<<-SQL)
          CREATE OR REPLACE FUNCTION matter_test_reject_update() RETURNS trigger AS $$
          BEGIN
            IF NEW.collection = 'things' AND NEW.id = 'one' THEN
              RAISE EXCEPTION 'injected storage update failure';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql
          SQL
        database.exec("CREATE TRIGGER matter_test_reject_update BEFORE UPDATE ON matter_storage_documents FOR EACH ROW EXECUTE FUNCTION matter_test_reject_update()")
      end

      backend.transaction do
        expect_raises(Matter::StorageError, /SQL storage operation failed/) do
          backend.write(BackendContract::COLLECTION, BackendContract::ID,
            Matter::Storage::Document{"n" => 2_i64})
        end
        backend.write(BackendContract::COLLECTION, BackendContract::OTHER_ID,
          Matter::Storage::Document{"n" => 3_i64})
      end
      backend.read(BackendContract::COLLECTION, BackendContract::ID).should eq(original)
      backend.read(BackendContract::COLLECTION, BackendContract::OTHER_ID).should eq(Matter::Storage::Document{"n" => 3_i64})
      backend.destroy!
      DB.open(url) { |database| database.exec("DROP FUNCTION matter_test_reject_update()") }
    end

    it "keeps an outer transaction usable after caught delete and clear errors" do
      backend = fresh_postgres(url)
      backend.write(BackendContract::COLLECTION, BackendContract::ID, Matter::Storage::Document{"n" => 1_i64})
      DB.open(url) do |database|
        database.exec(<<-SQL)
          CREATE OR REPLACE FUNCTION matter_test_reject_delete() RETURNS trigger AS $$
          BEGIN
            IF OLD.collection = 'things' AND OLD.id = 'one' THEN
              RAISE EXCEPTION 'injected storage delete failure';
            END IF;
            RETURN OLD;
          END;
          $$ LANGUAGE plpgsql
          SQL
        database.exec("CREATE TRIGGER matter_test_reject_delete BEFORE DELETE ON matter_storage_documents FOR EACH ROW EXECUTE FUNCTION matter_test_reject_delete()")
      end

      backend.transaction do
        expect_raises(Matter::StorageError, /SQL storage operation failed/) do
          backend.delete(BackendContract::COLLECTION, BackendContract::ID)
        end
        expect_raises(Matter::StorageError, /SQL storage operation failed/) do
          backend.clear(BackendContract::COLLECTION)
        end
        backend.write(BackendContract::COLLECTION, BackendContract::OTHER_ID,
          Matter::Storage::Document{"n" => 2_i64})
      end
      backend.ids(BackendContract::COLLECTION).should eq([BackendContract::ID, BackendContract::OTHER_ID])
      backend.destroy!
      DB.open(url) { |database| database.exec("DROP FUNCTION matter_test_reject_delete()") }
    end

    it "rejects a newer physical SQL schema without modifying it" do
      backend = fresh_postgres(url)
      backend.close
      DB.open(url) do |database|
        database.exec("UPDATE matter_storage_schema SET version = $1", Matter::Storage::SqlSchema::VERSION + 1)
      end
      expect_raises(Matter::StorageError, /SQL storage schema version/) { Matter::Storage::Postgres.new(url).open }
      DB.open(url) do |database|
        database.scalar("SELECT version FROM matter_storage_schema").should eq(Matter::Storage::SqlSchema::VERSION + 1)
      end
      backend.destroy!
    end

    it "refuses a newer document schema without changing stored data" do
      backend = fresh_postgres(url)
      backend.write(Matter::Storage::Collections::META, Matter::Storage::Collections::META_SCHEMA_ID,
        BackendContract::NEWER_SCHEMA)
      backend.close
      expect_raises(Matter::StorageError, /schema version/) { Matter::Storage::Postgres.new(url).open }
      DB.open(url) do |database|
        database.query_one("SELECT payload FROM matter_storage_documents WHERE collection = $1 AND id = $2",
          Matter::Storage::Collections::META, Matter::Storage::Collections::META_SCHEMA_ID, as: String)
          .should eq(Matter::Storage::SqlDocumentCodec.encode(BackendContract::NEWER_SCHEMA))
      end
      backend.destroy!
    end

    it "applies the shared first SQL migration to a version-zero database" do
      backend = fresh_postgres(url)
      backend.close
      DB.open(url) do |database|
        database.exec("DROP TABLE matter_storage_documents")
        database.exec("UPDATE matter_storage_schema SET version = $1", 0_i64)
      end
      reopened = Matter::Storage::Postgres.new(url).tap(&.open)
      reopened.read(Matter::Storage::Collections::META, Matter::Storage::Collections::META_SCHEMA_ID)
        .should eq(BackendContract::SCHEMA_DOCUMENT)
      reopened.destroy!
    end

    it "allows independent adapters to open the same fresh database" do
      Matter::Storage::Postgres.new(url).destroy!
      done = Channel(Exception?).new
      8.times do
        spawn do
          backend = Matter::Storage::Postgres.new(url).tap(&.open)
          backend.read(Matter::Storage::Collections::META, Matter::Storage::Collections::META_SCHEMA_ID)
            .should eq(BackendContract::SCHEMA_DOCUMENT)
          backend.close
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end
      8.times { done.receive.should be_nil }
      Matter::Storage::Postgres.new(url).destroy!
    end

    it "registers a PostgreSQL migrator scheme" do
      source = Matter::Storage::Memory.new
      source.write(BackendContract::COLLECTION, BackendContract::ID, BackendContract.sample_document)
      backend = fresh_postgres(url)
      backend.close
      target = Matter::Storage::Migrator.open(url)
      Matter::Storage::Migrator.copy(source, target).should eq({BackendContract::COLLECTION => 1})
      target.close
      reopened = Matter::Storage::Postgres.new(url).tap(&.open)
      reopened.read(BackendContract::COLLECTION, BackendContract::ID).should eq(BackendContract.sample_document)
      reopened.destroy!
    end

    it "drops only Matter-owned tables on destroy" do
      DB.open(url) do |database|
        database.exec("CREATE TABLE IF NOT EXISTS application_data (id BIGINT PRIMARY KEY)")
        database.exec("INSERT INTO application_data (id) VALUES (1) ON CONFLICT (id) DO NOTHING")
      end
      backend = fresh_postgres(url)
      backend.write(BackendContract::COLLECTION, BackendContract::ID, Matter::Storage::Document{"n" => 1_i64})
      backend.destroy!
      DB.open(url) do |database|
        database.query_one("SELECT COUNT(*) FROM application_data", as: Int64).should eq(1_i64)
        database.query_one("SELECT COUNT(*) FROM pg_catalog.pg_tables WHERE schemaname = current_schema() AND tablename = 'matter_storage_documents'", as: Int64).should eq(0_i64)
        database.exec("DROP TABLE application_data")
      end
    end
  end
end
