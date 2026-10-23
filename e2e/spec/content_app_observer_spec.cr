require "./e2e_helper"

describe "Matter 1.6 Content App Observer interoperability" do
  device = E2E::Device["matter_content_app_observer"]

  it "commissions a Casting Video Client and returns a typed host response" do
    device.commission!
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq(0x0029_i64)
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0510_i64)
    read_int(device, "contentappobserver", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)

    reply = expect_success(device.invoke("contentappobserver", "content-app-message", ["text/plain"],
      options: ["--Data", "ping"]))
    reply.output.should contain("ContentAppMessageResponse")
    reply.int("status").should eq(0_i64)
    reply.value("data").should eq("pong")

    unknown = expect_success(device.invoke("contentappobserver", "content-app-message", ["text/plain"],
      options: ["--Data", "unknown"]))
    unknown.int("status").should eq(1_i64)

    device.restart!
    expect_success(device.invoke("contentappobserver", "content-app-message", ["text/plain"],
      options: ["--Data", "ping"]))
  end
end
