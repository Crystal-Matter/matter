# Boolean State Configuration

`Matter::Cluster::BooleanStateConfiguration` implements the Matter 1.6 revision
2 server at cluster ID `0x0080`. Add it to a sensor endpoint alongside
`BooleanState` when the device exposes alarm modes, sensitivity settings, or
fault reporting.

Construct the cluster with the features the device supports. `Visual` and
`Audible` enable alarm state and the `EnableDisableAlarm` command.
`AlarmSuppress` requires at least one of them and enables the `SuppressAlarm`
command. `SensitivityLevel` exposes a writable current level and a fixed
supported count from 2 through 10. `FaultEvents` enables the typed
`SensorFault` event. The optional default sensitivity attribute is exposed
only when a value is provided at construction.

```crystal
configuration = Matter::Cluster::BooleanStateConfiguration.new(
  endpoint,
  feature_map: Matter::Cluster::BooleanStateConfiguration::Feature::Visual |
               Matter::Cluster::BooleanStateConfiguration::Feature::AlarmSuppress,
)
configuration.update_alarms_active(
  Matter::Cluster::BooleanStateConfiguration::AlarmMode::Visual,
)
```

`update_alarms_active` reports the underlying condition. Suppression records
acknowledgement separately; it does not clear the active alarm. When an alarm
clears, its suppression bit clears too. Changes to active or suppressed alarms
emit typed `AlarmsStateChanged` events. `report_sensor_fault` emits a typed
event when the fault bitmap changes. These events use the endpoint's ordinary
event journal and are available to Matter subscriptions.

Disabling an alarm mode through `EnableDisableAlarm` also clears its active and
suppressed bits. `SuppressAlarm` returns `InvalidInState` if the requested mode
is not currently active.

Current sensitivity and enabled alarm modes use the cluster's persisted state.
The device application remains responsible for deciding when an alarm or fault
starts and clears; the cluster does not inspect sensor hardware.
