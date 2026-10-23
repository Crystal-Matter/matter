require "./e2e_helper"

private TARIFF_CLUSTER  = "commoditytariff"
private TARIFF_ENDPOINT = 1

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
end
