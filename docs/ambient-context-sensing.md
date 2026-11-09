# Ambient Context Sensing (Matter 1.6 provisional)

`Matter::Cluster::AmbientContextSensing` implements revision 1 with HumanActivity (HA), HA+PredictedActivity (PRED), standalone ObjectIdentification (OI), SoundIdentification (AUD), AUD+PRED, or the combined ObjectCounting and ObjectIdentification (OC+OI) profile on an opt-in endpoint. The host supplies physical classifications through `observe_human_activity`, `observe_object`, `observe_sound`, or `observe_object_count`. Synthetic Aggregator endpoints in `examples/matter_ambient_context_device.cr` demonstrate the wire surface; they do not claim a certified sensing device type.

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

For OC+OI, configure Identified Object namespace (0x49) tags including Unknown and one concrete object. A single supported object and threshold are selected through `ObjectCountConfig` (Manage-writable and persistent). `ObjectIdentified` becomes true for a positive host count, while `ObjectCountReached` becomes true only when the selected object's count reaches the threshold. The optional `ObjectCount` attribute has stable metadata and reads null until that threshold is reached. The start event includes the count status and includes the count when reached. A zero observation or HoldTime expiry ends detection. This profile still supports only one active detection and does not advertise HA.

For standalone OI, configure Identified Object namespace (0x49) tags including Unknown and one concrete object. `observe_object(tag, true)` starts or refreshes a detection; `observe_object(tag, false)` ends that object's detection, and HoldTime expiry also ends it. The server advertises `ObjectIdentified`, `AmbientContextType`, and `AmbientContextTypeSupported` without the three OC count attributes. Start events carry the detected object tag without count fields. Only one object can be active at once. Host classification remains responsible for determining whether that object is present.

For AUD, configure standard Identified Sound namespace (0x4A) tags including Unknown and at least one concrete sound. `observe_sound` accepts only configured concrete tags. It sets `AudioContextDetected`, reports the sound in `AmbientContextType`, and emits the existing start event. A repeated observation refreshes HoldTime; expiry clears the flag, restores Unknown, and emits the end event. This opt-in profile supports one active sound detection, with no built-in microphone or classifier.

For HA+PRED or AUD+PRED, configure the corresponding activity or sound tags and a trusted `prediction_clock` callback that returns seconds since the Matter epoch (2000-01-01 UTC), or `nil` while time is unavailable. The host supplies future `PredictedActivityStruct` entries through `replace_predicted_activities`. Each entry has start and end timestamps, one configured tag from that profile, and confidence from 0 to 100 percent. The server accepts at most 20 entries, requires each start to follow the previous end, and publishes the replacement atomically. A prediction is removed when its start time arrives; reads refresh the list, and the host can call `refresh_predicted_activities` when its clock advances to notify subscribers promptly. Loss of trusted time clears the list. The predictor and clock discipline remain host-owned; the synthetic fixture uses separate explicit test clocks and hooks for HA and AUD.

An observation starts a detection and emits `AmbientContextDetectStarted` with the detected semantic tag. Repeated observations of that tag add HoldTime at most once in each HoldTime period without another start event. Continuous triggered time is capped at `HoldTimeLimits.HoldTimeMax`; at the deadline, the server clears detection, restores Unknown, and emits `AmbientContextDetectEnded` with the start time in POSIX milliseconds. A later observation starts a new detection. `HoldTime` is writable with Manage privilege and survives a restart; active detection and events are volatile. `HoldTimeLimits` is fixed. An application should feed the cluster only classifications backed by its own sensor and should choose HoldTime limits that fit its sensor.

The tagged Matter 1.6 XML marks `SimultaneousDetectionLimit` writable with Operate privilege and calls the end-event field `EventStartTime` (context tag 0). The connectedhomeip future errata overlay and current matter.js model instead mark the limit read-only/fixed and use `EventStartTimePos`/`EventStartTimeSys`. This server follows the tagged 1.6 XML; compatibility with that future variant is separate work.

Standalone OC, standalone PRED, and combined feature profiles beyond HA+PRED, AUD+PRED, and OC+OI are not implemented. The constructor rejects those feature maps, so their conditional attributes and events are never advertised. This provisional slice does not implement a physical sensor, classifier, or certification policy.
