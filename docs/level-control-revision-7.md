# Level Control revision 7 audit

The server advertises revision 7. The pinned Matter 1.6
`LevelControl.xml` revision history says revision 7 makes MinLevel and
MaxLevel mandatory, marks them fixed, and removes their previous persistence
quality. CurrentLevel remains nullable and nonvolatile, with scene quality.

This branch keeps MinLevel and MaxLevel from constructor configuration across
runtime-state restores, ignores legacy stored bounds, and clamps a known
restored CurrentLevel to the configured range. It also reports null
CurrentLevel and handles an absolute MoveToLevel from that state. Focused
specs cover these behaviors, plus the CurrentLevel scene quality and the
minimum non-null DefaultMoveRate of 1. A further conformance slice aligns
write privileges with the XML, makes only CurrentLevel and
StartUpCurrentLevel nonvolatile, exposes all eight mandatory commands without
requiring the optional OnOff feature, and marks Frequency CurrentFrequency as
a scene attribute. Direct host CurrentLevel assignments now validate the
configured bounds before changing the value. The Lighting
`Options.CoupleColorTempToLevel` bit now couples level changes to the sibling
Color Control server on the same endpoint. It uses the effective command
option, tracks timed transitions, and maps level 1 to the physical maximum
temperature in mireds and level 254 to the coupling minimum. Coupling requires
the Color Temperature feature and active color temperature mode. The related
Color Control cluster advertises revision 9 and supplies the required coupling
minimum.

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
