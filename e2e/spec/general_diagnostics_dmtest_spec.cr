require "./e2e_helper"

describe "Matter 1.6 General Diagnostics DMTEST interoperability" do
  device = E2E::Device["matter_diagnostics_dmtest"]
  key = "hex:0102030405060708090a0b0c0d0e0f10"

  it "commissions and advertises the test feature only for the opt-in fixture" do
    device.commission!
    expect_success(device.read("generaldiagnostics", "test-event-triggers-enabled", 0))
      .bool("TestEventTriggersEnabled").should be_true
    expect_success(device.read("generaldiagnostics", "feature-map", 0))
      .int("FeatureMap").should eq(1_i64)
  end

  it "returns the requested repeated-byte payload through official chip-tool" do
    result = expect_success(device.invoke("generaldiagnostics", "payload-test-request",
      [key, "171", "4"], endpoint: 0))
    result.output.should contain("PayloadTestResponse")
    result.output.should contain("Payload")
  end

  it "rejects a mismatched key and count beyond 2048" do
    expect_failure(device.invoke("generaldiagnostics", "payload-test-request",
      ["hex:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "171", "4"], endpoint: 0), "CONSTRAINT_ERROR")
    expect_failure(device.invoke("generaldiagnostics", "payload-test-request",
      [key, "171", "2049"], endpoint: 0), "CONSTRAINT_ERROR")
  end
end
