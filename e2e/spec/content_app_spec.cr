require "./e2e_helper"

module ContentAppE2E
  CATALOG_VENDOR_ID = 0xFFF1_i64
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
end
