# Pump Configuration and Control (Matter 1.6)

`Cluster::PumpConfigurationControl` implements revision 5 of cluster `0x0200`
for the ConstantSpeed (`SPD`, bit 3) profile. The canonical XML requires at
least one of constant pressure, compensated pressure, constant flow, constant
speed, or constant temperature. This implementation accepts ConstantSpeed only.
Other feature maps are rejected at construction so endpoints do not advertise
regulation algorithms they cannot provide.

The server exposes mandatory MaxPressure, MaxSpeed, MaxFlow,
EffectiveOperationMode, EffectiveControlMode, Capacity, and OperationMode,
plus the speed-specific MinConstSpeed and MaxConstSpeed. It also exposes
ControlMode, PumpStatus, Speed, and the lifetime/power attributes. Fixed limits
can be `null` when the host has no reliable capability value. Lifetime
RunningHours and EnergyConsumed, OperationMode and ControlMode use Manage
privilege for writes; the requested modes and lifetime counters persist.

A remote write calls the host's `on_apply_mode` callback. With no callback,
the server returns `INVALID_IN_STATE`. Unsupported feature modes return
`CONSTRAINT_ERROR`. An accepted request changes the requested mode only; it
does not claim the pump physically changed. The host calls `report_operation`
after observing the current operation, speed, and capacity. This updates the
effective attributes and sends normal attribute change notifications. The
synthetic pump in `examples/matter_pump_device.cr` accepts requested speed
modes for protocol testing.

Pressure, flow, temperature, automatic, and local-operation profiles remain
unsupported. Optional fault events are not declared or emitted. A production
host must implement the physical mode transition and connect its power, status,
and lifetime telemetry. The example is a protocol fixture, not a pump driver.
