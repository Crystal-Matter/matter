require "./e2e_helper"

module ContentAppE2E
  CATALOG_VENDOR_ID = 0xFFF1_i64
  MESSAGE_ID        = "00112233445546778899aabbccddeeff"
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
end
