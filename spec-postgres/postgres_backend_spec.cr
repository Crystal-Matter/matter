require "uri"
require "../spec/storage/backend_contract_spec"
require "../src/matter/storage/postgres"

# This suite is intentionally outside spec/: ordinary `crystal spec` never
# loads the optional PostgreSQL driver or needs a running database. CI and
# applications opt in with MATTER_TEST_POSTGRES_URL and run this file directly.
private def fresh_postgres(url : String) : Matter::Storage::Postgres
  backend = Matter::Storage::Postgres.new(url)
  backend.destroy!
  backend.open
  backend
end

if url = ENV["MATTER_TEST_POSTGRES_URL"]?
  raise "PostgreSQL integration tests require a dedicated *_test database" unless URI.parse(url).path.ends_with?("_test")

  BackendContract.run("Postgres", ".postgres") { |_path| fresh_postgres(url) }

  describe Matter::Storage::Postgres do
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
