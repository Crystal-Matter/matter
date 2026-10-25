# Window Covering conformance

Crystal Matter advertises Window Covering cluster revision 8, matching the [Matter 1.6 data model](https://github.com/project-chip/connectedhomeip/blob/v1.6.0.0/data_model/1.6/clusters/WindowCovering.xml).

The implementation omits the revision 7 retired AbsolutePosition feature and commands, validates LF/TL and position-aware feature dependencies, starts nullable current and target positions as unknown, applies open/close to both configured axes, encodes the three OperationalStatus direction fields, and makes StopMotion target the last reported position on each axis. The optional percentage commands on lift-only or tilt-only configurations are not advertised; they are mandatory and present with the matching position-aware feature.

Mode writes reject undefined bits, synchronize ConfigStatus, and block all movement commands with Busy in maintenance mode or Failure in calibration mode. Mode and reported current positions survive a restart. The optional whole-percent current-position attributes follow the reported percent100ths positions.

Device integrations retain responsibility for physical motion and position reporting:

- Report current positions as hardware moves. When a reported lift or tilt
  position reaches its target, the cluster settles that axis in
  OperationalStatus and derives the global status from the remaining axis.
- Report SafetyStatus based on device sensors and implement physical movement reversal when MotorDirectionReversed is set.
- Count lift and tilt actuations where the optional counters are exposed; expose a hardware movement and stop hook rather than treating target assignment as physical movement.

These are application-specific capabilities, not claims of physical movement by the library.
