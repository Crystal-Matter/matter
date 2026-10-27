require "./e2e_helper"

describe "Matter 1.6 Diagnostic Logs interoperability" do
  device = E2E::Device["matter_switch"]

  it "validates BDX designators and returns inline diagnostics through chip-tool" do
    device.commission!

    expect_failure(device.invoke("diagnosticlogs", "retrieve-logs-request",
      ["0", "1"], endpoint: 0), "INVALID_COMMAND")
    expect_failure(device.invoke("diagnosticlogs", "retrieve-logs-request",
      ["0", "1"], endpoint: 0,
      options: ["--TransferFileDesignator", "é" * 17]), "CONSTRAINT_ERROR")

    response = expect_success(device.invoke("diagnosticlogs", "retrieve-logs-request",
      ["1", "0"], endpoint: 0))
    response.output.should contain("RetrieveLogsResponse")
    response.value("logContent").should eq("Network diagnostics: Device operational".to_slice.hexstring.upcase)
  end
end
