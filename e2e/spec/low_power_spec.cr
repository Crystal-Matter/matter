require "./e2e_helper"

private def await_sleep_request(path : String, expected : String) : Nil
  deadline = Time.monotonic + 2.seconds
  until File.exists?(path) && File.read(path) == expected
    fail "Low Power transition #{expected} did not run after InvokeResponse" if Time.monotonic >= deadline
    sleep 10.milliseconds
  end
end

describe "Matter 1.6 Low Power interoperability" do
  device = E2E::Device["matter_low_power"]
  request_path = File.join(E2E::LOG_DIR, "matter_low_power.sleep_requests")

  it "commissions, advertises Sleep, and dispatches to the host" do
    device.commission!
    read_int(device, "lowpower", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    expect_success(device.invoke("lowpower", "sleep", endpoint: 1))
    await_sleep_request(request_path, "1")
    expect_success(device.invoke("lowpower", "sleep", endpoint: 1))
    await_sleep_request(request_path, "2")
    device.restart!
    expect_success(device.invoke("lowpower", "sleep", endpoint: 1))
    await_sleep_request(request_path, "1")
  end
end
