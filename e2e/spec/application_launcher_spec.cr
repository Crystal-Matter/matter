require "./e2e_helper"

module ApplicationLauncherE2E
  APP     = %({"catalogVendorID":65521,"applicationID":"crystal.radio"})
  PENDING = %({"catalogVendorID":65521,"applicationID":"pending"})
end

describe "Matter 1.6 Application Launcher interoperability" do
  device = E2E::Device["matter_application_launcher"]

  it "commissions and exposes revision two AP metadata and an endpoint app" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x050C_i64)
    expect_success(device.read("descriptor", "server-list", 2)).int_list("ServerList").should contain(0x050C_i64)
    read_int(device, "applicationlauncher", "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, "applicationlauncher", "feature-map", "FeatureMap", 1).should eq(1_i64)
    read_int(device, "applicationlauncher", "feature-map", "FeatureMap", 2).should eq(0_i64)
    expect_success(device.read("applicationlauncher", "catalog-list", 1)).int_list("CatalogList").should eq([65521_i64])
    expect_failure(device.read("applicationlauncher", "catalog-list", 2), "UNSUPPORTED_ATTRIBUTE")
    expect_success(device.read("applicationlauncher", "current-app", 1)).output.should contain("null")
  end

  it "launches, hides, and stops applications through host callbacks with typed responses" do
    launched = expect_success(device.invoke("applicationlauncher", "launch-app", options: ["--Application", ApplicationLauncherE2E::APP]))
    launched.output.should contain("LauncherResponse")
    launched.int("status").should eq(0_i64)
    expect_success(device.read("applicationlauncher", "current-app", 1)).output.should contain("crystal.radio")
    read_int(device, "applicationbasic", "status", "Status", 2).should eq(1_i64)

    pending = expect_success(device.invoke("applicationlauncher", "launch-app", options: ["--Application", ApplicationLauncherE2E::PENDING]))
    pending.int("status").should eq(3_i64)
    hidden = expect_success(device.invoke("applicationlauncher", "hide-app", options: ["--Application", ApplicationLauncherE2E::APP]))
    hidden.int("status").should eq(0_i64)
    read_int(device, "applicationbasic", "status", "Status", 2).should eq(2_i64)
    expect_success(device.read("applicationlauncher", "current-app", 2)).output.should contain("null")

    launched_local = expect_success(device.invoke("applicationlauncher", "launch-app", endpoint: 2))
    launched_local.int("status").should eq(0_i64)
    expect_success(device.read("applicationlauncher", "current-app", 1)).output.should contain("crystal.radio")
    stopped = expect_success(device.invoke("applicationlauncher", "stop-app", endpoint: 2))
    stopped.int("status").should eq(0_i64)
    read_int(device, "applicationbasic", "status", "Status", 2).should eq(0_i64)
    expect_success(device.read("applicationlauncher", "current-app", 1)).output.should contain("null")

    device.restart!
    expect_success(device.read("applicationlauncher", "catalog-list", 1)).int_list("CatalogList").should eq([65521_i64])
  end
end
