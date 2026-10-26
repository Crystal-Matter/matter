require "./e2e_helper"

describe "Matter 1.6 Content Control interoperability" do
  device = E2E::Device["matter_content_control"]
  timed = ["--timedInteractionTimeoutMs", "2000"]

  it "commissions a Basic Video Player and changes persisted content policy" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x050F_i64)
    read_int(device, "contentcontrol", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "contentcontrol", "feature-map", "FeatureMap", 1).should eq(143_i64)
    read_int(device, "contentcontrol", "screen-daily-time", "ScreenDailyTime", 1).should eq(3_600_i64)
    before_bonus = read_int(device, "contentcontrol", "remaining-screen-time", "RemainingScreenTime", 1)
    expect_success(device.invoke("contentcontrol", "add-bonus-time", ["5", "wrong"]))
    read_int(device, "contentcontrol", "remaining-screen-time", "RemainingScreenTime", 1).should eq(before_bonus + 5_i64)
    expect_failure(device.invoke("contentcontrol", "reset-pin"), "NEEDS_TIMED_INTERACTION")
    reset = expect_success(device.invoke("contentcontrol", "reset-pin", options: timed))
    pin = reset.output.match(/\bPINCode:\s*['\"]?(\d{6})\b/).try(&.[1]) || ""
    pin.should match(/\A\d{6}\z/)
    device.invoke("contentcontrol", "update-pin", [pin, "123456"], options: timed).success?.should be_true
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
    read_int(device, "contentcontrol", "screen-daily-time", "ScreenDailyTime", 1).should eq(3_600_i64)
    read_int(device, "contentcontrol", "remaining-screen-time", "RemainingScreenTime", 1).should be > 0_i64
    device.invoke("contentcontrol", "update-pin", ["123456", "234567"], options: timed).success?.should be_true
    expect_success(device.read("contentcontrol", "enabled")).bool("Enabled").should be_true
    expect_success(device.read("contentcontrol", "block-unrated")).bool("BlockUnrated").should be_true
    expect_success(device.read("contentcontrol", "on-demand-rating-threshold")).value("OnDemandRatingThreshold").should eq("PG")
    expect_success(device.invoke("contentcontrol", "disable", options: timed))
    expect_success(device.read("contentcontrol", "enabled")).bool("Enabled").should be_false

    expect_success(device.invoke("contentcontrol", "unblock-unrated-content"))
    all_day = %({"timeWindowIndex":null,"dayOfWeek":127,"timePeriod":[{"startHour":0,"startMinute":0,"endHour":23,"endMinute":59}]})
    expect_success(device.invoke("contentcontrol", "set-block-content-time-window", [all_day]))
    expect_success(device.read("contentcontrol", "block-content-time-window")).output.should contain("DayOfWeek: 127")
    expect_success(device.invoke("contentcontrol", "enable", options: timed))
    expect_success(device.invoke("mediaplayback", "play")).int("status").should eq(2_i64)
    device.restart!
    expect_success(device.read("contentcontrol", "block-content-time-window")).output.should contain("DayOfWeek: 127")
    expect_success(device.invoke("mediaplayback", "play")).int("status").should eq(2_i64)
    expect_success(device.invoke("contentcontrol", "remove-block-content-time-window", ["[0]"]))
    expect_success(device.invoke("mediaplayback", "play")).int("status").should eq(0_i64)
    expect_success(device.invoke("mediaplayback", "pause")).int("status").should eq(0_i64)
    before_daily_change = read_int(device, "contentcontrol", "remaining-screen-time", "RemainingScreenTime", 1)
    expect_success(device.invoke("contentcontrol", "set-screen-daily-time", ["120"]))
    read_int(device, "contentcontrol", "screen-daily-time", "ScreenDailyTime", 1).should eq(120_i64)
    read_int(device, "contentcontrol", "remaining-screen-time", "RemainingScreenTime", 1).should eq(before_daily_change)
    device.restart!
    read_int(device, "contentcontrol", "screen-daily-time", "ScreenDailyTime", 1).should eq(120_i64)
    read_int(device, "contentcontrol", "remaining-screen-time", "RemainingScreenTime", 1).should eq(before_daily_change)
  end
end
