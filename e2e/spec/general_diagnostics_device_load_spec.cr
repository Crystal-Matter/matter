require "./e2e_helper"

describe "Matter 1.6 General Diagnostics device load" do
  device = E2E::Device["matter_level_control"]

  it "commissions with the official chip-tool" do
    device.commission!
  end

  it "reads every mandatory DeviceLoadStatus field through chip-tool" do
    result = expect_success(device.read("generaldiagnostics", "device-load-status", 0))
    [
      "CurrentSubscriptions",
      "CurrentSubscriptionsForFabric",
      "TotalSubscriptionsEstablished",
      "TotalInteractionModelMessagesSent",
      "TotalInteractionModelMessagesReceived",
    ].each do |field|
      result.int(field).should_not be_nil, result.output
    end
    result.int("CurrentSubscriptionsForFabric").should eq(0_i64)
    result.int("TotalInteractionModelMessagesReceived").as(Int64).should be >= 1_i64
  end
end
