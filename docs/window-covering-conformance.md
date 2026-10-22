# Window Covering conformance

This audit compares Crystal Matter with [the official Matter 1.6 WindowCovering.xml](https://github.com/project-chip/connectedhomeip/blob/v1.6.0.0/data_model/1.6/clusters/WindowCovering.xml) (cluster revision 8) and the local matter.js WindowCovering server reference. Crystal Matter still advertises cluster revision 6.

The current slice removes the revision 7 retired AbsolutePosition feature and commands, validates LF/TL and position-aware feature dependencies, starts nullable current and target positions as unknown, applies open/close to both configured axes, encodes the three OperationalStatus direction fields, and makes StopMotion target the last reported position on each axis.

Remaining gaps before advertising revision 8 include:

- Settle OperationalStatus when a reported current position reaches its target. The current setters do not yet recompute movement status when hardware reports a new position.
- Synchronize optional whole-percent current-position attributes with the percent100ths values and persist them when exposed. Persisted state needs migration support before adding these fields to the storage schema.
- Implement Mode, ConfigStatus, and SafetyStatus behavior, including maintenance and calibration lockout, operational availability, movement reversal, and supported actuator controls.
- Count lift and tilt actuations where the optional counters are exposed; expose a hardware movement and stop hook rather than treating target assignment as physical movement.

These gaps are tracked here so a revision change follows verified behavior rather than just matching the data-model number.
