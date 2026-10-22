require "./e2e_helper"

describe "Matter 1.6 Low Power interoperability" do
  device = E2E::Device["matter_low_power"]
  request_path = File.join(E2E::LOG_DIR, "matter_low_power.sleep_requests")

  it "commissions, advertises Sleep, and dispatches to the host" do
    device.commission!
    read_int(device, "lowpower", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    expect_success(device.invoke("lowpower", "sleep", endpoint: 1))
    File.read(request_path).should eq("1")
    expect_success(device.invoke("lowpower", "sleep", endpoint: 1))
    File.read(request_path).should eq("2")
    device.restart!
    expect_success(device.invoke("lowpower", "sleep", endpoint: 1))
    File.read(request_path).should eq("1")
  end
end
