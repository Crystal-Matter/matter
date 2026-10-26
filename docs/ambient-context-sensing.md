# Ambient Context Sensing (Matter 1.6 provisional)

`Matter::Cluster::AmbientContextSensing` implements revision 1 with either HumanActivity (HA) or the combined ObjectCounting and ObjectIdentification (OC+OI) profile on an opt-in endpoint. The host supplies physical classifications through `observe_human_activity` or `observe_object_count`. Synthetic Aggregator endpoints in `examples/matter_ambient_context_device.cr` demonstrate the wire surface; they do not claim a certified sensing device type.

```crystal
alias Ambient = Matter::Cluster::AmbientContextSensing
unknown = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)

cluster = Ambient.new(endpoint_id,
  supported_activity_tags: [unknown, walking],
  hold_time: 30_u16)
cluster.observe_human_activity(walking)
```

The server advertises the HA bit alone. `HumanActivityDetected`, `AmbientContextType`, and `AmbientContextTypeSupported` use canonical `SemanticTagStruct` wire fields. When inactive, `AmbientContextType` contains the standard Human Activity Unknown tag (namespace 0x4B, tag 0) to satisfy its nonempty list constraint. The implementation supports one active detection; writes requesting a larger `SimultaneousDetectionLimit` return `ConstraintError`. Supported tags are configured at construction and must include Unknown.

For OC+OI, configure Identified Object namespace (0x49) tags including Unknown and one concrete object. A single supported object and threshold are selected through `ObjectCountConfig` (Manage-writable and persistent). `ObjectIdentified` becomes true for a positive host count, while `ObjectCountReached` becomes true only when the selected object's count reaches the threshold. The optional `ObjectCount` attribute is exposed only while that threshold is reached. The start event includes the count status and includes the count when reached. A zero observation or HoldTime expiry ends detection. This profile still supports only one active detection and does not advertise HA.

An observation starts a detection and emits `AmbientContextDetectStarted` with the detected semantic tag. Repeated observations of that tag refresh the HoldTime without another start event. After the HoldTime expires, the server clears detection, restores Unknown, and emits `AmbientContextDetectEnded` with the start time in POSIX milliseconds. `HoldTime` is writable with Manage privilege and survives a restart; active detection and events are volatile. `HoldTimeLimits` is fixed. An application should feed the cluster only classifications backed by its own sensor and should choose HoldTime limits that fit its sensor.

The tagged Matter 1.6 XML marks `SimultaneousDetectionLimit` writable with Operate privilege and calls the end-event field `EventStartTime` (context tag 0). The connectedhomeip future errata overlay and current matter.js model instead mark the limit read-only/fixed and use `EventStartTimePos`/`EventStartTimeSys`. This server follows the tagged 1.6 XML; compatibility with that future variant is separate work.

Standalone OC, standalone OI, SoundIdentification (AUD), PredictedActivity (PRED), and combinations with HA are not implemented. The constructor rejects those feature maps, so their conditional attributes and events are never advertised. This provisional slice does not implement a physical sensor, classifier, or certification policy.
