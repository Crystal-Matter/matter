require "../spec_helper"
require "../../src/matter/device"

private alias HostAcl = Matter::Cluster::AccessControl

private class ManagedRestrictionSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Managed Restriction Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8131_u16,
    discriminator: 3845_u16, pin: 20202096_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory

  def release : Nil
    message_handler.close
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
    persistence.close
    transport.close
  end
end

private def managed_spec_fabric(index : UInt8) : Matter::Fabric
  Matter::Fabric.new(fabric_id: 0xA001_u64, fabric_index: index, node_id: 0xB001_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
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
end
