require "./e2e_helper"

private TARIFF_CLUSTER           = "commoditytariff"
private TARIFF_ENDPOINT          = 1
private FRIENDLY_CREDIT_ENDPOINT = 2

private def refresh_friendly_credit(at : UInt32) : Nil
  trigger = File.join(E2E::LOG_DIR, "matter_commodity_tariff.trigger")
  ack = "#{trigger}.ack"
  File.delete(ack) if File.exists?(ack)
  nonce = "refresh:#{at}:#{Time.utc.to_unix_ms}"
  File.write("#{trigger}.tmp", nonce)
  File.rename("#{trigger}.tmp", trigger)
  deadline = Time.instant + 10.seconds
  until File.exists?(ack) && File.read(ack) == nonce
    raise "Commodity Tariff host did not acknowledge refresh" if Time.instant >= deadline
    sleep 100.milliseconds
  end
end

describe "Matter 1.6 Commodity Tariff interoperability" do
  device = E2E::Device["matter_commodity_tariff"]

  it "commissions and reads the published Pricing calendar" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", TARIFF_ENDPOINT)).int_list("ServerList").should contain(0x0700_i64)
    read_int(device, TARIFF_CLUSTER, "cluster-revision", "ClusterRevision", TARIFF_ENDPOINT).should eq(1_i64)
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", TARIFF_ENDPOINT).should eq(1_i64)
    expect_success(device.read(TARIFF_CLUSTER, "tariff-info", TARIFF_ENDPOINT)).output.should contain("Daily energy")
    expect_success(device.read(TARIFF_CLUSTER, "day-entries", TARIFF_ENDPOINT)).output.should contain("DayEntryID")
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", TARIFF_ENDPOINT)).output.should contain("Energy")
  end

  it "serves both required lookup commands and restores the tariff" do
    day = expect_success(device.invoke(TARIFF_CLUSTER, "get-day-entry", ["1"], endpoint: TARIFF_ENDPOINT))
    day.output.should contain("GetDayEntryResponse")
    component = expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"], endpoint: TARIFF_ENDPOINT))
    component.output.should contain("GetTariffComponentResponse")
    component.output.should contain("Daily")
    device.restart!
    expect_success(device.read(TARIFF_CLUSTER, "tariff-info", TARIFF_ENDPOINT)).output.should contain("Daily energy")
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", TARIFF_ENDPOINT)).output.should contain("Energy")
  end

  it "projects FriendlyCredit entry and exit on an opt-in endpoint and retains the published tariff" do
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", FRIENDLY_CREDIT_ENDPOINT).should eq(3_i64)
    refresh_friendly_credit(100_u32)
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", FRIENDLY_CREDIT_ENDPOINT))
      .bool("FriendlyCredit").should be_true
    expect_success(device.read(TARIFF_CLUSTER, "next-tariff-components", FRIENDLY_CREDIT_ENDPOINT))
      .bool("FriendlyCredit").should be_false
    entry = expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: FRIENDLY_CREDIT_ENDPOINT))
    entry.bool("FriendlyCredit").should be_true
    refresh_friendly_credit(43_200_u32)
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", FRIENDLY_CREDIT_ENDPOINT))
      .bool("FriendlyCredit").should be_false
    device.restart!
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", FRIENDLY_CREDIT_ENDPOINT).should eq(3_i64)
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: FRIENDLY_CREDIT_ENDPOINT)).bool("FriendlyCredit").should be_true
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["2"],
      endpoint: FRIENDLY_CREDIT_ENDPOINT)).bool("FriendlyCredit").should be_false
  end
end
