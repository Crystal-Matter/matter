require "./e2e_helper"

describe "Matter 1.6 Laundry Controls interoperability" do
  device = E2E::Device["matter_laundry_combo"]

  it "commissions a washer-dryer combo with both control clusters" do
    device.commission!
    servers = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    servers.should contain(0x004A_i64)
    servers.should contain(0x0053_i64)
    read_int(device, "laundrydryercontrols", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "laundrywashercontrols", "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, "laundrywashercontrols", "feature-map", "FeatureMap", 1).should eq(3_i64)
    expect_success(device.read("laundrydryercontrols", "supported-dryness-levels", 1))
    expect_success(device.read("laundrywashercontrols", "spin-speeds", 1)).output.should contain("Standard")
    expect_success(device.read("laundrywashercontrols", "supported-rinses", 1))
    read_int(device, "laundrydryercontrols", "selected-dryness-level", "SelectedDrynessLevel", 1).should eq(1_i64)
    read_int(device, "laundrywashercontrols", "spin-speed-current", "SpinSpeedCurrent", 1).should eq(1_i64)
    read_int(device, "laundrywashercontrols", "number-of-rinses", "NumberOfRinses", 1).should eq(1_i64)
  end

  it "validates writes through the host and retains accepted settings across restart" do
    expect_failure(device.write("laundrydryercontrols", "selected-dryness-level", 3, 1), "CONSTRAINT_ERROR")
    expect_failure(device.write("laundrydryercontrols", "selected-dryness-level", 0, 1), "INVALID_IN_STATE")
    expect_success(device.write("laundrydryercontrols", "selected-dryness-level", 2, 1))
    expect_failure(device.write("laundrywashercontrols", "spin-speed-current", 4, 1), "CONSTRAINT_ERROR")
    expect_failure(device.write("laundrywashercontrols", "spin-speed-current", 2, 1), "INVALID_IN_STATE")
    expect_success(device.write("laundrywashercontrols", "spin-speed-current", 0, 1))
    expect_failure(device.write("laundrywashercontrols", "number-of-rinses", 3, 1), "CONSTRAINT_ERROR")
    expect_success(device.write("laundrywashercontrols", "number-of-rinses", 2, 1))

    device.restart!
    read_int(device, "laundrydryercontrols", "selected-dryness-level", "SelectedDrynessLevel", 1).should eq(2_i64)
    read_int(device, "laundrywashercontrols", "spin-speed-current", "SpinSpeedCurrent", 1).should eq(0_i64)
    read_int(device, "laundrywashercontrols", "number-of-rinses", "NumberOfRinses", 1).should eq(2_i64)
  end
end
