# Zone Management (Matter 1.6)

`Cluster::ZoneManagement` implements revision 1 of cluster `0x0550` with the
TwoDimensionalCartesianZone (bit 0) and UserDefined (bit 2) features. It
supports the mandatory zone and trigger lists, global Sensitivity, and all
five requests plus the CreateTwoDCartesianZone response. The two mandatory
ZoneTriggered and ZoneStopped events are emitted when a host reports motion
and the configured trigger duration expires.

A zone is a simple polygon with 3–12 vertices inside `TwoDCartesianMax`. The
server checks bounds, crossings, zero area, name length, and optional CSS
hexadecimal color syntax. Zone IDs are unique, start at zero, and increase
across removals and restarts.
User zones, trigger controls, and global sensitivity persist through restart.
Manufacturer-defined zones can be supplied at construction; their IDs cannot
be updated or removed through the user commands. `MaxZones` includes the
manufacturer and user capacity.

The host calls `report_motion(zone_id)` when activity occurs. The first
observation emits ZoneTriggered. Later observations can extend the detection
window repeatedly under the augmentation rule, within MaxDuration. A timeout
emits ZoneStopped; BlindDuration
prevents another start until the blind interval expires. The server schedules
these timeouts automatically. `advance_trigger_timers` supports a host-owned
scheduler and deterministic tests. Live trigger activity is reset on restart;
configured zones and triggers remain durable.

A host that accepts Privacy zones must supply `on_zone_change` and apply
privacy masking in its media pipeline. Without that callback, Privacy zone
creation returns `INVALID_IN_STATE`. `examples/matter_zone_management_device.cr`
is a synthetic motion fixture on an Aggregator endpoint for chip-tool tests.
It is not advertised as a Camera device, which requires additional AV and
WebRTC clusters.

PerZoneSensitivity and FocusZones features are not enabled. Zone rendering,
real motion detection, and camera stream effects are the host's work.
