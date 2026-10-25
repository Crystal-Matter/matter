# Matter 1.6 closure clusters

`Matter::Cluster::ClosureControl` implements revision 1 of cluster `0x0104`.
`Matter::Cluster::ClosureDimension` implements revision 1 of `0x0105`.
The synthetic fixture in `examples/matter_closure_device.cr` puts Closure Control
on a Closure (`0x0230`) endpoint and Closure Dimension on a separate Closure Panel
(`0x0231`) endpoint. The feature map must include Positioning, MotionLatching, or
both. Constructors reject combinations whose dependent features lack Positioning.
A positioning Closure Dimension selects exactly one motion type: Translation,
Rotation, or Modulation.

## Host integration

Closure Control `MoveTo` and `Calibrate` require timed interaction; `MoveTo`
requires Operate and `Calibrate` requires Manage privilege. The host registers
`on_move_to` and optionally `on_calibrate` to admit physical actuator work.
`on_stop` stops physical motion. Accepted targets update the cluster's target
state; actual positions and the current main state change only when the host
calls `report_state`. `report_errors` updates `CurrentErrorList` and emits
`OperationalError`; `report_engaged` emits `EngageStateChanged` for a manually
operable closure. `Stop` always returns Success and changes Moving,
WaitingForMotion, or Calibrating to Stopped. The host must register `on_stop`
when those states are physically possible.

Closure Dimension `SetTarget` and `Step` are timed Operate commands. The host
registers `on_set_target`, which sees a normalized target and may reject it.
Position values are integer hundredths of a percent (`0..10000`). `Resolution`
and `StepValue` are fixed, positive integer values; `StepValue` is a multiple of
`Resolution`. A requested target is rounded to the nearest valid resolution;
`Step` uses `StepValue` and clamps to the percentage range. With Limitation,
range endpoints must align to `Resolution` so every advertised target remains
representable. The host calls
`report_state` when the panel reaches a sensed position. A composite host also
coordinates Control `MoveTo` with the associated Dimension target; the cluster
servers do not infer a physical panel relationship from endpoint numbers.

The canonical 1.6 XML spells the default of `Resolution` and `StepValue` as
`0.01`, in units of percent. Their Matter wire type is `percent100ths`, so the
encoded default is the integer `1`. A focused spec asserts that default; the
chip-tool fixture uses an explicitly configured resolution of `100` (1%). [The SDK schema correction discussion](https://github.com/project-chip/connectedhomeip/issues/74264)
records the same unit mismatch.

## Nullable state fields

The 1.6 XML requires a feature-present `Position` or `Latch` member inside
`OverallCurrentState`, `OverallTargetState`, `CurrentState`, or `TargetState`
even when its value is null. It omits that member when the feature is absent.
The current `TLV::Serializable` field model uses a nil value to omit an optional
member, and cannot choose between omission and an explicit TLV null based on a
cluster feature map. These cluster structs therefore serialize populated fields
correctly but omit a nil feature-present `Position` or `Latch`. This is a wire
conformance gap for unknown state values. The serializer needs a feature-aware
presence mechanism before these fields can be fully conformant.

## Composition limitation

Matter 1.6 defines Closure (`0x0230`) and Closure Panel (`0x0231`) as separate
endpoint device types. A Closure Panel is a child of a Closure and its Descriptor
requires the `TAGLIST` feature. The endpoint DSL now accepts `parent_endpoint:`
and `tag_list:`; see [Descriptor composition](descriptor-composition.md). The
current example still places its typed endpoints under root and does not claim
full Closure/Closure Panel device composition conformance. A composed Closure
fixture and official chip-tool check remain before certification.

Reference: [connectedhomeip ClosureControl.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.6/clusters/ClosureControl.xml),
[ClosureDimension.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.6/clusters/ClosureDimension.xml),
and the [matter.js closure model](https://github.com/matter-js/matter.js/tree/main/packages/model/src/standard/elements).
