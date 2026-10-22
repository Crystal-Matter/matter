require "./e2e_helper"

describe "Matter 1.6 Resource Monitoring family interoperability" do
  device = E2E::Device["matter_resource_monitoring"]

  it "commissions and exposes three independent revision-one cluster identities" do
    device.commission!
    {"hepafiltermonitoring" => 1, "activatedcarbonfiltermonitoring" => 2,
     "watertanklevelmonitoring" => 3}.each do |cluster, endpoint|
      read_int(device, cluster, "cluster-revision", "ClusterRevision", endpoint).should eq(1_i64)
    end
    read_int(device, "hepafiltermonitoring", "feature-map", "FeatureMap", 1).should eq(7_i64)
    read_int(device, "activatedcarbonfiltermonitoring", "feature-map", "FeatureMap", 2).should eq(3_i64)
    read_int(device, "watertanklevelmonitoring", "feature-map", "FeatureMap", 3).should eq(0_i64)
    expect_success(device.read("hepafiltermonitoring", "replacement-product-list", 1)).output
      .should contain("123456789012")
    expect_success(device.read("hepafiltermonitoring", "in-place-indicator", 1)).bool("InPlaceIndicator").should be_true
    expect_failure(device.read("watertanklevelmonitoring", "condition", 3), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.read("activatedcarbonfiltermonitoring", "last-changed-time", 2), "UNSUPPORTED_ATTRIBUTE")
  end

  it "resets downward and upward resources and rejects the absent optional command" do
    read_int(device, "hepafiltermonitoring", "condition", "Condition", 1).should eq(10_i64)
    read_int(device, "activatedcarbonfiltermonitoring", "condition", "Condition", 2).should eq(90_i64)
    expect_success(device.invoke("hepafiltermonitoring", "reset-condition", endpoint: 1))
    expect_success(device.invoke("activatedcarbonfiltermonitoring", "reset-condition", endpoint: 2))
    read_int(device, "hepafiltermonitoring", "condition", "Condition", 1).should eq(100_i64)
    read_int(device, "activatedcarbonfiltermonitoring", "condition", "Condition", 2).should eq(0_i64)
    read_int(device, "hepafiltermonitoring", "change-indication", "ChangeIndication", 1).should eq(0_i64)
    read_int(device, "activatedcarbonfiltermonitoring", "change-indication", "ChangeIndication", 2).should eq(0_i64)
    expect_failure(device.invoke("watertanklevelmonitoring", "reset-condition", endpoint: 3), "UNSUPPORTED_COMMAND")
  end

  it "persists LastChangedTime but resets runtime condition after restart" do
    expect_success(device.write("hepafiltermonitoring", "last-changed-time", 123456))
    device.restart!
    read_int(device, "hepafiltermonitoring", "last-changed-time", "LastChangedTime", 1).should eq(123456_i64)
    read_int(device, "hepafiltermonitoring", "condition", "Condition", 1).should eq(10_i64)
    read_int(device, "activatedcarbonfiltermonitoring", "condition", "Condition", 2).should eq(90_i64)
  end
end
