require "../spec_helper"
require "../../src/matter/device/persistence"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/wi_fi_network_management"

private alias ManagedWifi = Matter::Cluster::WiFiNetworkManagement

# Counts file flushes so a spec can pin "one write for many mutations".
private class CountingYamlFile < Matter::Storage::YamlFile
  getter flushes = 0

  protected def flush : Nil
    @flushes += 1
    super
  end
end

private class PausingClusterMemory < Matter::Storage::Memory
  property? pause_next_cluster_write = false
  getter write_started = Channel(Nil).new(1)
  getter write_resume = Channel(Nil).new(1)

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::CLUSTERS && pause_next_cluster_write?
      @pause_next_cluster_write = false
      @write_started.send(nil)
      @write_resume.receive
    end
    super
  end
end

private class PausingTransactionMemory < Matter::Storage::Memory
  property? pause_next_transaction = false
  property? transaction_completed = false
  getter transaction_started = Channel(Nil).new(1)
  getter transaction_resume = Channel(Nil).new(1)

  def transaction(& : -> Nil) : Nil
    super do
      if pause_next_transaction?
        @pause_next_transaction = false
        @transaction_started.send(nil)
        @transaction_resume.receive
      end
      yield
    end
    @transaction_completed = true
  end
end

private CLUSTERS = Matter::Storage::Collections::CLUSTERS
private DEVICE   = Matter::Storage::Collections::DEVICE
private APP      = Matter::Storage::Collections::APP

# Long enough for the debounce fiber to have fired.
private DEBOUNCE_WAIT = Matter::Device::Persistence::SAVE_DEBOUNCE + 100.milliseconds

private def with_temp_file(& : String ->) : Nil
  path = File.join(Dir.tempdir, "matter-persistence-#{Random::Secure.hex(6)}.yml")
  yield path
ensure
  File.delete?(path) if path
end

private def on_off_cluster(endpoint : UInt16 = 1_u16) : Matter::Cluster::OnOff
  build(Matter::Cluster::OnOff, endpoint)
end

private def build_fabric(fabric_index : UInt8) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: fabric_index.to_u64,
    fabric_index: fabric_index,
    node_id: 0x1_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16),
    last_used_at: Time.utc(2020, 1, 1)
  )
end

describe Matter::Device::Persistence do
  describe "clusters" do
    it "orders a snapshotted Access Control write before fabric removal and replacement" do
      storage = PausingClusterMemory.new
      persistence = Matter::Device::Persistence.new(storage)
      acl = Matter::Cluster::AccessControl.new(endpoint(0), Matter::Cluster::AccessControl::Feature::ManagedDevice)
      original = Matter::Cluster::AccessControl::AccessRestrictionEntry.new(1_u16, ManagedWifi::CLUSTER_ID, [
        Matter::Cluster::AccessControl::AccessRestriction.new(
          Matter::Cluster::AccessControl::AccessRestrictionType::AttributeAccessForbidden, ManagedWifi::ATTR_SSID),
      ])
      replacement = Matter::Cluster::AccessControl::AccessRestrictionEntry.new(1_u16, ManagedWifi::CLUSTER_ID, [
        Matter::Cluster::AccessControl::AccessRestriction.new(
          Matter::Cluster::AccessControl::AccessRestrictionType::AttributeWriteForbidden, ManagedWifi::ATTR_SSID),
      ])
      acl.configure_access_restrictions(1_u8, [original])
      storage.pause_next_cluster_write = true
      old_saved = Channel(Bool).new(1)
      spawn { old_saved.send(persistence.save_cluster(acl)) }
      storage.write_started.receive
      replacement_saved = Channel(Bool).new(1)
      spawn do
        acl.remove_fabric_acl(1_u8)
        acl.configure_access_restrictions(1_u8, [replacement])
        replacement_saved.send(persistence.save_cluster(acl))
      end
      Fiber.yield
      storage.write_resume.send(nil)
      old_saved.receive.should be_true
      replacement_saved.receive.should be_true
      restored = Matter::Cluster::AccessControl.new(endpoint(0), Matter::Cluster::AccessControl::Feature::ManagedDevice)
      restored.restore_state(storage.read(CLUSTERS, acl.persistence_key).as(Matter::Storage::Document))
      restored.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
    end

    it "allows legacy fabrics without a saved Access Control document" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      acl = Matter::Cluster::AccessControl.new(endpoint(0))
      persistence.restore_clusters([acl] of Matter::Cluster::Base).should eq(0)
      persistence.fabric_table.add_fabric(build_fabric(1_u8))
      persistence.close
      restarted = Matter::Device::Persistence.new(storage)
      restarted.restore_clusters([Matter::Cluster::AccessControl.new(endpoint(0))] of Matter::Cluster::Base).should eq(0)
      restarted.close
    end

    it "requires a saved Access Control document after a host ARL policy was persisted" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      persistence.fabric_table.add_fabric(build_fabric(1_u8))
      acl = Matter::Cluster::AccessControl.new(endpoint(0))
      acl.configure_access_restrictions(1_u8, [
        Matter::Cluster::AccessControl::AccessRestrictionEntry.new(1_u16, ManagedWifi::CLUSTER_ID, [
          Matter::Cluster::AccessControl::AccessRestriction.new(
            Matter::Cluster::AccessControl::AccessRestrictionType::AttributeAccessForbidden, ManagedWifi::ATTR_SSID),
        ]),
      ])
      persistence.save_cluster(acl).should be_true
      storage.delete(CLUSTERS, acl.persistence_key)
      persistence.close
      restarted = Matter::Device::Persistence.new(storage)
      expect_raises(Matter::AccessControlRestoreError) do
        restarted.restore_clusters([Matter::Cluster::AccessControl.new(endpoint(0))] of Matter::Cluster::Base)
      end
      restarted.close
    end

    it "requires Access Control state for an advertised managed device with fabrics" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      managed = Matter::Cluster::AccessControl.new(endpoint(0), Matter::Cluster::AccessControl::Feature::ManagedDevice)
      persistence.restore_clusters([managed] of Matter::Cluster::Base).should eq(0)
      persistence.fabric_table.add_fabric(build_fabric(1_u8))
      persistence.close
      restarted = Matter::Device::Persistence.new(storage)
      expect_raises(Matter::AccessControlRestoreError) do
        restarted.restore_clusters([managed] of Matter::Cluster::Base)
      end
      restarted.close
    end

    it "requires a saved commissioning ARL even before the first fabric joins" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      acl = Matter::Cluster::AccessControl.new(endpoint(0))
      acl.configure_commissioning_access_restrictions([
        Matter::Cluster::AccessControl::CommissioningAccessRestrictionEntry.new(
          1_u16, ManagedWifi::CLUSTER_ID, [
          Matter::Cluster::AccessControl::AccessRestriction.new(
            Matter::Cluster::AccessControl::AccessRestrictionType::AttributeAccessForbidden,
            ManagedWifi::ATTR_SSID),
        ]),
      ])
      persistence.save_cluster(acl).should be_true
      storage.delete(CLUSTERS, acl.persistence_key)
      persistence.close
      restarted = Matter::Device::Persistence.new(storage)
      expect_raises(Matter::AccessControlRestoreError) do
        restarted.restore_clusters([Matter::Cluster::AccessControl.new(endpoint(0))] of Matter::Cluster::Base)
      end
      restarted.close
    end
    it "saves a dirty cluster after the debounce without a shutdown" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      cluster = on_off_cluster
      persistence.track(cluster)

      cluster.on = true
      storage.read(CLUSTERS, cluster.persistence_key).should be_nil

      sleep DEBOUNCE_WAIT
      document = storage.read(CLUSTERS, cluster.persistence_key).as(Matter::Storage::Document)
      document["on_off"].should be_true
      document["data_version"].should eq(cluster.data_version.to_i64)
    end

    it "writes many mutations with one flush" do
      with_temp_file do |path|
        storage = CountingYamlFile.new(path)
        persistence = Matter::Device::Persistence.new(storage)
        cluster = on_off_cluster
        persistence.track(cluster)
        baseline = storage.flushes

        10.times { cluster.toggle }
        storage.flushes.should eq(baseline)

        sleep DEBOUNCE_WAIT
        storage.flushes.should eq(baseline + 1)
        storage.read(CLUSTERS, cluster.persistence_key).as(Matter::Storage::Document)["data_version"].should eq(cluster.data_version.to_i64)
        persistence.close
      end
    end

    it "flushes synchronously" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      cluster = on_off_cluster
      persistence.track(cluster)

      cluster.on = true
      persistence.flush
      storage.read(CLUSTERS, cluster.persistence_key).as(Matter::Storage::Document)["on_off"].should be_true
    end

    it "holds the protocol lock before a deferred fabric flush enters storage" do
      storage = PausingTransactionMemory.new
      persistence = Matter::Device::Persistence.new(storage)
      persistence.fabric_table.add_fabric(build_fabric(1_u8))
      persistence.fabric_table.protocol_lock = Mutex.new(:reentrant)
      cluster = on_off_cluster
      persistence.track(cluster)
      cluster.on = true

      entered_before_completion = false
      persistence.fabric_table.on_before_fabric_change = ->(_mutation : Matter::FabricTable::FabricMutation, _index : UInt8) do
        unless storage.transaction_completed?
          entered_before_completion = true
          raise Matter::StorageError.new("Fabric removal entered before the deferred flush completed")
        end
      end

      storage.transaction_completed = false
      storage.pause_next_transaction = true
      flush_done = Channel(Nil).new(1)
      spawn do
        persistence.flush
        flush_done.send(nil)
      end
      storage.transaction_started.receive

      removal_started = Channel(Nil).new(1)
      removal_done = Channel(Bool).new(1)
      spawn do
        removal_started.send(nil)
        removal_done.send(persistence.fabric_table.remove_fabric(1_u8))
      rescue
        removal_done.send(false)
      end
      removal_started.receive
      sleep 100.milliseconds

      storage.transaction_resume.send(nil)
      flush_done.receive
      removal_done.receive.should be_true
      entered_before_completion.should be_false
      persistence.close
    end

    it "saves and restores clusters explicitly" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      cluster = on_off_cluster
      cluster.on = true

      persistence.save_clusters([cluster] of Matter::Cluster::Base).should eq(1)

      restored = on_off_cluster
      persistence.restore_clusters([restored] of Matter::Cluster::Base).should eq(1)
      restored.on_off?.should be_true
      restored.data_version.should eq(cluster.data_version)
    end

    it "forget_cluster removes the document and stops tracking" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      cluster = on_off_cluster
      persistence.track(cluster)
      cluster.on = true
      persistence.flush
      storage.ids(CLUSTERS).should eq([cluster.persistence_key])

      persistence.forget_cluster(cluster)
      storage.ids(CLUSTERS).should be_empty

      cluster.toggle
      persistence.flush
      storage.ids(CLUSTERS).should be_empty
    end

    it "forget_cluster by endpoint and cluster id drops a pending write" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      cluster = on_off_cluster(2_u16)
      persistence.track(cluster)
      cluster.on = true

      persistence.forget_cluster(2_u16, Matter::Cluster::OnOff::CLUSTER_ID)
      persistence.flush
      storage.ids(CLUSTERS).should be_empty
    end
  end

  describe "fabrics and sessions" do
    it "defers fabric last-used writes to the shared debouncer" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      persistence.fabric_table.add_fabric(build_fabric(1_u8))

      persistence.fabric_table.mark_fabric_used(1_u8)
      storage.read(Matter::FabricTable::COLLECTION, "1").as(Matter::Storage::Document)["last_used_at"].should eq(Time.utc(2020, 1, 1))

      persistence.flush
      stored = storage.read(Matter::FabricTable::COLLECTION, "1").as(Matter::Storage::Document)["last_used_at"].as(Time)
      stored.should be > Time.utc(2020, 1, 1)
    end

    it "shares the debouncer with protocol persistence" do
      persistence = Matter::Device::Persistence.new(Matter::Storage::Memory.new)
      persistence.protocol_persistence.write_debouncer.should be(persistence.fabric_table.write_debouncer)
    end
  end

  describe "identity" do
    it "generates and persists the identity values" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)

      hostname = persistence.commissioning_hostname
      serial = persistence.serial_number
      unique_id = persistence.unique_id

      hostname.should match(/\A[0-9A-F]{16}\.local\z/)
      serial.should match(/\A[0-9A-F]{16}\z/)
      unique_id.should match(/\A[0-9a-f]{32}\z/)

      identity = storage.read(DEVICE, Matter::Device::Persistence::IDENTITY_ID).as(Matter::Storage::Document)
      identity[Matter::Device::Persistence::HOSTNAME_KEY].should eq(hostname)
      identity[Matter::Device::Persistence::SERIAL_NUMBER_KEY].should eq(serial)
      identity[Matter::Device::Persistence::UNIQUE_ID_KEY].should eq(unique_id)

      again = Matter::Device::Persistence.new(storage)
      again.commissioning_hostname.should eq(hostname)
      again.serial_number.should eq(serial)
      again.unique_id.should eq(unique_id)
    end

    it "keeps an updated hostname" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)
      persistence.update_hostname("bridge-1.local")
      Matter::Device::Persistence.new(storage).commissioning_hostname.should eq("bridge-1.local")
    end

    it "replaces a malformed stored hostname" do
      storage = Matter::Storage::Memory.new
      storage.write(DEVICE, Matter::Device::Persistence::IDENTITY_ID, Matter::Storage::Document{Matter::Device::Persistence::HOSTNAME_KEY => "nope"})
      Matter::Device::Persistence.new(storage).commissioning_hostname.should match(/\A[0-9A-F]{16}\.local\z/)
    end
  end

  describe "application documents" do
    it "reads, writes and deletes app documents" do
      storage = Matter::Storage::Memory.new
      persistence = Matter::Device::Persistence.new(storage)

      persistence.app_document("bridged_devices").should be_nil
      persistence.write_app_document("bridged_devices", Matter::Storage::Document{"count" => 2_i64})
      persistence.app_document("bridged_devices").should eq(Matter::Storage::Document{"count" => 2_i64})
      storage.ids(APP).should eq(["bridged_devices"])

      persistence.delete_app_document("bridged_devices")
      persistence.app_document("bridged_devices").should be_nil
    end
  end

  describe "lifecycle" do
    it "restores cluster state after close and reopen" do
      with_temp_file do |path|
        persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
        cluster = on_off_cluster
        persistence.track(cluster)
        cluster.on = true
        persistence.close

        reopened = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
        restored = on_off_cluster
        reopened.restore_clusters([restored] of Matter::Cluster::Base).should eq(1)
        restored.on_off?.should be_true
        reopened.close
      end
    end

    it "reset! removes every document and the file" do
      with_temp_file do |path|
        persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
        persistence.fabric_table.add_fabric(build_fabric(1_u8))
        persistence.serial_number
        persistence.write_app_document("thing", Matter::Storage::Document{"a" => 1_i64})
        File.exists?(path).should be_true

        persistence.reset!
        File.exists?(path).should be_false

        fresh = Matter::Storage::YamlFile.new(path)
        fresh.open
        fresh.collections.should eq([Matter::Storage::Collections::META])
        fresh.close
      end
    end

    it "reset! works after close" do
      with_temp_file do |path|
        persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
        persistence.serial_number
        persistence.close

        persistence.reset!
        File.exists?(path).should be_false
      end
    end

    it "close is idempotent and flush is a no-op once closed" do
      persistence = Matter::Device::Persistence.new(Matter::Storage::Memory.new)
      persistence.close
      persistence.close
      persistence.flush
    end
  end
end
