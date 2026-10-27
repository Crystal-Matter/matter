# Thermostat Matter Schedules

`Cluster::Thermostat` supports the Matter 1.6 MSCH feature when the host supplies
local civil time and configures schedule types before exposing the endpoint.
The clock callback may return `nil` until the device has trustworthy time. It
must return time in the device's intended local timezone, including any daylight
saving offset; a UTC clock is suitable only when UTC is the intended local zone.

```crystal
alias Thermostat = Matter::Cluster::Thermostat

class ScheduledThermostat < Thermostat
  def initialize(endpoint_id : Matter::DataType::EndpointNumber)
    type = ScheduleType.new(SystemMode::Heat, 1_u8,
      ScheduleTypeFeatures::SupportsSetpoints)
    monday_morning = ScheduleTransition.new(0x02_u8, 480_u16,
      nil, nil, nil, 1900_i16)
    schedule = Schedule.new(Bytes[1_u8], SystemMode::Heat,
      nil, nil, [monday_morning], false)
    super(endpoint_id,
      feature_map: Feature::Heating | Feature::MatterSchedules | Feature::Events,
      schedule_types: [type], schedules: [schedule],
      schedule_max_transitions: 2_u8, schedule_max_per_day: 2_u8,
      local_time_provider: -> : Time? { Time.local })
  end
end
```

Construction checks modes, capacities, transition day bitmaps and
minutes, overlaps, setpoint bounds, preset references, and built-in entries.
The schedule types and transition limits determine the advertised fixed
capacity attributes and remain fixed. The host should supply the same profile on every restart
before the device restores its persisted cluster state. `configure_schedules`
can update the host-owned list within those limits. A valid MSCH construction
publishes the Schedules attributes, `AtomicRequest`, and `SetActiveSchedule`.

Controllers use a CASE session with Manage privilege to begin an `AtomicRequest`
for the Schedules attribute, write the list, and commit or roll back. Other
peers see only committed entries until the transaction commits. Activation
selects a committed handle. The device polls the supplied clock once per
second while running. Hosts that advance civil time outside normal polling can
also call `tick_schedule`. A `nil` clock pauses transitions, and the latest
weekly transition is evaluated when time becomes available. During a repeated
daylight saving hour, an earlier wall-clock transition does not undo a later
transition already applied that day.

The committed schedules, used handle history, and active handle persist. After
restart, the first clock evaluation restores the applicable setpoints and mode;
unchanged values do not emit duplicate setpoint events. The host remains
responsible for providing a trustworthy clock, timezone updates, and the
physical heating or cooling actuator. The
[`matter_thermostat_schedules` fixture](../e2e/fixture/matter_thermostat_schedules_device.cr)
exercises the production class with official `chip-tool` in
[`thermostat_schedules_spec.cr`](../e2e/spec/thermostat_schedules_spec.cr).
