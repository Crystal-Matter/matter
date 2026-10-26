require "./e2e_helper"

describe "Matter Thermostat Schedules guarded fixture" do
  device = E2E::Device["matter_thermostat_schedules"]
  schedule_attribute = "[81]"
  baseline = %([{"scheduleHandle":"hex:01","systemMode":4,"transitions":[{"dayOfWeek":2,"transitionTime":480,"heatingSetpoint":1900}],"builtIn":false}])
  updated = %([{"scheduleHandle":"hex:01","systemMode":4,"transitions":[{"dayOfWeek":2,"transitionTime":480,"heatingSetpoint":2100}],"builtIn":false}])
  clock_path = File.join(E2E::LOG_DIR, "matter_thermostat_schedules.clock")

  it "commissions with the MSCH attributes and refuses an unknown schedule handle" do
    File.delete?(clock_path)
    device.commission!
    read_int(device, "thermostat", "cluster-revision", "ClusterRevision", 1).should eq(9_i64)
    read_int(device, "thermostat", "feature-map", "FeatureMap", 1).should eq(0x281_i64)
    read_int(device, "thermostat", "number-of-schedules", "NumberOfSchedules", 1).should eq(1_i64)
    read_int(device, "thermostat", "number-of-schedule-transitions", "NumberOfScheduleTransitions", 1).should eq(2_i64)
    expect_success(device.read("thermostat", "schedule-types", 1)).output.should contain("ScheduleTypeFeatures")
    expect_success(device.read("thermostat", "schedules", 1)).output.should contain("ScheduleHandle")
    expect_failure(device.chip("thermostat", "set-active-schedule-request", "hex:02", device.node, "1"),
      "INVALID_COMMAND")
  end

  it "rolls back, commits, and activates a schedule through official chip-tool" do
    File.delete?(clock_path)
    # Device storage survives `./test` runs unless --clean was requested.
    expect_success(device.chip("thermostat", "atomic-request", "0", schedule_attribute,
      device.node, "1", "--Timeout", "60000"))
    expect_success(device.write("thermostat", "schedules", baseline, 1))
    expect_success(device.chip("thermostat", "atomic-request", "1", schedule_attribute,
      device.node, "1"))

    expect_success(device.chip("thermostat", "atomic-request", "0", schedule_attribute,
      device.node, "1", "--Timeout", "60000"))
    expect_success(device.write("thermostat", "schedules", updated, 1))
    expect_success(device.chip("thermostat", "atomic-request", "2", schedule_attribute,
      device.node, "1"))
    expect_success(device.read("thermostat", "schedules", 1)).output.should contain("1900")

    expect_success(device.chip("thermostat", "atomic-request", "0", schedule_attribute,
      device.node, "1", "--Timeout", "60000"))
    expect_success(device.write("thermostat", "schedules", updated, 1))
    expect_success(device.chip("thermostat", "atomic-request", "1", schedule_attribute,
      device.node, "1"))
    expect_success(device.read("thermostat", "schedules", 1)).output.should contain("2100")

    expect_success(device.chip("thermostat", "set-active-schedule-request", "hex:01", device.node, "1"))
    expect_success(device.read("thermostat", "active-schedule-handle", 1)).output.should contain("01")
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2100_i64)

    device.restart!
    expect_success(device.read("thermostat", "schedules", 1)).output.should contain("2100")
    expect_success(device.read("thermostat", "active-schedule-handle", 1)).output.should contain("01")
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2100_i64)
  end

  it "applies clock-driven transitions after commissioning and a restart" do
    # The file is a fixture-owned civil clock. No IM command advances it.
    File.write(clock_path, "unavailable")
    device.restart!
    transitions = %([{"scheduleHandle":"hex:01","systemMode":4,"transitions":[{"dayOfWeek":2,"transitionTime":480,"heatingSetpoint":1900},{"dayOfWeek":2,"transitionTime":481,"heatingSetpoint":2200}],"builtIn":false}])
    expect_success(device.chip("thermostat", "atomic-request", "0", schedule_attribute,
      device.node, "1", "--Timeout", "60000"))
    expect_success(device.write("thermostat", "schedules", transitions, 1))
    expect_success(device.chip("thermostat", "atomic-request", "1", schedule_attribute,
      device.node, "1"))
    expect_success(device.chip("thermostat", "set-active-schedule-request", "hex:01", device.node, "1"))
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2100_i64)

    File.write(clock_path, Time.utc(2026, 10, 26, 8, 0).to_unix.to_s)
    sleep 1.5.seconds
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(1900_i64)
    event = expect_success(device.chip("thermostat", "read-event", "setpoint-change", device.node, "1"))
    event.ints("CurrentSetpoint").last.should eq(1900_i64)
    first_event_number = event.ints("Event number").last

    File.write(clock_path, Time.utc(2026, 10, 26, 8, 1).to_unix.to_s)
    sleep 1.5.seconds
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2200_i64)
    event = expect_success(device.chip("thermostat", "read-event", "setpoint-change", device.node, "1"))
    event.ints("CurrentSetpoint").count(1900_i64).should eq(1)
    event.ints("CurrentSetpoint").count(2200_i64).should eq(1)
    event.ints("Event number").last.should eq(first_event_number + 1)
    sleep 1.2.seconds
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2200_i64)
    event = expect_success(device.chip("thermostat", "read-event", "setpoint-change", device.node, "1"))
    event.ints("CurrentSetpoint").count(2200_i64).should eq(1)
    event.ints("Event number").last.should eq(first_event_number + 1)

    device.restart!
    sleep 1.5.seconds
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2200_i64)
    event = expect_success(device.chip("thermostat", "read-event", "setpoint-change", device.node, "1"))
    # The event journal is volatile across restart; unchanged restored state
    # must not generate a replay event when the poller evaluates it again.
    event.ints("CurrentSetpoint").should be_empty
  ensure
    File.delete?(clock_path)
  end
end
