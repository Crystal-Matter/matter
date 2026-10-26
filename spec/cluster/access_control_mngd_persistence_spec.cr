require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/wi_fi_network_management"
require "../../src/matter/device/persistence"
require "../../src/matter/cluster/on_off"

private class FailingReadStorage < Matter::Storage::Memory
  property? fail_reads = false

  def read(collection : String, id : String) : Matter::Storage::Document?
    raise Matter::StorageError.new("unreadable document") if @fail_reads
    super
  end
end

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
  it "allows an inline host approval and saves a restartable completed token" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    updates = [] of UInt64
    acl.on_restriction_review_updated { |_fabric, update| updates << update.token }
    acl.on_restriction_review_requested do |request|
      acl.approve_restriction_review(request.fabric_index, request.token, [stored_entry]).should be_true
    end
    token = acl.request_restriction_review(1_u8, [] of StoredAcl::AccessRestrictionEntry)
    updates.should eq([token])
    acl.arl(1_u8).size.should eq(1)

    restored = stored_cluster
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.arl(1_u8).size.should eq(1)
    restored.complete_restriction_review(1_u8, token).should be_false
  end

  it "allows an inline host denial without leaving an unfinished request marker" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    updates = [] of UInt64
    acl.on_restriction_review_updated { |_fabric, update| updates << update.token }
    acl.on_restriction_review_requested do |request|
      acl.deny_restriction_review(request.fabric_index, request.token).should be_true
    end
    token = acl.request_restriction_review(1_u8, [] of StoredAcl::AccessRestrictionEntry)
    updates.should eq([token])

    restored = stored_cluster
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.complete_restriction_review(1_u8, token).should be_false
  end

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

  it "blocks restart when a rejected host request cannot be durably cancelled" do
    original = stored_cluster
    saved = original.save_state.as(Matter::Storage::Document)
    saves = 0
    original.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("cancellation failed") if saves > 1
      saved = original.save_state.as(Matter::Storage::Document)
      nil
    end
    original.on_restriction_review_requested do |_request|
      raise Matter::ConfigurationError.new("host rejected request")
    end
    original.on_restriction_review_updated { |_fabric, _update| }
    expect_raises(Matter::StorageError) do
      original.request_restriction_review(1_u8, [stored_entry])
    end
    expect_raises(Matter::AccessControlRestoreError) do
      stored_cluster.restore_state(saved)
    end
  end

  it "rejects missing or malformed managed fields instead of clearing restrictions" do
    original = stored_cluster
    original.configure_access_restrictions(1_u8, [stored_entry])
    missing = original.save_state.as(Matter::Storage::Document)
    missing.delete("access_restrictions")
    expect_raises(Matter::AccessControlRestoreError) do
      stored_cluster.restore_state(missing)
    end

    malformed = original.save_state.as(Matter::Storage::Document)
    malformed["access_restrictions"] = "corrupt"
    expect_raises(Matter::AccessControlRestoreError) do
      stored_cluster.restore_state(malformed)
    end
  end

  it "rejects malformed legacy ACL state while accepting valid legacy documents" do
    legacy = stored_cluster.save_state.as(Matter::Storage::Document)
    StoredAcl::MANAGED_PERSISTED_KEYS.each { |key| legacy.delete(key) }
    stored_cluster.restore_state(legacy)
    expect_raises(Matter::AccessControlRestoreError) do
      StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice).restore_state(legacy)
    end
    legacy["acl"] = "corrupt"
    expect_raises(Matter::AccessControlRestoreError) do
      stored_cluster.restore_state(legacy)
    end
  end

  it "aborts cluster restore when a saved managed policy is corrupt" do
    storage = Matter::Storage::Memory.new
    persistence = Matter::Device::Persistence.new(storage)
    original = stored_cluster
    original.configure_access_restrictions(1_u8, [stored_entry])
    corrupt = original.save_state.as(Matter::Storage::Document)
    corrupt["access_restrictions"] = "corrupt"
    storage.write(Matter::Storage::Collections::CLUSTERS, original.persistence_key, corrupt)
    expect_raises(Matter::AccessControlRestoreError) do
      persistence.restore_clusters([stored_cluster] of Matter::Cluster::Base)
    end
    persistence.close
  end

  it "aborts Access Control startup on an unreadable document but retains best effort for ordinary clusters" do
    storage = FailingReadStorage.new
    persistence = Matter::Device::Persistence.new(storage)
    storage.fail_reads = true
    expect_raises(Matter::AccessControlRestoreError) do
      persistence.restore_clusters([stored_cluster] of Matter::Cluster::Base)
    end
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    persistence.restore_clusters([on_off] of Matter::Cluster::Base).should eq(0)
    persistence.close
  end

  it "does not emit a review update when durable completion fails" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    requests = [] of StoredAcl::RestrictionReviewRequest
    updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(acl, requests, updates)
    events = [] of UInt32
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) { events << id; nil }
    token = acl.request_restriction_review(1_u8, [stored_entry])
    acl.on_persist = -> { raise Matter::StorageError.new("storage failed") }
    expect_raises(Matter::StorageError) { acl.deny_restriction_review(1_u8, token) }
    events.should be_empty
    updates.should be_empty
    acl.on_persist = nil
    acl.deny_restriction_review(1_u8, token).should be_true
  end

  it "compensates the persisted token and approved policy when delivery fails" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [stored_entry])
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| raise Matter::ConfigurationError.new("host failed") }
    events = [] of UInt32
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) { events << id; nil }
    token = acl.request_restriction_review(1_u8, [stored_entry])
    expect_raises(Matter::ConfigurationError) do
      acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry)
    end
    restored = stored_cluster
    restored.restore_state(saved)
    restored.arl(1_u8).size.should eq(1)
    restored.arl(1_u8).first.restrictions.should eq(stored_entry.restrictions)
    replayed = [] of StoredAcl::RestrictionReviewRequest
    updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(restored, replayed, updates)
    replayed.map(&.token).should eq([token])
    events.should be_empty
  end

  it "keeps a durable decision when an event observer raises after journaling" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [stored_entry])
    events = [] of UInt32
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) do
      events << id
      raise Matter::StorageError.new("observer failed")
    end
    acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry).should be_true
    events.should eq([StoredAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
    restored = stored_cluster
    restored.restore_state(saved)
    restored.deny_restriction_review(1_u8, token).should be_false
  end

  it "does not deliver the same token while its host completion callback is still running" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated do |_fabric, _update|
      entered.send(nil)
      release.receive
      raise Matter::ConfigurationError.new("host completion failed")
    end
    events = [] of UInt32
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) { events << id; nil }
    token = acl.request_restriction_review(1_u8, [stored_entry])
    outcome = Channel(Exception?).new(1)
    spawn do
      acl.deny_restriction_review(1_u8, token)
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end
    entered.receive
    second_result = acl.complete_restriction_review(1_u8, token)
    events_before_release = events.dup
    outbox_size_before_release = saved["review_completion_outbox"].as(Array(Matter::Storage::Type)).size
    release.send(nil)
    second_result.should be_false
    events_before_release.should be_empty
    outbox_size_before_release.should eq(1)
    outcome.receive.should be_a(Matter::ConfigurationError)
    events.should be_empty
    saved["review_completion_outbox"].as(Array(Matter::Storage::Type)).should be_empty
    saved["pending_restriction_reviews"].as(Array(Matter::Storage::Type)).size.should eq(1)
    acl.on_restriction_review_updated { |_fabric, _update| }
    acl.deny_restriction_review(1_u8, token).should be_true
    events.should eq([StoredAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
  end

  it "serializes same-fabric approvals and restores policy after failed callbacks" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [stored_entry])
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    first_token = 0_u64
    fail_second = true
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated do |_fabric, update|
      if update.token == first_token
        entered.send(nil)
        release.receive
        raise Matter::ConfigurationError.new("first host completion failed")
      end
      raise Matter::ConfigurationError.new("second host completion failed") if fail_second
    end
    first_token = acl.request_restriction_review(1_u8, [stored_entry])
    second_token = acl.request_restriction_review(1_u8, [stored_entry])
    outcome = Channel(Exception?).new(1)
    spawn do
      acl.approve_restriction_review(1_u8, first_token, [] of StoredAcl::AccessRestrictionEntry)
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end
    entered.receive
    replacement = StoredAcl::AccessRestrictionEntry.new(1_u16, StoredWifi::CLUSTER_ID, [
      StoredAcl::AccessRestriction.new(StoredAcl::AccessRestrictionType::CommandForbidden,
        StoredWifi::CMD_NETWORK_PASSPHRASE_REQUEST),
    ])
    second_result = acl.approve_restriction_review(1_u8, second_token, [replacement])
    release.send(nil)
    second_result.should be_false
    outcome.receive.should be_a(Matter::ConfigurationError)
    acl.arl(1_u8).first.restrictions.should eq(stored_entry.restrictions)
    expect_raises(Matter::ConfigurationError, /second host completion failed/) do
      acl.approve_restriction_review(1_u8, second_token, [replacement])
    end
    acl.arl(1_u8).first.restrictions.should eq(stored_entry.restrictions)
    fail_second = false
    acl.approve_restriction_review(1_u8, second_token, [replacement]).should be_true
    acl.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
    restored = stored_cluster
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
  end

  it "rejects a same-fabric policy configuration during a yielding approval callback" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [stored_entry])
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated do |_fabric, _update|
      entered.send(nil)
      release.receive
      raise Matter::ConfigurationError.new("host completion failed")
    end
    token = acl.request_restriction_review(1_u8, [stored_entry])
    outcome = Channel(Exception?).new(1)
    spawn do
      acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry)
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end
    entered.receive
    replacement = StoredAcl::AccessRestrictionEntry.new(1_u16, StoredWifi::CLUSTER_ID, [
      StoredAcl::AccessRestriction.new(StoredAcl::AccessRestrictionType::CommandForbidden,
        StoredWifi::CMD_NETWORK_PASSPHRASE_REQUEST),
    ])
    configuration_error = begin
      acl.configure_access_restrictions(1_u8, [replacement])
      nil
    rescue ex
      ex
    end
    release.send(nil)
    configuration_error.should be_a(Matter::ConfigurationError)
    configuration_error.as(Matter::ConfigurationError).message.as(String).should contain("already in progress")
    outcome.receive.should be_a(Matter::ConfigurationError)
    acl.arl(1_u8).first.restrictions.should eq(stored_entry.restrictions)
    acl.configure_access_restrictions(1_u8, [replacement])
    acl.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
    restored = stored_cluster
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
  end

  it "keeps another fabric's policy and data version when a yielding approval fails" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [stored_entry])
    acl.configure_access_restrictions(2_u8, [stored_entry])
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated do |_fabric, _update|
      entered.send(nil)
      release.receive
      raise Matter::ConfigurationError.new("host completion failed")
    end
    token = acl.request_restriction_review(1_u8, [stored_entry])
    outcome = Channel(Exception?).new(1)
    spawn do
      acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry)
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end
    entered.receive
    replacement = StoredAcl::AccessRestrictionEntry.new(1_u16, StoredWifi::CLUSTER_ID, [
      StoredAcl::AccessRestriction.new(StoredAcl::AccessRestrictionType::CommandForbidden,
        StoredWifi::CMD_NETWORK_PASSPHRASE_REQUEST),
    ])
    acl.configure_access_restrictions(2_u8, [replacement])
    version_after_other_fabric = acl.data_version
    release.send(nil)
    outcome.receive.should be_a(Matter::ConfigurationError)
    acl.arl(1_u8).first.restrictions.should eq(stored_entry.restrictions)
    acl.arl(2_u8).first.restrictions.should eq(replacement.restrictions)
    acl.data_version.should be >= version_after_other_fabric
    restored = stored_cluster
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.arl(2_u8).first.restrictions.should eq(replacement.restrictions)
  end

  it "blocks restart if compensation cannot save after a host callback failure" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [stored_entry])
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| raise Matter::ConfigurationError.new("host failed") }
    token = acl.request_restriction_review(1_u8, [stored_entry])
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("compensation failed") if saves > 1
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    expect_raises(Matter::StorageError) do
      acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry)
    end
    acl.arl(1_u8).first.restrictions.should eq(stored_entry.restrictions)
    expect_raises(Matter::AccessControlRestoreError) do
      stored_cluster.restore_state(saved)
    end
  end

  it "keeps host-approved policy when the final write reports an ambiguous failure" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [stored_entry])
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [stored_entry])
    saved = acl.save_state.as(Matter::Storage::Document)
    saves = 0
    acl.on_persist = -> do
      saves += 1
      saved = acl.save_state.as(Matter::Storage::Document)
      raise Matter::StorageError.new("write acknowledged late") if saves == 2
      nil
    end
    expect_raises(Matter::StorageError) do
      acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry)
    end
    acl.arl(1_u8).should be_empty
    restored = stored_cluster
    restored.restore_state(saved)
    restored.arl(1_u8).should be_empty
    restored.deny_restriction_review(1_u8, token).should be_false
  end

  it "retries final persistence and event delivery without repeating host consent" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    requested = [] of StoredAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(acl, requested, updated)
    token = acl.request_restriction_review(1_u8, [stored_entry])
    events = [] of UInt32
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) { events << id; nil }
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("final write failed") if saves == 2
      nil
    end
    expect_raises(Matter::StorageError) do
      acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry)
    end
    updated.size.should eq(1)
    events.should eq([StoredAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
    acl.complete_restriction_review(1_u8, token).should be_true
    updated.size.should eq(1)
    events.should eq([StoredAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
    acl.complete_restriction_review(1_u8, token).should be_false
  end

  it "automatically retries a failed final review write while the device is running" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice,
      review_delivery_retry_interval: 5.milliseconds)
    requested = [] of StoredAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(acl, requested, updated)
    token = acl.request_restriction_review(1_u8, [stored_entry])
    events = [] of UInt32
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) { events << id; nil }
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("final write failed") if saves == 2
      nil
    end
    expect_raises(Matter::StorageError) { acl.deny_restriction_review(1_u8, token) }
    40.times do
      break if saves >= 3
      sleep 5.milliseconds
    end
    saves.should be >= 3
    updated.size.should eq(1)
    events.should eq([StoredAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
    acl.complete_restriction_review(1_u8, token).should be_false
  end

  it "notifies ARL subscribers once after a failed final approval save is retried" do
    acl = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice,
      review_delivery_retry_interval: 5.milliseconds)
    acl.configure_access_restrictions(1_u8, [stored_entry])
    requested = [] of StoredAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(acl, requested, updated)
    token = acl.request_restriction_review(1_u8, [stored_entry])
    changed = [] of UInt32
    events = [] of UInt32
    acl.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) { changed << attribute; nil }
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) { events << id; nil }
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("final write failed") if saves == 2
      nil
    end

    expect_raises(Matter::StorageError) do
      acl.approve_restriction_review(1_u8, token, [] of StoredAcl::AccessRestrictionEntry)
    end
    changed.should be_empty
    40.times do
      break unless changed.empty?
      sleep 5.milliseconds
    end
    saves.should be >= 3
    acl.arl(1_u8).should be_empty
    updated.size.should eq(1)
    events.should eq([StoredAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
    changed.should eq([StoredAcl::ATTR_ARL])
    acl.complete_restriction_review(1_u8, token).should be_false
    changed.should eq([StoredAcl::ATTR_ARL])
  end

  it "cancels an unanswered review request after a crash during its first save" do
    original = stored_cluster
    requested = [] of StoredAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(original, requested, updated)
    snapshots = [] of Matter::Storage::Document
    original.on_persist = -> { snapshots << original.save_state.as(Matter::Storage::Document); nil }
    token = original.request_restriction_review(1_u8, [stored_entry])
    snapshots.size.should eq(2)

    restored = stored_cluster
    cleaned = [] of Matter::Storage::Document
    restored.on_persist = -> { cleaned << restored.save_state.as(Matter::Storage::Document); nil }
    restored.restore_state(snapshots.first)
    replayed = [] of StoredAcl::RestrictionReviewRequest
    restored_updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(restored, replayed, restored_updates)
    replayed.should be_empty
    restored.complete_restriction_review(1_u8, token).should be_false
    cleaned.size.should eq(1)
    restored.request_restriction_review(1_u8, [stored_entry]).should be > token
  end

  it "replays a durable completion after a crash before its host update" do
    original = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    requested = [] of StoredAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    stored_callbacks(original, requested, updated)
    token = original.request_restriction_review(1_u8, [stored_entry])
    snapshots = [] of Matter::Storage::Document
    original.on_persist = -> { snapshots << original.save_state.as(Matter::Storage::Document); nil }
    original.approve_restriction_review(1_u8, token, [stored_entry], "Approved").should be_true
    snapshots.size.should eq(2)

    restored = StoredAcl.new(endpoint(0), StoredAcl::Feature::ManagedDevice)
    restored.on_persist = -> { snapshots << restored.save_state.as(Matter::Storage::Document); nil }
    restored.restore_state(snapshots.first)
    restored.arl(1_u8).first.restrictions.should eq(stored_entry.restrictions)
    resumed_requests = [] of StoredAcl::RestrictionReviewRequest
    resumed_updates = [] of Tuple(UInt8, StoredAcl::FabricRestrictionReviewUpdate)
    events = [] of UInt32
    restored.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, _fabric : UInt8?) { events << id; nil }
    stored_callbacks(restored, resumed_requests, resumed_updates)
    resumed_requests.should be_empty
    resumed_updates.map(&.[1].token).should eq([token])
    resumed_updates.map(&.[1].instruction).should eq(["Approved"])
    events.should eq([StoredAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
    restored.complete_restriction_review(1_u8, token).should be_false
  end
end
