require "./e2e_helper"

private PROFILE_CLUSTER  = "zonemanagement"
private PROFILE_ENDPOINT = 1
private PROFILE_MOTION   = %({"name":"Door","use":0,"vertices":[{"x":0,"y":0},{"x":100,"y":0},{"x":100,"y":100},{"x":0,"y":100}]})
private PROFILE_FOCUS    = %({"name":"Focus","use":2,"vertices":[{"x":0,"y":0},{"x":100,"y":0},{"x":100,"y":100},{"x":0,"y":100}]})
private PROFILE_TRIGGER  = %({"zoneID":0,"initialDuration":2,"augmentationDuration":1,"maxDuration":4,"blindDuration":1,"sensitivity":5})

describe "Matter 1.6 Zone Management optional profiles interoperability" do
  device = E2E::Device["matter_zone_management_profiles"]

  it "commissions and advertises per-zone sensitivity and focus zones" do
    device.commission!
    read_int(device, PROFILE_CLUSTER, "feature-map", "FeatureMap", PROFILE_ENDPOINT).should eq(15_i64)
    expect_failure(device.read(PROFILE_CLUSTER, "sensitivity", PROFILE_ENDPOINT), "UNSUPPORTED_ATTRIBUTE")
    expect_success(device.invoke(PROFILE_CLUSTER, "create-two-dcartesian-zone", [PROFILE_MOTION], endpoint: PROFILE_ENDPOINT))
    expect_failure(device.invoke(PROFILE_CLUSTER, "create-or-update-trigger",
      [%({"zoneID":0,"initialDuration":2,"augmentationDuration":1,"maxDuration":4,"blindDuration":1})],
      endpoint: PROFILE_ENDPOINT), "CONSTRAINT_ERROR")
    expect_success(device.invoke(PROFILE_CLUSTER, "create-or-update-trigger", [PROFILE_TRIGGER], endpoint: PROFILE_ENDPOINT))
    expect_success(device.read(PROFILE_CLUSTER, "triggers", PROFILE_ENDPOINT)).output.should contain("Sensitivity: 5")
    expect_success(device.invoke(PROFILE_CLUSTER, "create-two-dcartesian-zone", [PROFILE_FOCUS], endpoint: PROFILE_ENDPOINT))
    expect_success(device.read(PROFILE_CLUSTER, "zones", PROFILE_ENDPOINT)).output.should contain("Focus")
    device.restart!
    read_int(device, PROFILE_CLUSTER, "feature-map", "FeatureMap", PROFILE_ENDPOINT).should eq(15_i64)
    expect_success(device.read(PROFILE_CLUSTER, "triggers", PROFILE_ENDPOINT)).output.should contain("Sensitivity: 5")
    expect_success(device.read(PROFILE_CLUSTER, "zones", PROFILE_ENDPOINT)).output.should contain("Focus")
  end
end
