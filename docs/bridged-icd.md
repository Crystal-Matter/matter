# Bridged intermittent devices

`BridgedDeviceBasicInformation` supports Matter 1.6 BridgedICDSupport (BIS) only
when the bridge passes a `keep_active_adapter`. The adapter accepts the requested
`StayActiveDuration` in milliseconds and returns the externally confirmed
`PromisedActiveDuration`, or `nil` if the bridged device did not confirm it.
For a bridged Matter ICD, the adapter should send `StayActiveRequest` on the ICD's
next check-in or subscription report and return the response's
`PromisedActiveDuration`.

```crystal
info = Matter::Cluster::BridgedDeviceBasicInformation.new(
  endpoint_id,
  unique_id: "sensor-123",
  keep_active_adapter: ->(duration_ms : UInt32) {
    external_icd.stay_active(duration_ms) # UInt32?; nil on failure
  },
)

# Call this when the bridge observes the external device become active.
info.bridged_device_became_active
```

`KeepActive` records a pending request for 30,000–3,600,000 ms. Repeated commands
retain the greater duration and later expiry. The host callback runs only after
the bridge reports a real activation while the request remains pending. The
cluster emits `ActiveChanged` only when the callback confirms a promise, then
consumes the request. An expired request causes no callback or event. Pending
requests belong to the bridged endpoint, not to a particular fabric, and are
transient across bridge restart. Fabric removal does not change a pending
request from another administrator.

The standard `matter_bridge` example bridges ordinary lights and leaves BIS
disabled. It cannot extend any external device's active time. Its chip-tool
test checks the absent feature, command list, and unsupported command response.
The separate E2E fixture enables BIS and injects an external check-in plus a
confirmed duration through a test-only file hook. That fixture exercises
chip-tool's KeepActive command and ActiveChanged event wire path; it does not
represent a production ICD transport.
