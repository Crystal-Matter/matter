# Pump Configuration and Control (Matter 1.6)

`Cluster::PumpConfigurationControl` implements revision 5 of cluster `0x0200`.
The default is the existing ConstantSpeed (`SPD`, bit 3) profile. A host may
select any combination of constant pressure (`PRSCONST`), compensated pressure
(`PRSCOMP`), constant flow (`FLW`), constant speed (`SPD`), and constant
temperature (`TEMP`), with optional Automatic (`AUTO`) and LocalOperation
(`LOCAL`). At least one regulation feature is required. The constructor chooses
the first advertised regulation mode as the initial ControlMode, preferring
speed when present; a host can supply another supported mode explicitly.
The feature map is fixed after construction so an existing requested or
effective mode cannot lose its backing capability.

The server exposes mandatory MaxPressure, MaxSpeed, MaxFlow,
EffectiveOperationMode, EffectiveControlMode, Capacity, and OperationMode,
plus the configured profile's Min/Max limits. It also exposes
ControlMode, PumpStatus, Speed, and the lifetime/power attributes. Fixed limits
can be `null` when the host has no reliable capability value. Lifetime
RunningHours and EnergyConsumed, OperationMode and ControlMode use Manage
privilege for writes; the requested modes and lifetime counters persist.

A remote write calls the host's `on_apply_mode` callback. With no callback,
the server returns `INVALID_IN_STATE`. Unsupported feature modes return
`CONSTRAINT_ERROR`. Minimum and Maximum operation require `SPD`; Local operation
requires `LOCAL`. An accepted request changes the requested mode only; it
does not claim the pump physically changed. The host calls `report_operation`
after observing the current operation, speed, and capacity. This updates the
effective attributes and sends normal attribute change notifications. The
synthetic pump in `examples/matter_pump_device.cr` has separate speed and flow
endpoints for protocol testing.

All 17 optional fault events are available through the `fault_events:` set.
The default empty set preserves the speed-only endpoint's empty event set.
An enabled event is advertised with its Matter 1.6 ID and priority; the host
calls `report_fault(Fault::DryRunning)` (or another enabled fault) when it
observes the condition. Fault events have empty payloads. A production host
must implement the physical regulation and mode transitions and connect its
power, status, lifetime, and fault telemetry. The example is a protocol fixture,
not a pump driver.
