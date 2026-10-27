require "./e2e_helper"

describe "Matter 1.6 Pump Configuration and Control interoperability" do
  device = E2E::Device["matter_pump"]

  it "commissions a Pump and reads its constant-speed profile" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0200_i64)
    read_int(device, "pumpconfigurationandcontrol", "cluster-revision", "ClusterRevision", 1).should eq(5_i64)
    read_int(device, "pumpconfigurationandcontrol", "feature-map", "FeatureMap", 1).should eq(8_i64)
    read_int(device, "pumpconfigurationandcontrol", "max-speed", "MaxSpeed", 1).should eq(3_600_i64)
    read_int(device, "pumpconfigurationandcontrol", "operation-mode", "OperationMode", 1).should eq(0_i64)
  end

  it "validates requested modes and restores a managed speed setting" do
    expect_failure(device.write("pumpconfigurationandcontrol", "control-mode", 3, 1), "CONSTRAINT_ERROR")
    expect_failure(device.write("pumpconfigurationandcontrol", "operation-mode", 3, 1), "CONSTRAINT_ERROR")
    expect_success(device.write("pumpconfigurationandcontrol", "operation-mode", 1, 1))
    read_int(device, "pumpconfigurationandcontrol", "operation-mode", "OperationMode", 1).should eq(1_i64)
    read_int(device, "pumpconfigurationandcontrol", "effective-operation-mode", "EffectiveOperationMode", 1).should eq(0_i64)
    device.restart!
    read_int(device, "pumpconfigurationandcontrol", "operation-mode", "OperationMode", 1).should eq(1_i64)
  end

  it "commissions a flow pump with automatic and local operation" do
    read_int(device, "pumpconfigurationandcontrol", "feature-map", "FeatureMap", 2).should eq(100_i64)
    read_int(device, "pumpconfigurationandcontrol", "min-const-flow", "MinConstFlow", 2).should eq(20_i64)
    read_int(device, "pumpconfigurationandcontrol", "control-mode", "ControlMode", 2).should eq(3_i64)
    expect_failure(device.write("pumpconfigurationandcontrol", "control-mode", 0, 2), "CONSTRAINT_ERROR")
    expect_failure(device.write("pumpconfigurationandcontrol", "operation-mode", 1, 2), "CONSTRAINT_ERROR")
    expect_success(device.write("pumpconfigurationandcontrol", "control-mode", 7, 2))
    expect_success(device.write("pumpconfigurationandcontrol", "operation-mode", 3, 2))
    device.restart!
    read_int(device, "pumpconfigurationandcontrol", "control-mode", "ControlMode", 2).should eq(7_i64)
    read_int(device, "pumpconfigurationandcontrol", "operation-mode", "OperationMode", 2).should eq(3_i64)
  end
end
