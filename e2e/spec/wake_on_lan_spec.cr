require "./e2e_helper"

describe "synthetic Wake On LAN interoperability" do
  device = E2E::Device["matter_wake_on_lan"]

  it "serves optional fixed addresses through chip-tool before and after restart" do
    device.commission!

    server_list = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_list.should contain(0x0503_i64)
    read_int(device, "wakeonlan", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "wakeonlan", "feature-map", "FeatureMap", 1).should eq(0_i64)

    mac = expect_success(device.read("wakeonlan", "macaddress", 1))
    mac.output.should contain("12345678ABCD")
    ipv6 = expect_success(device.read("wakeonlan", "link-local-address", 1))
    ipv6.output.downcase.should contain("fe800000000000000000000000000001")

    expect_failure(device.read("wakeonlan", "macaddress", 2), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.read("wakeonlan", "link-local-address", 2), "UNSUPPORTED_ATTRIBUTE")

    device.restart!
    expect_success(device.read("wakeonlan", "macaddress", 1)).output.should contain("12345678ABCD")
    expect_success(device.read("wakeonlan", "link-local-address", 1)).output.downcase
      .should contain("fe800000000000000000000000000001")
  end
end
