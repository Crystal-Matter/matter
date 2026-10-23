require "./e2e_helper"

describe "Matter 1.6 Content Control interoperability" do
  device = E2E::Device["matter_content_control"]
  timed = ["--timedInteractionTimeoutMs", "2000"]

  it "commissions a Basic Video Player and changes persisted content policy" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x050F_i64)
    read_int(device, "contentcontrol", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "contentcontrol", "feature-map", "FeatureMap", 1).should eq(12_i64)
    expect_success(device.read("contentcontrol", "enabled")).bool("Enabled").should be_false
    expect_success(device.invoke("mediaplayback", "play")).int("status").should eq(0_i64)
    expect_success(device.invoke("contentcontrol", "enable", options: timed))
    expect_success(device.read("contentcontrol", "enabled")).bool("Enabled").should be_true
    expect_success(device.invoke("contentcontrol", "block-unrated-content"))
    expect_success(device.read("contentcontrol", "block-unrated")).bool("BlockUnrated").should be_true
    read_int(device, "mediaplayback", "current-state", "CurrentState").should eq(2_i64)
    expect_success(device.invoke("mediaplayback", "play")).int("status").should eq(2_i64)
    expect_success(device.invoke("contentcontrol", "set-on-demand-rating-threshold", ["PG"]))
    expect_success(device.read("contentcontrol", "on-demand-rating-threshold")).value("OnDemandRatingThreshold").should eq("PG")

    device.restart!
    expect_success(device.read("contentcontrol", "enabled")).bool("Enabled").should be_true
    expect_success(device.read("contentcontrol", "block-unrated")).bool("BlockUnrated").should be_true
    expect_success(device.read("contentcontrol", "on-demand-rating-threshold")).value("OnDemandRatingThreshold").should eq("PG")
    expect_success(device.invoke("contentcontrol", "disable", options: timed))
    expect_success(device.read("contentcontrol", "enabled")).bool("Enabled").should be_false
  end
end
