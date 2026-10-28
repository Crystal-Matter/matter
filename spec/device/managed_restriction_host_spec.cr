require "../spec_helper"
require "../../src/matter/device"
require "../../src/matter/cluster/wi_fi_network_management"

private alias HostAcl = Matter::Cluster::AccessControl

private class ManagedRestrictionSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Managed Restriction Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8131_u16,
    discriminator: 3845_u16, pin: 20202096_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory

  def release : Nil
    message_handler.close
    access_control.shutdown_restriction_review_workers
    persistence.close
    transport.close
  end
end

private class ManagedRestrictionDslSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Managed Restriction DSL Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8132_u16,
    discriminator: 3846_u16, pin: 20202095_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage yaml: "managed-restriction-spec.yml"

  getter requested = [] of UInt64
  getter updated = [] of UInt64

  managed_restrictions requested: :review_requested, updated: :review_updated

  private def review_requested(request : HostAcl::RestrictionReviewRequest) : Nil
    @requested << request.token
  end

  private def review_updated(_fabric : UInt8, update : HostAcl::FabricRestrictionReviewUpdate) : Nil
    @updated << update.token
  end

  def release : Nil
    message_handler.close
    access_control.shutdown_restriction_review_workers
    persistence.close
    transport.close
  end
end

private class ManagedPolicyFailingYaml < Matter::Storage::YamlFile
  property fail_acl_id : String?

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::CLUSTERS && id == @fail_acl_id
      raise Matter::StorageError.new("Injected managed policy cleanup failure")
    end
    super
  end
end

private class ManagedEventCounterFailingYaml < Matter::Storage::YamlFile
  property? fail_next_event_counter = false

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_next_event_counter && collection == Matter::Storage::Collections::DEVICE &&
       id == Matter::Protocol::Persistence::StorageBackend::EVENT_COUNTER_ID
      @fail_next_event_counter = false
      raise Matter::StorageError.new("Injected event counter write failure")
    end
    super
  end
end

private class ManagedNilPathDurableStore < Matter::Storage::Memory
  def durable? : Bool
    true
  end
end

private def managed_spec_fabric(index : UInt8) : Matter::Fabric
  Matter::Fabric.new(fabric_id: 0xA001_u64, fabric_index: index, node_id: 0xB001_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

private def managed_spec_restriction_entry : HostAcl::AccessRestrictionEntry
  HostAcl::AccessRestrictionEntry.new(1_u16, Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID, [
    HostAcl::AccessRestriction.new(HostAcl::AccessRestrictionType::AttributeAccessForbidden,
      Matter::Cluster::WiFiNetworkManagement::ATTR_SSID),
  ])
end

describe "Device managed restriction host" do
  it "leaves ManagedDevice and its command unadvertised by default" do
    require_udp_sockets!
    device = ManagedRestrictionSpecDevice.new(port: 0)
    device.access_control.feature_map.managed_device?.should be_false
    device.access_control.commands.map(&.id.id).should_not contain(HostAcl::CMD_REVIEW_FABRIC_RESTRICTIONS)
  ensure
    device.try(&.release)
  end

  it "rejects incomplete callbacks and volatile storage" do
    require_udp_sockets!
    requested = ->(_request : HostAcl::RestrictionReviewRequest) { nil }
    updated = ->(_fabric : UInt8, _update : HostAcl::FabricRestrictionReviewUpdate) { nil }
    expect_raises(Matter::ConfigurationError, /both.*callbacks/) do
      ManagedRestrictionSpecDevice.new(port: 0, on_restriction_review_requested: requested)
    end
    expect_raises(Matter::ConfigurationError, /durable storage/) do
      ManagedRestrictionSpecDevice.new(port: 0, on_restriction_review_requested: requested,
        on_restriction_review_updated: updated)
    end
  end

  it "accepts a durable backend with no local filesystem path" do
    require_udp_sockets!
    requested = ->(_request : HostAcl::RestrictionReviewRequest) { nil }
    updated = ->(_fabric : UInt8, _update : HostAcl::FabricRestrictionReviewUpdate) { nil }
    backend = ManagedNilPathDurableStore.new
    backend.path.should be_nil
    device = ManagedRestrictionSpecDevice.new(storage: backend, port: 0,
      on_restriction_review_requested: requested, on_restriction_review_updated: updated)
    device.access_control.feature_map.managed_device?.should be_true
  ensure
    device.try(&.release)
  end

  it "accepts callback keywords with durable storage and rejects an absent fabric atomically" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-keywords-#{Random::Secure.hex(8)}.yml")
    requested = ->(_request : HostAcl::RestrictionReviewRequest) { nil }
    updated = ->(_fabric : UInt8, _update : HostAcl::FabricRestrictionReviewUpdate) { nil }
    device = ManagedRestrictionSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0,
      on_restriction_review_requested: requested, on_restriction_review_updated: updated)
    device.access_control.feature_map.managed_device?.should be_true
    expect_raises(Matter::ConfigurationError, /fabric is unavailable/) do
      device.access_control.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    end
    device.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    device.access_control.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry).should eq(1_u64)
  ensure
    device.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "advertises ManagedDevice and replays a saved request token after restart" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-restriction-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    acl = first.access_control
    acl.feature_map.managed_device?.should be_true
    acl.commands.map(&.id.id).should contain(HostAcl::CMD_REVIEW_FABRIC_RESTRICTIONS)
    acl.attributes.map(&.id.id).should contain(HostAcl::ATTR_ARL)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    token = acl.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    first.requested.should eq([token])
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.requested.should eq([token])
    second.access_control.deny_restriction_review(1_u8, token).should be_true
    second.updated.should eq([token])
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "replays a durable completion outbox with the same token after restart" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-outbox-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = first.access_control
    token = acl.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    saved_device = first
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("final write failed") if saves == 2
      saved_device.persistence.save_cluster(acl)
      nil
    end
    expect_raises(Matter::StorageError) { acl.deny_restriction_review(1_u8, token) }
    first.updated.should eq([token])
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.updated.should eq([token])
    second.access_control.deny_restriction_review(1_u8, token).should be_false
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "retains a completion outbox when its review event cannot be journaled durably" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-event-failure-#{Random::Secure.hex(8)}.yml")
    backend = ManagedEventCounterFailingYaml.new(path)
    first = ManagedRestrictionDslSpecDevice.new(storage: backend, port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = first.access_control
    token = acl.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    review_path = [Matter::InteractionModel::EventPath.new(endpoint: 0_u16,
      cluster: HostAcl::CLUSTER_ID, event: HostAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE)]

    backend.fail_next_event_counter = true
    expect_raises(Matter::EventJournalError, /not journaled/) do
      acl.deny_restriction_review(1_u8, token)
    end
    first.updated.should eq([token])
    first.node.event_journal.query(review_path, fabric_index: 1_u8).should be_empty
    saved = backend.read(Matter::Storage::Collections::CLUSTERS,
      acl.persistence_key).as(Matter::Storage::Document)
    saved["review_completion_outbox"].as(Array(Matter::Storage::Type)).size.should eq(1)
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.updated.should eq([token])
    second.node.event_journal.query(review_path, fabric_index: 1_u8).size.should eq(1)
    second.access_control.deny_restriction_review(1_u8, token).should be_false
    second.node.event_journal.query(review_path, fabric_index: 1_u8).size.should eq(1)
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "does not duplicate a journaled review event when its observer fails" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-event-observer-#{Random::Secure.hex(8)}.yml")
    device = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    device.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = device.access_control
    token = acl.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    review_path = [Matter::InteractionModel::EventPath.new(endpoint: 0_u16,
      cluster: HostAcl::CLUSTER_ID, event: HostAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE)]
    observer_calls = 0
    device.node.on_event_emitted = ->(_record : Matter::EventJournal::Record) do
      observer_calls += 1
      raise Matter::StorageError.new("Injected observer failure")
    end

    acl.deny_restriction_review(1_u8, token).should be_true
    device.updated.should eq([token])
    observer_calls.should eq(1)
    device.node.event_journal.query(review_path, fabric_index: 1_u8).size.should eq(1)
    acl.deny_restriction_review(1_u8, token).should be_false
    device.node.event_journal.query(review_path, fabric_index: 1_u8).size.should eq(1)
  ensure
    device.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "prunes an orphaned completion outbox before installing host callbacks" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-orphan-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = first.access_control
    token = acl.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    saved_device = first
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("final write failed") if saves == 2
      saved_device.persistence.save_cluster(acl)
      nil
    end
    expect_raises(Matter::StorageError) { acl.deny_restriction_review(1_u8, token) }
    first.fabric_table.remove_fabric(1_u8).should be_true
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.updated.should be_empty
    second.access_control.deny_restriction_review(1_u8, token).should be_false
    review_path = [Matter::InteractionModel::EventPath.new(endpoint: 0_u16,
      cluster: HostAcl::CLUSTER_ID, event: HostAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE)]
    second.node.event_journal.query(review_path, fabric_index: 1_u8).should be_empty
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "does not deliver an old outbox to a replacement fabric using the same index" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-reused-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = first.access_control
    token = acl.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    saved_device = first
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("final write failed") if saves == 2
      saved_device.persistence.save_cluster(acl)
      nil
    end
    expect_raises(Matter::StorageError) { acl.deny_restriction_review(1_u8, token) }
    first.fabric_table.remove_fabric(1_u8).should be_true
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.updated.should be_empty
    second.access_control.deny_restriction_review(1_u8, token).should be_false
    review_path = [Matter::InteractionModel::EventPath.new(endpoint: 0_u16,
      cluster: HostAcl::CLUSTER_ID, event: HostAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE)]
    second.node.event_journal.query(review_path, fabric_index: 1_u8).should be_empty
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "cancels a legacy review with no fabric identity before replaying callbacks" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-legacy-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = first.access_control
    token = acl.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    backend = first.persistence.backend
    collection = Matter::Storage::Collections::CLUSTERS
    document = backend.read(collection, acl.persistence_key).as(Matter::Storage::Document)
    review = document["pending_restriction_reviews"].as(Array(Matter::Storage::Type)).first.as(Matter::Storage::Document)
    review.delete("fabric_identity")
    backend.write(collection, acl.persistence_key, document)
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.requested.should be_empty
    second.access_control.deny_restriction_review(1_u8, token).should be_false
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "does not restore old ARL policy onto a replacement fabric with the same index" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-policy-reused-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    first.access_control.configure_access_restrictions(1_u8, [managed_spec_restriction_entry])
    first.access_control.arl(1_u8).should_not be_empty
    first.fabric_table.remove_fabric(1_u8).should be_true
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.access_control.arl(1_u8).should be_empty
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "does not apply an old ARL to a replacement fabric before restart" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-live-policy-reused-#{Random::Secure.hex(8)}.yml")
    device = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    device.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = device.access_control
    acl.configure_access_restrictions(1_u8, [managed_spec_restriction_entry])
    acl.attribute_read_restricted?(1_u8, 1_u16, Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID,
      Matter::Cluster::WiFiNetworkManagement::ATTR_SSID).should be_true
    device.fabric_table.remove_fabric(1_u8).should be_true
    device.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true

    acl.attribute_read_restricted?(1_u8, 1_u16, Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID,
      Matter::Cluster::WiFiNetworkManagement::ATTR_SSID).should be_false
    acl.arl(1_u8).should be_empty
    device.release
    device = nil

    restarted = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    restarted.access_control.arl(1_u8).should be_empty
  ensure
    device.try(&.release)
    restarted.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "fails closed if stale live ARL cleanup cannot persist" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-live-policy-failure-#{Random::Secure.hex(8)}.yml")
    backend = ManagedPolicyFailingYaml.new(path)
    device = ManagedRestrictionDslSpecDevice.new(storage: backend, port: 0)
    device.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = device.access_control
    acl.configure_access_restrictions(1_u8, [managed_spec_restriction_entry])
    # Simulate an out-of-band identity mutation. Normal removal now erases the
    # old ARL before the index can be reused.
    device.fabric_table.get_fabric(1_u8).as(Matter::Fabric).fabric_id = 0xA002_u64
    backend.fail_acl_id = acl.persistence_key

    expect_raises(Matter::StorageError) do
      acl.arl(1_u8)
    end
    expect_raises(Matter::StorageError) do
      acl.attribute_read_restricted?(1_u8, 1_u16, Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID,
        Matter::Cluster::WiFiNetworkManagement::ATTR_SSID)
    end
    backend.fail_acl_id = nil
    acl.arl(1_u8).should be_empty
  ensure
    device.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "retains ARL policy across restart for the same fabric" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-policy-same-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    first.access_control.configure_access_restrictions(1_u8, [managed_spec_restriction_entry])
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.access_control.arl(1_u8).size.should eq(1)
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "binds host-approved ARL to its fabric identity" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-policy-approved-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    token = first.access_control.request_restriction_review(1_u8, [] of HostAcl::AccessRestrictionEntry)
    first.access_control.approve_restriction_review(1_u8, token, [managed_spec_restriction_entry]).should be_true
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.access_control.arl(1_u8).size.should eq(1)
    second.fabric_table.remove_fabric(1_u8).should be_true
    second.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    second.release
    second = nil

    third = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    third.access_control.arl(1_u8).should be_empty
  ensure
    first.try(&.release)
    second.try(&.release)
    third.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "prunes legacy ARL policy without a saved fabric identity" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-policy-legacy-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = first.access_control
    acl.configure_access_restrictions(1_u8, [managed_spec_restriction_entry])
    backend = first.persistence.backend
    collection = Matter::Storage::Collections::CLUSTERS
    document = backend.read(collection, acl.persistence_key).as(Matter::Storage::Document)
    document.delete("access_restriction_fabric_identities")
    backend.write(collection, acl.persistence_key, document)
    first.release
    first = nil

    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.access_control.arl(1_u8).should be_empty
  ensure
    first.try(&.release)
    second.try(&.release)
    File.delete(path) if path && File.exists?(path)
  end

  it "refuses startup when stale ARL policy cannot be durably pruned" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-managed-policy-failclosed-#{Random::Secure.hex(8)}.yml")
    first = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl = first.access_control
    acl.configure_access_restrictions(1_u8, [managed_spec_restriction_entry])
    stale_document = first.persistence.backend.read(Matter::Storage::Collections::CLUSTERS,
      acl.persistence_key).as(Matter::Storage::Document)
    first.fabric_table.remove_fabric(1_u8).should be_true
    first.fabric_table.add_fabric(managed_spec_fabric(1_u8)).should be_true
    acl_id = acl.persistence_key
    # Model an interrupted older removal leaving its Access Control document
    # behind; current removal guards clear the policy before index reuse.
    first.persistence.backend.write(Matter::Storage::Collections::CLUSTERS, acl_id, stale_document)
    first.release
    first = nil

    failing = ManagedPolicyFailingYaml.new(path)
    failing.fail_acl_id = acl_id
    expect_raises(Matter::StorageError, /stale managed restriction cleanup/) do
      ManagedRestrictionDslSpecDevice.new(storage: failing, port: 0)
    end
    failing.close
    second = ManagedRestrictionDslSpecDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.access_control.arl(1_u8).should be_empty
  ensure
    first.try(&.release)
    second.try(&.release)
    failing.try { |backend| backend.close if backend.open? }
    File.delete(path) if path && File.exists?(path)
  end
end
