require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/wi_fi_network_management"

private alias ConsentAcl = Matter::Cluster::AccessControl
private alias ConsentWifi = Matter::Cluster::WiFiNetworkManagement

private def consent_entry : ConsentAcl::AccessRestrictionEntry
  ConsentAcl::AccessRestrictionEntry.new(1_u16, ConsentWifi::CLUSTER_ID, [
    ConsentAcl::AccessRestriction.new(ConsentAcl::AccessRestrictionType::AttributeAccessForbidden,
      ConsentWifi::ATTR_SSID),
  ])
end

private def consent_scoped_entry(fabric : UInt8) : ConsentAcl::AccessRestrictionEntry
  ConsentAcl::AccessRestrictionEntry.new(1_u16, ConsentWifi::CLUSTER_ID,
    consent_entry.restrictions, fabric)
end

private def consent_callbacks(acl : ConsentAcl,
                              requested : Array(ConsentAcl::RestrictionReviewRequest),
                              updated : Array(Tuple(UInt8, ConsentAcl::FabricRestrictionReviewUpdate))) : Nil
  acl.on_restriction_review_requested { |request| requested << request }
  acl.on_restriction_review_updated { |fabric, update| updated << {fabric, update} }
end

describe "Managed restriction host consent" do
  it "keeps policy intact on a fabric-scoped denial and consumes the review token" do
    acl = ConsentAcl.new(endpoint(0))
    acl.configure_access_restrictions(1_u8, [consent_entry])
    requested = [] of ConsentAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, ConsentAcl::FabricRestrictionReviewUpdate)
    consent_callbacks(acl, requested, updated)
    token = acl.request_restriction_review(1_u8, [consent_entry])

    acl.deny_restriction_review(2_u8, token, instruction: "Not approved").should be_false
    acl.arl(1_u8).should eq([consent_scoped_entry(1_u8)])
    acl.deny_restriction_review(1_u8, token, instruction: "Not approved").should be_true
    acl.arl(1_u8).should eq([consent_scoped_entry(1_u8)])
    updated.map(&.[1].token).should eq([token])
    updated.first[1].instruction.should eq("Not approved")
    acl.deny_restriction_review(1_u8, token).should be_false
    acl.feature_map.value.should eq(ConsentAcl::Feature::Extension.value)
  end

  it "applies only the explicitly approved replacement and persists the completed review together" do
    acl = ConsentAcl.new(endpoint(0), ConsentAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [consent_entry])
    acl.configure_access_restrictions(2_u8, [consent_entry])
    requested = [] of ConsentAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, ConsentAcl::FabricRestrictionReviewUpdate)
    consent_callbacks(acl, requested, updated)
    saved = acl.save_state.as(Matter::Storage::Document)
    acl.on_persist = -> do
      saved = acl.save_state.as(Matter::Storage::Document)
      nil
    end
    token = acl.request_restriction_review(1_u8, [consent_entry])
    acl.arl(1_u8).should eq([consent_scoped_entry(1_u8)])

    acl.approve_restriction_review(2_u8, token, [] of ConsentAcl::AccessRestrictionEntry).should be_false
    acl.arl(2_u8).should eq([consent_scoped_entry(2_u8)])
    acl.approve_restriction_review(1_u8, token, [] of ConsentAcl::AccessRestrictionEntry).should be_true
    acl.arl(1_u8).should be_empty
    acl.arl(2_u8).should eq([consent_scoped_entry(2_u8)])
    updated.map(&.[1].token).should eq([token])

    restored = ConsentAcl.new(endpoint(0))
    restored.restore_state(saved)
    restored.arl(1_u8).should be_empty
    restored.arl(2_u8).should eq([consent_scoped_entry(2_u8)])
    restored.data_version.should eq(acl.data_version)
    replayed = [] of ConsentAcl::RestrictionReviewRequest
    later_updates = [] of Tuple(UInt8, ConsentAcl::FabricRestrictionReviewUpdate)
    consent_callbacks(restored, replayed, later_updates)
    replayed.should be_empty
  end

  it "rejects invalid approved policy and rolls back when update delivery fails" do
    acl = ConsentAcl.new(endpoint(0))
    acl.configure_access_restrictions(1_u8, [consent_entry])
    requested = [] of ConsentAcl::RestrictionReviewRequest
    acl.on_restriction_review_requested { |request| requested << request }
    acl.on_restriction_review_updated { |_fabric, _update| raise Matter::ConfigurationError.new("delivery failed") }
    token = acl.request_restriction_review(1_u8, [consent_entry])

    expect_raises(Matter::ConfigurationError) do
      acl.approve_restriction_review(1_u8, token, [
        ConsentAcl::AccessRestrictionEntry.new(0_u16, ConsentWifi::CLUSTER_ID,
          consent_entry.restrictions),
      ])
    end
    acl.arl(1_u8).should eq([consent_scoped_entry(1_u8)])
    expect_raises(Matter::ConfigurationError) do
      acl.approve_restriction_review(1_u8, token, [] of ConsentAcl::AccessRestrictionEntry)
    end
    acl.arl(1_u8).should eq([consent_scoped_entry(1_u8)])
    acl.on_restriction_review_updated { |_fabric, _update| }
    acl.approve_restriction_review(1_u8, token, [] of ConsentAcl::AccessRestrictionEntry).should be_true
    acl.arl(1_u8).should be_empty
  end

  it "publishes interim instructions without consuming the token or changing policy" do
    acl = ConsentAcl.new(endpoint(0), ConsentAcl::Feature::ManagedDevice)
    acl.configure_access_restrictions(1_u8, [consent_entry])
    requested = [] of ConsentAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, ConsentAcl::FabricRestrictionReviewUpdate)
    consent_callbacks(acl, requested, updated)
    token = acl.request_restriction_review(1_u8, [consent_entry])

    acl.publish_restriction_review_update(2_u8, token, instruction: "Review underway").should be_false
    expect_raises(Matter::ConfigurationError) do
      acl.publish_restriction_review_update(1_u8, token, instruction: "x" * 513)
    end
    acl.publish_restriction_review_update(1_u8, token,
      instruction: "Review underway", arl_request_flow_url: "https://example.test/consent").should be_true
    acl.arl(1_u8).should eq([consent_scoped_entry(1_u8)])
    updated.map(&.[1].token).should eq([token])
    acl.deny_restriction_review(1_u8, token, instruction: "Not approved").should be_true
    updated.map(&.[1].token).should eq([token, token])
  end

  it "keeps pending consent and the old ARL when its final save fails" do
    acl = ConsentAcl.new(endpoint(0))
    acl.configure_access_restrictions(1_u8, [consent_entry])
    requested = [] of ConsentAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, ConsentAcl::FabricRestrictionReviewUpdate)
    consent_callbacks(acl, requested, updated)
    token = acl.request_restriction_review(1_u8, [consent_entry])
    before_version = acl.data_version
    acl.on_persist = -> { raise Matter::StorageError.new("save failed") }

    expect_raises(Matter::StorageError) do
      acl.approve_restriction_review(1_u8, token, [] of ConsentAcl::AccessRestrictionEntry)
    end
    acl.arl(1_u8).should eq([consent_scoped_entry(1_u8)])
    acl.data_version.should eq(before_version)
    acl.on_persist = nil
    acl.deny_restriction_review(1_u8, token).should be_true
  end
end
