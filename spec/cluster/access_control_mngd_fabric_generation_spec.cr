require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/wi_fi_network_management"

private alias GenerationAcl = Matter::Cluster::AccessControl
private alias GenerationWifi = Matter::Cluster::WiFiNetworkManagement

private def generation_entry(type : GenerationAcl::AccessRestrictionType) : GenerationAcl::AccessRestrictionEntry
  GenerationAcl::AccessRestrictionEntry.new(1_u16, GenerationWifi::CLUSTER_ID, [
    GenerationAcl::AccessRestriction.new(type, GenerationWifi::ATTR_SSID),
  ])
end

describe "Managed restriction fabric generation" do
  it "cancels a request paused in its callback when its fabric index is reused" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    replacement = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    started = Channel(Nil).new
    resume = Channel(Nil).new
    finished = Channel(Exception?).new
    acl.on_restriction_review_requested do |_request|
      started.send(nil)
      resume.receive
    end
    acl.on_restriction_review_updated { |_fabric, _update| }
    spawn do
      acl.request_restriction_review(1_u8, [generation_entry(GenerationAcl::AccessRestrictionType::AttributeAccessForbidden)])
      finished.send(nil)
    rescue ex
      finished.send(ex)
    end
    started.receive
    acl.remove_fabric_acl(1_u8)
    acl.configure_access_restrictions(1_u8, [replacement])
    resume.send(nil)
    finished.receive.should be_a(Matter::ConfigurationError)
    acl.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
  end

  it "does not restore the removed fabric's policy after its completion callback fails" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    old_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeAccessForbidden)
    new_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    acl.configure_access_restrictions(1_u8, [old_policy])
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [old_policy])
    acl.on_restriction_review_updated do |_fabric, _update|
      acl.remove_fabric_acl(1_u8)
      acl.configure_access_restrictions(1_u8, [new_policy])
      raise Matter::ConfigurationError.new("old host callback failed")
    end

    expect_raises(Matter::ConfigurationError) do
      acl.approve_restriction_review(1_u8, token, [] of GenerationAcl::AccessRestrictionEntry)
    end
    acl.arl(1_u8).first.restrictions.should eq(new_policy.restrictions)
    acl.complete_restriction_review(1_u8, token).should be_false
  end

  it "does not release a replacement fabric's policy transaction when the old callback exits" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    old_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeAccessForbidden)
    new_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    acl.configure_access_restrictions(1_u8, [old_policy])
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [old_policy])
    callback_started = Channel(Nil).new(1)
    callback_resume = Channel(Nil).new(1)
    acl.on_restriction_review_updated do |_fabric, _update|
      callback_started.send(nil)
      callback_resume.receive
      raise Matter::ConfigurationError.new("old callback failed")
    end
    old_outcome = Channel(Exception?).new(1)
    spawn do
      acl.approve_restriction_review(1_u8, token, [] of GenerationAcl::AccessRestrictionEntry)
      old_outcome.send(nil)
    rescue ex
      old_outcome.send(ex)
    end
    callback_started.receive
    acl.remove_fabric_acl(1_u8)

    persist_started = Channel(Nil).new(1)
    persist_resume = Channel(Nil).new(1)
    pause_next_persist = true
    acl.on_persist = -> do
      if pause_next_persist
        pause_next_persist = false
        persist_started.send(nil)
        persist_resume.receive
      end
      nil
    end
    new_outcome = Channel(Exception?).new(1)
    spawn do
      acl.configure_access_restrictions(1_u8, [new_policy])
      new_outcome.send(nil)
    rescue ex
      new_outcome.send(ex)
    end
    persist_started.receive
    callback_resume.send(nil)
    old_outcome.receive.should be_a(Matter::ConfigurationError)
    expect_raises(Matter::ConfigurationError, /already in progress/) do
      acl.configure_access_restrictions(1_u8, [old_policy])
    end
    persist_resume.send(nil)
    new_outcome.receive.should be_nil
    acl.arl(1_u8).first.restrictions.should eq(new_policy.restrictions)
  end

  it "does not persist a replacement fabric's provisional policy from an obsolete callback" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    old_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeAccessForbidden)
    new_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    acl.configure_access_restrictions(1_u8, [old_policy])
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [old_policy])
    callback_started = Channel(Nil).new(1)
    callback_resume = Channel(Nil).new(1)
    acl.on_restriction_review_updated do |_fabric, _update|
      callback_started.send(nil)
      callback_resume.receive
      raise Matter::ConfigurationError.new("old callback failed")
    end
    old_outcome = Channel(Exception?).new(1)
    spawn do
      acl.approve_restriction_review(1_u8, token, [] of GenerationAcl::AccessRestrictionEntry)
      old_outcome.send(nil)
    rescue ex
      old_outcome.send(ex)
    end
    callback_started.receive
    acl.remove_fabric_acl(1_u8)
    saved = acl.save_state.as(Matter::Storage::Document)

    persist_started = Channel(Nil).new(1)
    persist_resume = Channel(Nil).new(1)
    persist_calls = 0
    acl.on_persist = -> do
      persist_calls += 1
      if acl.arl(1_u8).first?.try(&.restrictions) == new_policy.restrictions
        persist_started.send(nil)
        persist_resume.receive
        raise Matter::StorageError.new("replacement persist failed")
      end
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    new_outcome = Channel(Exception?).new(1)
    spawn do
      acl.configure_access_restrictions(1_u8, [new_policy])
      new_outcome.send(nil)
    rescue ex
      new_outcome.send(ex)
    end
    persist_started.receive
    callback_resume.send(nil)
    old_outcome.receive.should be_a(Matter::ConfigurationError)
    persist_resume.send(nil)
    new_outcome.receive.should be_a(Matter::StorageError)
    persist_calls.should eq(4)
    acl.arl(1_u8).should be_empty

    restored = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.arl(1_u8).should be_empty
  end

  it "does not save a replacement policy from an obsolete request callback" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    old_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeAccessForbidden)
    new_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    request_started = Channel(Nil).new(1)
    request_resume = Channel(Nil).new(1)
    acl.on_restriction_review_requested do |_request|
      request_started.send(nil)
      request_resume.receive
    end
    acl.on_restriction_review_updated { |_fabric, _update| }
    request_outcome = Channel(Exception?).new(1)
    spawn do
      acl.request_restriction_review(1_u8, [old_policy])
      request_outcome.send(nil)
    rescue ex
      request_outcome.send(ex)
    end
    request_started.receive
    acl.remove_fabric_acl(1_u8)
    saved = acl.save_state.as(Matter::Storage::Document)
    persist_started = Channel(Nil).new(1)
    persist_resume = Channel(Nil).new(1)
    acl.on_persist = -> do
      if acl.arl(1_u8).first?.try(&.restrictions) == new_policy.restrictions
        persist_started.send(nil)
        persist_resume.receive
        raise Matter::StorageError.new("replacement persist failed")
      end
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    replacement_outcome = Channel(Exception?).new(1)
    spawn do
      acl.configure_access_restrictions(1_u8, [new_policy])
      replacement_outcome.send(nil)
    rescue ex
      replacement_outcome.send(ex)
    end
    persist_started.receive
    request_resume.send(nil)
    request_outcome.receive.should be_a(Matter::ConfigurationError)
    persist_resume.send(nil)
    replacement_outcome.receive.should be_a(Matter::StorageError)
    restored = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.arl(1_u8).should be_empty
  end

  it "finishes a snapshotted write before removing and reusing its fabric index" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    old_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeAccessForbidden)
    replacement = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    saved = acl.save_state.as(Matter::Storage::Document)
    write_started = Channel(Nil).new(1)
    write_resume = Channel(Nil).new(1)
    first_write = true
    acl.on_persist = -> do
      snapshot = acl.save_state.as(Matter::Storage::Document)
      if first_write
        first_write = false
        write_started.send(nil)
        write_resume.receive
      end
      saved = snapshot
      nil
    end
    old_outcome = Channel(Exception?).new(1)
    spawn do
      acl.configure_access_restrictions(1_u8, [old_policy])
      old_outcome.send(nil)
    rescue ex
      old_outcome.send(ex)
    end
    write_started.receive
    replacement_outcome = Channel(Exception?).new(1)
    spawn do
      acl.remove_fabric_acl(1_u8)
      acl.configure_access_restrictions(1_u8, [replacement])
      replacement_outcome.send(nil)
    rescue ex
      replacement_outcome.send(ex)
    end
    Fiber.yield
    write_resume.send(nil)
    old_outcome.receive.should be_nil
    replacement_outcome.receive.should be_nil
    restored = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    restored.on_persist = -> { nil }
    restored.restore_state(saved)
    restored.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
  end

  it "does not emit an interim update paused while a fabric index is reused" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [] of GenerationAcl::AccessRestrictionEntry)
    started = Channel(Nil).new
    resume = Channel(Nil).new
    finished = Channel(Bool).new
    events = [] of UInt8?
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, fabric : UInt8?) { events << fabric; nil }
    acl.on_restriction_review_updated do |_fabric, _update|
      started.send(nil)
      resume.receive
    end
    spawn do
      finished.send(acl.publish_restriction_review_update(1_u8, token, instruction: "Old fabric only"))
    end
    started.receive
    acl.remove_fabric_acl(1_u8)
    acl.configure_access_restrictions(1_u8, [generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)])
    resume.send(nil)
    finished.receive.should be_false
    events.should be_empty
  end

  it "drops a completion paused in its callback before a fabric index is reused" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [] of GenerationAcl::AccessRestrictionEntry)
    started = Channel(Nil).new
    resume = Channel(Nil).new
    finished = Channel(Exception?).new
    events = [] of UInt8?
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, fabric : UInt8?) { events << fabric; nil }
    acl.on_restriction_review_updated do |_fabric, _update|
      started.send(nil)
      resume.receive
    end
    spawn do
      acl.complete_restriction_review(1_u8, token)
      finished.send(nil)
    rescue ex
      finished.send(ex)
    end
    started.receive
    acl.remove_fabric_acl(1_u8)
    replacement = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    acl.configure_access_restrictions(1_u8, [replacement])
    resume.send(nil)
    finished.receive.should be_a(Matter::ConfigurationError)
    acl.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
    events.should be_empty
  end

  it "does not resume an old callback after a failed removal restores its token" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice)
    old_policy = generation_entry(GenerationAcl::AccessRestrictionType::AttributeAccessForbidden)
    acl.configure_access_restrictions(1_u8, [old_policy])
    acl.on_restriction_review_requested { |_request| }
    acl.on_restriction_review_updated { |_fabric, _update| }
    token = acl.request_restriction_review(1_u8, [old_policy])
    prior_state = acl.save_state.as(Matter::Storage::Document)
    events = [] of UInt8?
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, fabric : UInt8?) { events << fabric; nil }
    acl.on_restriction_review_updated do |_fabric, _update|
      acl.remove_fabric_acl(1_u8)
      acl.restore_state(prior_state)
    end

    expect_raises(Matter::ConfigurationError) { acl.complete_restriction_review(1_u8, token) }
    events.should be_empty
    acl.arl(1_u8).first.restrictions.should eq(old_policy.restrictions)
  end

  it "cancels an awaiting delivery and its retry when the fabric index is reused" do
    acl = GenerationAcl.new(endpoint(0), GenerationAcl::Feature::ManagedDevice,
      review_delivery_retry_interval: 5.milliseconds)
    acl.on_restriction_review_requested { |_request| }
    callbacks = 0
    acl.on_restriction_review_updated { |_fabric, _update| callbacks += 1 }
    token = acl.request_restriction_review(1_u8, [] of GenerationAcl::AccessRestrictionEntry)
    events = [] of UInt8?
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, fabric : UInt8?) { events << fabric; nil }
    saves = 0
    acl.on_persist = -> do
      saves += 1
      raise Matter::StorageError.new("final save failed") if saves == 2
      nil
    end
    expect_raises(Matter::StorageError) { acl.complete_restriction_review(1_u8, token) }
    events.should eq([1_u8])
    acl.on_persist = nil
    acl.remove_fabric_acl(1_u8)
    replacement = generation_entry(GenerationAcl::AccessRestrictionType::AttributeWriteForbidden)
    acl.configure_access_restrictions(1_u8, [replacement])
    sleep 25.milliseconds
    acl.complete_restriction_review(1_u8, token).should be_false
    callbacks.should eq(1)
    events.should eq([1_u8])
    acl.arl(1_u8).first.restrictions.should eq(replacement.restrictions)
  end
end
