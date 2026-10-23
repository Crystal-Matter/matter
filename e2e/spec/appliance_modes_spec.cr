require "./e2e_helper"

describe "Matter 1.6 Dishwasher and Laundry Washer Mode interoperability" do
  device = E2E::Device["matter_appliance_modes"]

  it "commissions and reads the two derived Mode Base clusters" do
    device.commission!
    {"dishwashermode", "laundrywashermode"}.each do |cluster|
      read_int(device, cluster, "cluster-revision", "ClusterRevision", 1).should eq(3_i64)
      read_int(device, cluster, "feature-map", "FeatureMap", 1).should eq(0_i64)
      read_int(device, cluster, "current-mode", "CurrentMode", 1).should eq(0_i64)
      expect_success(device.read(cluster, "supported-modes", 1)).output.should contain("Normal")
    end
  end

  it "returns Mode Base response status for unsupported and supported transitions" do
    {"dishwashermode", "laundrywashermode"}.each do |cluster|
      unsupported = expect_success(device.invoke(cluster, "change-to-mode", ["7"], endpoint: 1))
      unsupported.int("status").should eq(1_i64)
      read_int(device, cluster, "current-mode", "CurrentMode", 1).should eq(0_i64)

      accepted = expect_success(device.invoke(cluster, "change-to-mode", ["1"], endpoint: 1))
      accepted.int("status").should eq(0_i64)
      read_int(device, cluster, "current-mode", "CurrentMode", 1).should eq(1_i64)
    end
    device.restart!
    read_int(device, "dishwashermode", "current-mode", "CurrentMode", 1).should eq(1_i64)
    read_int(device, "laundrywashermode", "current-mode", "CurrentMode", 1).should eq(1_i64)
  end
end
