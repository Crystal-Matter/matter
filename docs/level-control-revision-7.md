# Level Control revision 7 audit

The server still advertises revision 6. The pinned Matter 1.6
`LevelControl.xml` revision history says revision 7 makes MinLevel and
MaxLevel mandatory, marks them fixed, and removes their previous persistence
quality. CurrentLevel remains nullable and nonvolatile, with scene quality.

This branch keeps MinLevel and MaxLevel from constructor configuration across
runtime-state restores, ignores legacy stored bounds, and clamps a known
restored CurrentLevel to the configured range. It also reports null
CurrentLevel and handles an absolute MoveToLevel from that state. Focused
specs cover these behaviors, plus the CurrentLevel scene quality and the
minimum non-null DefaultMoveRate of 1. The advertised revision stays at 6
because the following behavior is still incomplete:

- The Lighting `Options.CoupleColorTempToLevel` bit should couple level changes
  to Color Control's color temperature when the sibling server is present.
  The current Level Control implementation handles ExecuteIfOff but does not
  implement color-temperature coupling. Matter.js covers the behavior in
  `ColorTemperatureCouplingTest.ts`.

The canonical XML in the pinned Matter 1.6 SDK is
`data_model/1.6/clusters/LevelControl.xml`; relevant attributes are 0x0000,
0x0002, 0x0003, and 0x4000, with the Options bitmap at 0x000F. The pinned
SDK's `src/app/clusters/level-control/LevelControlCluster.cpp` Startup and
MoveToLevel paths provide implementation cross-checks.

The startup rule is implemented after cluster state restore. Ordinary startup
applies a non-null `StartUpCurrentLevel` (zero selects MinLevel); an OTA restart
passes `ota_restart: true` to `Device#start` and retains the previous level.
The rule follows Matter 1.6 Application Cluster §1.6.6.15. OTA update flows
must supply the restart flag when they restart the device.
