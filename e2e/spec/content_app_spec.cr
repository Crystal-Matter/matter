require "./e2e_helper"

module ContentAppE2E
  CATALOG_VENDOR_ID       = 0xFFF1_i64
  MESSAGE_ID              = "00112233445546778899aabbccddeeff"
  TIMED_MESSAGE_ID        = "102132435465768798a9bacbdcedfe0f"
  TEMP_ACCOUNT_IDENTIFIER = "crystal-radio-user"
  SETUP_PIN               = "12345678"
end

describe "matter_content_app example" do
  device = E2E::Device["matter_content_app"]

  it "commissions a Content App and reads Application Basic through official chip-tool" do
    device.commission!
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq(0x0024_i64)
    read_int(device, "applicationbasic", "cluster-revision", "ClusterRevision").should eq(1)
    expect_success(device.read("applicationbasic", "application-name")).value("ApplicationName").should eq("Crystal Radio")
    application = expect_success(device.read("applicationbasic", "application"))
    application.int("CatalogVendorID").should eq(ContentAppE2E::CATALOG_VENDOR_ID)
    application.value("ApplicationID").should eq("crystal.radio")
    expect_success(device.read("applicationbasic", "application-version")).value("ApplicationVersion").should eq("1.0.0")
    read_int(device, "applicationbasic", "status", "Status").should eq(1)
    expect_success(device.read("applicationbasic", "allowed-vendor-list")).int_list("AllowedVendorList").should eq([ContentAppE2E::CATALOG_VENDOR_ID])

    device.restart!
    read_int(device, "applicationbasic", "status", "Status").should eq(1)
    expect_success(device.read("applicationbasic", "application-name")).value("ApplicationName").should eq("Crystal Radio")
  end

  it "queues, persists, and cancels a fabric-scoped message through official chip-tool" do
    device.commission!
    read_int(device, "messages", "cluster-revision", "ClusterRevision").should eq(3)
    id = ContentAppE2E::MESSAGE_ID
    expect_success(device.invoke("messages", "present-messages-request",
      ["hex:#{id}", "1", "0", "null", "null", "Crystal Radio notice"]))
    expect_success(device.read("messages", "messages")).output.downcase.should contain(id)

    device.restart!
    expect_success(device.read("messages", "messages")).output.downcase.should contain(id)
    expect_success(device.invoke("messages", "cancel-messages-request", ["[\"hex:#{id}\"]"]))
    expect_success(device.read("messages", "messages")).output.should contain("Messages: 0 entries")
  end

  it "expires a duration-limited message and reports completion through official chip-tool" do
    device.commission!
    id = ContentAppE2E::TIMED_MESSAGE_ID
    expect_success(device.invoke("messages", "present-messages-request",
      ["hex:#{id}", "1", "0", "null", "3000", "Expiring notice"]))
    sleep 4.seconds
    expect_success(device.read("messages", "messages")).output.should contain("Messages: 0 entries")
    complete = expect_success(device.chip("messages", "read-event", "message-complete", device.node, "1"))
    complete.output.downcase.should contain(id)
  end

  it "logs into and out of a Content App through timed Account Login commands" do
    device.commission!
    read_int(device, "accountlogin", "cluster-revision", "ClusterRevision").should eq(2)
    timed = ["--timedInteractionTimeoutMs", "2000"]
    identifier = ContentAppE2E::TEMP_ACCOUNT_IDENTIFIER
    expect_failure(device.invoke("accountlogin", "get-setup-pin", [identifier]), "NEEDS_TIMED_INTERACTION")
    response = expect_success(device.invoke("accountlogin", "get-setup-pin", [identifier], options: timed))
    response.value("SetupPIN").should eq(ContentAppE2E::SETUP_PIN)
    mismatch = expect_success(device.invoke("accountlogin", "get-setup-pin", ["different-radio-user"], options: timed))
    mismatch.value("SetupPIN").should eq("")
    expect_success(device.invoke("accountlogin", "login", [identifier, ContentAppE2E::SETUP_PIN], options: timed))
    expect_success(device.invoke("accountlogin", "logout", options: timed))
    logged_out = expect_success(device.chip(["accountlogin", "read-event", "logged-out", device.node, "1"]))
    logged_out.output.should contain("LoggedOut")
  end
end
