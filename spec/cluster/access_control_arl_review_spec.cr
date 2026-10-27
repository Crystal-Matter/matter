require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/wi_fi_network_management"

private alias ReviewAcl = Matter::Cluster::AccessControl
private alias ReviewWifi = Matter::Cluster::WiFiNetworkManagement

private def review_entry
  ReviewAcl::AccessRestrictionEntry.new(1_u16, ReviewWifi::CLUSTER_ID, [
    ReviewAcl::AccessRestriction.new(
      ReviewAcl::AccessRestrictionType::AttributeAccessForbidden, ReviewWifi::ATTR_SSID),
  ])
end

describe "host-managed restriction review lifecycle" do
  it "correlates a fabric-scoped completion with the requested ARL snapshot" do
    acl = ReviewAcl.new(endpoint(0))
    requested = [] of ReviewAcl::RestrictionReviewRequest
    updated = [] of Tuple(UInt8, ReviewAcl::FabricRestrictionReviewUpdate)
    acl.on_restriction_review_requested { |request| requested << request }
    acl.on_restriction_review_updated { |fabric, update| updated << {fabric, update} }
    entries = [review_entry]

    token = acl.request_restriction_review(1_u8, entries)
    entries.clear
    requested.size.should eq(1)
    requested.first.fabric_index.should eq(1_u8)
    requested.first.token.should eq(token)
    requested.first.entries.should eq([review_entry])
    acl.complete_restriction_review(2_u8, token).should be_false
    acl.complete_restriction_review(1_u8, token, instruction: "Ask the host", arl_request_flow_url: "https://example.test/review")
      .should be_true
    updated.map(&.[0]).should eq([1_u8])
    updated.first[1].token.should eq(token)
    updated.first[1].instruction.should eq("Ask the host")
    updated.first[1].arl_request_flow_url.should eq("https://example.test/review")
    decoded = ReviewAcl::FabricRestrictionReviewUpdate.from_tlv(updated.first[1].to_tlv(nil))
    decoded.token.should eq(token)
    decoded.instruction.should eq("Ask the host")
    decoded.arl_request_flow_url.should eq("https://example.test/review")
    acl.complete_restriction_review(1_u8, token).should be_false
    acl.feature_map.value.should eq(ReviewAcl::Feature::Extension.value)
  end

  it "accepts a generic empty-list request and rejects invalid payloads atomically" do
    acl = ReviewAcl.new(endpoint(0))
    requested = [] of ReviewAcl::RestrictionReviewRequest
    acl.on_restriction_review_requested { |request| requested << request }
    acl.on_restriction_review_updated { |_, _| }
    token = acl.request_restriction_review(1_u8, [] of ReviewAcl::AccessRestrictionEntry)
    requested.first.entries.should be_empty

    expect_raises(Matter::ConfigurationError) do
      acl.request_restriction_review(1_u8, [
        ReviewAcl::AccessRestrictionEntry.new(1_u16, ReviewWifi::CLUSTER_ID,
          [] of ReviewAcl::AccessRestriction),
      ])
    end
    requested.size.should eq(1)
    expect_raises(Matter::ConfigurationError) do
      acl.complete_restriction_review(1_u8, token, instruction: "x" * 513)
    end
    expect_raises(Matter::ConfigurationError) do
      acl.complete_restriction_review(1_u8, token, arl_request_flow_url: "x" * 257)
    end
    acl.on_restriction_review_updated { |_, _| raise Matter::ConfigurationError.new("host delivery failed") }
    expect_raises(Matter::ConfigurationError) do
      acl.complete_restriction_review(1_u8, token)
    end
    acl.on_restriction_review_updated { |_, _| }
    acl.complete_restriction_review(1_u8, token).should be_true
  end

  it "emits a correlated completion by the one-hour deadline and cancels removed fabrics" do
    acl = ReviewAcl.new(endpoint(0), review_timeout: 5.milliseconds)
    updates = Channel(Tuple(UInt8, ReviewAcl::FabricRestrictionReviewUpdate)).new
    acl.on_restriction_review_requested { |_| }
    acl.on_restriction_review_updated { |fabric, update| updates.send({fabric, update}) }

    timed_token = acl.request_restriction_review(1_u8, [review_entry])
    fabric, update = updates.receive
    fabric.should eq(1_u8)
    update.token.should eq(timed_token)
    acl.complete_restriction_review(1_u8, timed_token).should be_false

    removed_token = acl.request_restriction_review(2_u8, [review_entry])
    acl.remove_fabric_acl(2_u8)
    acl.complete_restriction_review(2_u8, removed_token).should be_false
    select
    when updates.receive
      fail("Removed fabric emitted a restriction review update")
    when timeout(25.milliseconds)
    end
  end

  it "cancels the deadline timer after an early host completion" do
    acl = ReviewAcl.new(endpoint(0), review_timeout: 5.milliseconds)
    updates = [] of ReviewAcl::FabricRestrictionReviewUpdate
    acl.on_restriction_review_requested { |_| }
    acl.on_restriction_review_updated { |_, update| updates << update }

    token = acl.request_restriction_review(1_u8, [review_entry])
    acl.complete_restriction_review(1_u8, token).should be_true
    sleep 25.milliseconds
    updates.map(&.token).should eq([token])
  end

  it "retries a deadline update after a transient host callback failure" do
    acl = ReviewAcl.new(endpoint(0), review_timeout: 5.milliseconds,
      review_delivery_retry_interval: 5.milliseconds)
    attempts = 0
    updates = [] of ReviewAcl::FabricRestrictionReviewUpdate
    acl.on_restriction_review_requested { |_| }
    acl.on_restriction_review_updated do |_fabric, update|
      attempts += 1
      raise Matter::ConfigurationError.new("host temporarily unavailable") if attempts == 1
      updates << update
    end

    token = acl.request_restriction_review(1_u8, [review_entry])
    40.times do
      break unless updates.empty?
      sleep 5.milliseconds
    end
    attempts.should be >= 2
    updates.map(&.token).should eq([token])
    acl.complete_restriction_review(1_u8, token).should be_false
  end
end
