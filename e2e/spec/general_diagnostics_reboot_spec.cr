require "./e2e_helper"

describe "Matter 1.6 General Diagnostics reboot durability" do
  device = E2E::Device["matter_level_control"]

  it "increments RebootCount after a commissioned restart" do
    device.commission!
    before = expect_success(device.read("generaldiagnostics", "reboot-count", 0))
      .int("RebootCount").as(Int64)

    device.restart!

    after = expect_success(device.read("generaldiagnostics", "reboot-count", 0))
      .int("RebootCount").as(Int64)
    after.should eq(Math.min(before + 1_i64, UInt16::MAX.to_i64))
  end
end
