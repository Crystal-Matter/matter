require "./e2e_helper"

describe "Matter 1.6 Thermostat User Interface Configuration interoperability" do
  device = E2E::Device["matter_thermostat_ui"]

  it "commissions a thermostat and reads revision 2 preferences" do
    device.commission!
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq(0x0301_i64)
    read_int(device, "thermostatuserinterfaceconfiguration", "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, "thermostatuserinterfaceconfiguration", "temperature-display-mode", "TemperatureDisplayMode", 1).should eq(0_i64)
    read_int(device, "thermostatuserinterfaceconfiguration", "keypad-lockout", "KeypadLockout", 1).should eq(0_i64)
    read_int(device, "thermostatuserinterfaceconfiguration", "schedule-programming-visibility", "ScheduleProgrammingVisibility", 1).should eq(0_i64)
  end

  it "writes valid preferences, rejects invalid enum values, and persists after restart" do
    expect_success(device.write("thermostatuserinterfaceconfiguration", "temperature-display-mode", 1, 1))
    expect_success(device.write("thermostatuserinterfaceconfiguration", "keypad-lockout", 3, 1))
    expect_success(device.write("thermostatuserinterfaceconfiguration", "schedule-programming-visibility", 1, 1))
    expect_failure(device.write("thermostatuserinterfaceconfiguration", "keypad-lockout", 6, 1), "CONSTRAINT_ERROR")
    device.restart!
    read_int(device, "thermostatuserinterfaceconfiguration", "temperature-display-mode", "TemperatureDisplayMode", 1).should eq(1_i64)
    read_int(device, "thermostatuserinterfaceconfiguration", "keypad-lockout", "KeypadLockout", 1).should eq(3_i64)
    read_int(device, "thermostatuserinterfaceconfiguration", "schedule-programming-visibility", "ScheduleProgrammingVisibility", 1).should eq(1_i64)
  end
end
