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

An accepted MoveTo, Step, or movement-producing Move command selects its
ColorMode and EnhancedColorMode as soon as it starts, before the first
transition tick. This also applies when a zero-duration command names the value
already stored: the new mode is still observable even though the numeric color
value does not change. Rejected or ExecuteIfOff-suppressed commands leave the
modes alone.

Only commands advertised by enabled features are available. The cluster
continues to advertise revision 7. Matter 1.6 defines revision 9; its full
behavioral audit remains open, including the advertised
StartUpColorTemperatureMireds power-on behavior and feature-map dependency
checks. Optional calibration attributes and device-specific color-space
conversion are not implemented.
