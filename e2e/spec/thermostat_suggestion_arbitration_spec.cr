require "./e2e_helper"

describe "Matter Thermostat Suggestions schedule and occupancy fixture" do
  device = E2E::Device["matter_thermostat_suggestion_arbitration"]
  clock_path = File.join(E2E::LOG_DIR, "matter_thermostat_suggestion_arbitration.clock")
  occupancy_path = File.join(E2E::LOG_DIR, "matter_thermostat_suggestion_arbitration.occupancy")

  it "keeps the selected suggestion visible while a schedule controls occupied and unoccupied setpoints" do
    File.write(clock_path, Time.utc(2026, 10, 26, 7, 59).to_unix.to_s)
    File.write(occupancy_path, "1")
    device.commission!
    utc_microseconds = (Time.utc.to_unix - Matter::Cluster::Thermostat::MATTER_EPOCH_UNIX_SECONDS).to_u64 * 1_000_000_u64
    expect_success(device.invoke("timesynchronization", "set-utctime", [utc_microseconds.to_s, "4"], endpoint: 0))
    added = expect_success(device.chip("thermostat", "add-thermostat-suggestion", "hex:01", "null", "30", device.node, "1"))
    id = added.value("uniqueID") || raise "AddThermostatSuggestionResponse lacks uniqueID: #{added.tail}"
    begin
      expect_success(device.chip("thermostat", "set-active-schedule-request", "hex:03", device.node, "1"))
      File.write(clock_path, Time.utc(2026, 10, 26, 8, 0).to_unix.to_s)
      sleep 2.seconds
      expect_success(device.read("thermostat", "current-thermostat-suggestion", 1)).output.should contain("01")
      expect_success(device.read("thermostat", "active-preset-handle", 1)).output.should contain("02")
      read_int(device, "thermostat", "thermostat-suggestion-not-following-reason",
        "ThermostatSuggestionNotFollowingReason", 1).should eq(4_i64)
      read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2100_i64)

      File.write(occupancy_path, "0")
      sleep 2.seconds
      read_int(device, "thermostat", "unoccupied-heating-setpoint", "UnoccupiedHeatingSetpoint", 1).should eq(2100_i64)
      expect_success(device.read("thermostat", "active-preset-handle", 1)).output.should contain("02")

      File.write(clock_path, Time.utc(2026, 10, 26, 9, 0).to_unix.to_s)
      sleep 2.seconds
      expect_success(device.read("thermostat", "active-preset-handle", 1)).output.should contain("01")
      expect_success(device.read("thermostat", "thermostat-suggestion-not-following-reason", 1))
        .output.downcase.should contain("null")
      read_int(device, "thermostat", "unoccupied-heating-setpoint", "UnoccupiedHeatingSetpoint", 1).should eq(1900_i64)
    ensure
      expect_success(device.chip("thermostat", "remove-thermostat-suggestion", id.split(/\s+/).first, device.node, "1"))
      File.delete?(clock_path)
      File.delete?(occupancy_path)
    end
  end
end
