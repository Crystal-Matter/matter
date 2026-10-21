# Color Control transitions

Color Control MoveTo and Step commands use their Matter 1.6 `TransitionTime`
field in deciseconds. Zero applies the target immediately. A nonzero value
interpolates current hue, enhanced hue, saturation, XY chromaticity, or color
temperature on monotonic 100 ms ticks. Combined hue/saturation commands move
both values over one duration. Hue follows the command's cyclic direction;
combined commands use the shortest route. The physical color temperature
bounds and command-specific StepColorTemperature bounds are enforced, as is
the XML chromaticity maximum of 65279.
MoveTo target fields beyond their XML bounds return ConstraintError and leave
the current transition running, even when ExecuteIfOff suppresses an otherwise
valid command. Step result values are clipped to their bounds.

`RemainingTime` starts at the requested decisecond count, decreases while a
timed command runs, and reaches zero on completion or StopMoveStep. A new
command advances the old transition to its current value before replacing it.
StopMoveStep holds that value. Per Matter 1.6, an active ColorLoop survives
StopMoveStep and is stopped by ColorLoopSet instead.

Only commands advertised by enabled features are available. The cluster
continues to advertise revision 7; this change does not claim the additional
requirements of Matter 1.6 revision 9.
