require "./e2e_helper"

private alias Tariff = Matter::Cluster::CommodityTariff
private TARIFF_CLUSTER           = "commoditytariff"
private TARIFF_ENDPOINT          = 1
private FRIENDLY_CREDIT_ENDPOINT = 2
private PEAK_PERIOD_ENDPOINT     = 3
private AUXILIARY_LOAD_ENDPOINT  = 4
private POWER_THRESHOLD_ENDPOINT = 5

private def refresh_tariffs(at : UInt32) : Nil
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
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", FRIENDLY_CREDIT_ENDPOINT).should eq(2_i64)
    info = expect_success(device.read(TARIFF_CLUSTER, "tariff-info", FRIENDLY_CREDIT_ENDPOINT)).output
    info.should contain("Friendly credit")
    info.should_not contain("Currency")
    expect_success(device.read(TARIFF_CLUSTER, "tariff-unit", FRIENDLY_CREDIT_ENDPOINT))
      .output.downcase.should contain("null")
    refresh_tariffs(100_u32)
    current = expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", FRIENDLY_CREDIT_ENDPOINT))
    current.bool("FriendlyCredit").should be_true
    current.output.should_not contain("Price")
    expect_success(device.read(TARIFF_CLUSTER, "next-tariff-components", FRIENDLY_CREDIT_ENDPOINT))
      .bool("FriendlyCredit").should be_false
    entry = expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: FRIENDLY_CREDIT_ENDPOINT))
    entry.bool("FriendlyCredit").should be_true
    refresh_tariffs(43_200_u32)
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", FRIENDLY_CREDIT_ENDPOINT))
      .bool("FriendlyCredit").should be_false
    device.restart!
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", FRIENDLY_CREDIT_ENDPOINT).should eq(2_i64)
    expect_success(device.read(TARIFF_CLUSTER, "tariff-info", FRIENDLY_CREDIT_ENDPOINT))
      .output.should_not contain("Currency")
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: FRIENDLY_CREDIT_ENDPOINT)).bool("FriendlyCredit").should be_true
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["2"],
      endpoint: FRIENDLY_CREDIT_ENDPOINT)).bool("FriendlyCredit").should be_false
  end

  it "projects PeakPeriod severity and number through reads, lookup, and restart" do
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", PEAK_PERIOD_ENDPOINT).should eq(9_i64)
    refresh_tariffs(100_u32)
    current = expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", PEAK_PERIOD_ENDPOINT))
    current.int("Severity").should eq(Tariff::PeakPeriodSeverity::Low.value.to_i64)
    current.ints("PeakPeriod").should contain(1_i64)
    next_components = expect_success(device.read(TARIFF_CLUSTER, "next-tariff-components", PEAK_PERIOD_ENDPOINT))
    next_components.int("Severity").should eq(Tariff::PeakPeriodSeverity::High.value.to_i64)
    next_components.ints("PeakPeriod").should contain(2_i64)
    entry = expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: PEAK_PERIOD_ENDPOINT))
    entry.ints("PeakPeriod").should contain(1_i64)
    refresh_tariffs(43_200_u32)
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", PEAK_PERIOD_ENDPOINT))
      .ints("PeakPeriod").should contain(2_i64)
    device.restart!
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", PEAK_PERIOD_ENDPOINT).should eq(9_i64)
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: PEAK_PERIOD_ENDPOINT)).ints("PeakPeriod").should contain(1_i64)
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["2"],
      endpoint: PEAK_PERIOD_ENDPOINT)).ints("PeakPeriod").should contain(2_i64)
  end

  it "projects an auxiliary switch setting through reads, lookup, and restart" do
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", AUXILIARY_LOAD_ENDPOINT).should eq(5_i64)
    refresh_tariffs(100_u32)
    current = expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", AUXILIARY_LOAD_ENDPOINT))
    current.int("Number").should eq(1_i64)
    current.int("RequiredState").should eq(Tariff::AuxiliaryLoadSetting::On.value.to_i64)
    next_components = expect_success(device.read(TARIFF_CLUSTER, "next-tariff-components", AUXILIARY_LOAD_ENDPOINT))
    next_components.int("Number").should eq(1_i64)
    next_components.int("RequiredState").should eq(Tariff::AuxiliaryLoadSetting::Off.value.to_i64)
    entry = expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: AUXILIARY_LOAD_ENDPOINT))
    entry.int("RequiredState").should eq(Tariff::AuxiliaryLoadSetting::On.value.to_i64)
    refresh_tariffs(43_200_u32)
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", AUXILIARY_LOAD_ENDPOINT))
      .int("RequiredState").should eq(Tariff::AuxiliaryLoadSetting::Off.value.to_i64)
    device.restart!
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", AUXILIARY_LOAD_ENDPOINT).should eq(5_i64)
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: AUXILIARY_LOAD_ENDPOINT)).int("RequiredState").should eq(Tariff::AuxiliaryLoadSetting::On.value.to_i64)
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["2"],
      endpoint: AUXILIARY_LOAD_ENDPOINT)).int("RequiredState").should eq(Tariff::AuxiliaryLoadSetting::Off.value.to_i64)
  end

  it "projects power and apparent power thresholds through reads, lookup, and restart" do
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", POWER_THRESHOLD_ENDPOINT).should eq(17_i64)
    refresh_tariffs(100_u32)
    current = expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", POWER_THRESHOLD_ENDPOINT))
    current.ints("PowerThreshold").should contain(2_000_i64)
    current.int("PowerThresholdSource").should eq(Tariff::PowerThresholdSource::Contract.value.to_i64)
    next_components = expect_success(device.read(TARIFF_CLUSTER, "next-tariff-components", POWER_THRESHOLD_ENDPOINT))
    next_components.int("ApparentPowerThreshold").should eq(3_000_i64)
    entry = expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: POWER_THRESHOLD_ENDPOINT))
    entry.ints("PowerThreshold").should contain(2_000_i64)
    refresh_tariffs(43_200_u32)
    expect_success(device.read(TARIFF_CLUSTER, "current-tariff-components", POWER_THRESHOLD_ENDPOINT))
      .int("ApparentPowerThreshold").should eq(3_000_i64)
    device.restart!
    read_int(device, TARIFF_CLUSTER, "feature-map", "FeatureMap", POWER_THRESHOLD_ENDPOINT).should eq(17_i64)
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["1"],
      endpoint: POWER_THRESHOLD_ENDPOINT)).ints("PowerThreshold").should contain(2_000_i64)
    expect_success(device.invoke(TARIFF_CLUSTER, "get-tariff-component", ["2"],
      endpoint: POWER_THRESHOLD_ENDPOINT)).int("ApparentPowerThreshold").should eq(3_000_i64)
  end
end
