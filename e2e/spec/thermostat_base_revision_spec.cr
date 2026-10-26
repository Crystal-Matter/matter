require "./e2e_helper"

describe "Matter 1.6 Thermostat base revision interoperability" do
  device = E2E::Device["matter_thermostat_base_revision"]

  it "reports the revision, features, mandatory attributes, and command for HEAT, COOL, and AUTO" do
    device.commission!

    {
      {1, 0x01_i64, [0x0000_i64, 0x0012_i64, 0x001B_i64, 0x001C_i64], [0x0011_i64, 0x0019_i64]},
      {2, 0x02_i64, [0x0000_i64, 0x0011_i64, 0x001B_i64, 0x001C_i64], [0x0012_i64, 0x0019_i64]},
      {3, 0x23_i64, [0x0000_i64, 0x0011_i64, 0x0012_i64, 0x0019_i64, 0x001B_i64, 0x001C_i64], [] of Int64},
    }.each do |endpoint, features, required, forbidden|
      read_int(device, "thermostat", "cluster-revision", "ClusterRevision", endpoint).should eq(11_i64)
      read_int(device, "thermostat", "feature-map", "FeatureMap", endpoint).should eq(features)
      attributes = expect_success(device.read("thermostat", "attribute-list", endpoint)).int_list("AttributeList")
      required.each { |id| attributes.should contain(id) }
      forbidden.each { |id| attributes.should_not contain(id) }
      expect_success(device.read("thermostat", "accepted-command-list", endpoint))
        .int_list("AcceptedCommandList").should eq([0_i64])
    end
  end
end
