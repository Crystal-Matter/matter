require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/wi_fi_network_management"

private alias StoredAcl = Matter::Cluster::AccessControl
private alias StoredWifi = Matter::Cluster::WiFiNetworkManagement

private def stored_entry : StoredAcl::AccessRestrictionEntry
  StoredAcl::AccessRestrictionEntry.new(1_u16, StoredWifi::CLUSTER_ID, [
    StoredAcl::AccessRestriction.new(StoredAcl::AccessRestrictionType::AttributeAccessForbidden,
      StoredWifi::ATTR_SSID),
  ])
end

private def stored_cluster(timeout : Time::Span = StoredAcl::DEFAULT_REVIEW_TIMEOUT) : StoredAcl
  StoredAcl.new(endpoint(0), StoredAcl::Feature::Extension, review_timeout: timeout)
end

private def stored_callbacks(acl : StoredAcl, requested : Array(StoredAcl::RestrictionReviewRequest),
                             updated : Array(Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate))) : Nil
  acl.on_restriction_review_requested { |request| requested << request }
  acl.on_restriction_review_updated { |fabric, update| updated << {fabric, update} }
end

describe "Access Control managed restriction persistence" do
  it "restores each fabric's ARL and replays a pending review with its original token" do
    original = stored_cluster
    original.configure_access_restrictions(1_u8, [stored_entry])
    original.configure_access_restrictions(2_u8, [
      StoredAcl::AccessRestrictionEntry.new(1_u16, StoredWifi::CLUSTER_ID, [
        StoredAcl::AccessRestriction.new(StoredAcl::AccessRestrictionType::CommandForbidden,
          StoredWifi::CMD_NETWORK_PASSPHRASE_REQUEST),
      ]),
    ])
    original.configure_commissioning_access_restrictions([
      StoredAcl::CommissioningAccessRestrictionEntry.new(1_u16, StoredWifi::CLUSTER_ID,
        stored_entry.restrictions),
    ])
    initial_requests = [] of StoredAcl::RestrictionReviewRequest
    initial_updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(original, initial_requests, initial_updates)
    token = original.request_restriction_review(1_u8, [stored_entry])
    document = original.save_state.as(Matter::Storage::Document)

    restored = stored_cluster
    restored.restore_state(document)
    restored.arl(1_u8).first.restrictions.first.id.should eq(StoredWifi::ATTR_SSID)
    restored.arl(2_u8).first.restrictions.first.type.should eq(StoredAcl::AccessRestrictionType::CommandForbidden)
    restored.commissioning_arl.size.should eq(1)
    expect_raises(Matter::ConfigurationError) do
      restored.configure_commissioning_access_restrictions([] of StoredAcl::CommissioningAccessRestrictionEntry)
    end
    replayed = [] of StoredAcl::RestrictionReviewRequest
    updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(restored, replayed, updates)
    replayed.map(&.token).should eq([token])
    replayed.first.entries.should eq([stored_entry])
    restored.complete_restriction_review(1_u8, token).should be_true
    updates.map(&.[0]).should eq([1_u8])
    updates.map(&.[1].token).should eq([token])
    restored.request_restriction_review(2_u8, [] of StoredAcl::AccessRestrictionEntry)
      .should be > token
  end

  it "delivers an overdue review update after restart without re-requesting host consent" do
    original = stored_cluster(5.milliseconds)
    initial_requests = [] of StoredAcl::RestrictionReviewRequest
    initial_updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(original, initial_requests, initial_updates)
    token = original.request_restriction_review(1_u8, [stored_entry])
    document = original.save_state.as(Matter::Storage::Document)
    sleep 10.milliseconds

    restored = stored_cluster(5.milliseconds)
    restored.restore_state(document)
    replayed = [] of StoredAcl::RestrictionReviewRequest
    updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(restored, replayed, updates)
    replayed.should be_empty
    updates.map(&.[1].token).should eq([token])
    restored.complete_restriction_review(1_u8, token).should be_false
  end

  it "persists fabric removal and reads old documents without MNGD keys" do
    original = stored_cluster
    original.configure_access_restrictions(1_u8, [stored_entry])
    requested = [] of StoredAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(original, requested, updated)
    token = original.request_restriction_review(1_u8, [stored_entry])
    original.remove_fabric_acl(1_u8)
    restored = stored_cluster
    restored.restore_state(original.save_state.as(Matter::Storage::Document))
    restored.arl(1_u8).should be_empty
    restored.complete_restriction_review(1_u8, token).should be_false

    legacy = original.save_state.as(Matter::Storage::Document)
    {"access_restrictions", "commissioning_arl", "commissioning_arl_configured",
     "pending_restriction_reviews", "next_restriction_review_token"}.each { |key| legacy.delete(key) }
    from_legacy = stored_cluster
    from_legacy.restore_state(legacy)
    from_legacy.arl(1_u8).should be_empty
  end

  it "rolls back a restriction removal when durable storage fails" do
    acl = stored_cluster
    acl.configure_access_restrictions(1_u8, [stored_entry])
    before_version = acl.data_version
    acl.on_persist = -> { raise Matter::StorageError.new("storage failed") }
    expect_raises(Matter::StorageError) do
      acl.configure_access_restrictions(1_u8, [] of StoredAcl::AccessRestrictionEntry)
    end
    acl.arl(1_u8).size.should eq(1)
    acl.data_version.should eq(before_version)
    expect_raises(Matter::StorageError) do
      acl.configure_commissioning_access_restrictions([
        StoredAcl::CommissioningAccessRestrictionEntry.new(1_u16, StoredWifi::CLUSTER_ID,
          stored_entry.restrictions),
      ])
    end
    acl.commissioning_arl.should be_empty
    acl.on_persist = nil
    acl.configure_commissioning_access_restrictions([] of StoredAcl::CommissioningAccessRestrictionEntry)
  end

  it "identifies managed state for an orphaned fabric even when it has no ACL" do
    acl = stored_cluster
    acl.configure_access_restrictions(2_u8, [stored_entry])
    requested = [] of StoredAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(acl, requested, updated)
    acl.request_restriction_review(3_u8, [stored_entry])
    restored = stored_cluster
    restored.restore_state(acl.save_state.as(Matter::Storage::Document))
    restored.restriction_fabric_indexes.sort.should eq([2_u8, 3_u8])
    restored.remove_fabric_acl(2_u8)
    restored.remove_fabric_acl(3_u8)
    restored.restriction_fabric_indexes.should be_empty
  end

  it "does not replay a host request that failed before its token was returned" do
    original = stored_cluster
    saved_document = original.save_state.as(Matter::Storage::Document)
    original.on_persist = -> do
      saved_document = original.save_state.as(Matter::Storage::Document)
      nil
    end
    original.on_restriction_review_requested do |_request|
      raise Matter::ConfigurationError.new("host unavailable")
    end
    original.on_restriction_review_updated { |_fabric, _update| }
    expect_raises(Matter::ConfigurationError) do
      original.request_restriction_review(1_u8, [] of StoredAcl::AccessRestrictionEntry)
    end

    restored = stored_cluster
    restored.restore_state(saved_document)
    replayed = [] of StoredAcl::RestrictionReviewRequest
    updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(restored, replayed, updates)
    replayed.should be_empty
    updates.should be_empty
  end
end
