require "./e2e_helper"

describe "Matter 1.6 Diagnostic Logs interoperability" do
  device = E2E::Device["matter_switch"]
  bdx_designator = "e2e-diagnostic-log"
  bdx_file = "/tmp/#{bdx_designator}"

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

  it "downloads a large diagnostic log by BDX after chip-tool accepts SendInit" do
    device.commission!
    File.delete(bdx_file) if File.exists?(bdx_file)

    log_path = File.join(E2E::LOG_DIR, "diagnostic-logs-bdx-chip-tool.log")
    File.open(log_path, "w") do |log|
      process = Process.new(E2E::CHIP_TOOL,
        ["interactive", "start", "--storage-directory", device.storage_dir],
        input: Process::Redirect::Pipe, output: log, error: log)
      begin
        process.input.puts("diagnosticlogs retrieve-logs-request 0 1 #{device.node} 0 --TransferFileDesignator #{bdx_designator}")
        process.input.flush
        deadline = Time.instant + 20.seconds
        expected_content = "E2E BDX diagnostic log " + "L" * 1100
        until File.exists?(bdx_file) && File.read(bdx_file).includes?(expected_content) &&
              File.read(log_path).includes?("OnTransferEnd")
          if Time.instant >= deadline
            raise "BDX diagnostic log was not downloaded to #{bdx_file}:\n#{E2E.strip_ansi(File.read(log_path)).lines.last(80).join}"
          end
          sleep 100.milliseconds
        end
        output = E2E.strip_ansi(File.read(log_path))
        output.should contain("BDX:SendInit")
        output.should contain("BDX:SendAccept")
        output.should contain("RetrieveLogsResponse")
        output.should contain("OnTransferData")
      ensure
        process.terminate rescue nil
        process.wait rescue nil
      end
    end

    denied = expect_success(device.invoke("diagnosticlogs", "retrieve-logs-request",
      ["0", "1"], endpoint: 0,
      options: ["--TransferFileDesignator", "Error:OnTransferBegin"]))
    denied.int("status").should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Denied.value.to_i64)
  end
end
