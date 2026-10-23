# Door Lock conformance

The [Matter 1.6 Door Lock definition](https://github.com/project-chip/connectedhomeip/blob/v1.6.0.0/data_model/1.6/clusters/DoorLock.xml)
declares cluster revision 10. Crystal Matter currently advertises revision 9.
Revision 10 removes obsolete Zigbee commands and the reportable attribute
quality; the Crystal cluster already omits those commands.

The server now uses the specified `SoundVolume` values (`High = 2`,
`Medium = 3`) and an inverse `SupportedOperatingModes` bitmap. Its default
supports the mandatory Normal and NoRemoteLockUnlock modes, marks optional
modes unsupported, and sets reserved bits 5–15. Writes selecting an
unsupported mode return `ConstraintError`. A credential feature requires the
User feature in the advertised feature map.

The Door Lock user, credential, and week/day/year/holiday schedule tables now
share the cluster's persisted document with its writable attributes and data
version. Device shutdown or a normal persistence flush saves those tables
through the configured `Storage::Backend`; startup restores them only when
the saved FeatureMap matches. Corrupt tables leave the constructor defaults
in place. A restored PIN remains tied to its user and fabric attribution;
disabled and non-access users cannot operate the lock with that PIN. The
example's chip-tool test creates a user and PIN credential, restarts the
device, reads them back, and unlocks with the restored PIN.

The backend contains credential bytes and other device secrets, so deployments
must protect its files or database with appropriate access controls.

WeekDayScheduleUser and YearDayScheduleUser require a matching schedule;
ScheduleRestrictedUser requires a match from each configured schedule kind.
Unknown local time denies these users. A host can supply a `local_time_provider`
returning `Time?`; the default reads the system's local clock. Schedule denial
does not count as an incorrect PIN. Weekday schedule fields are checked before
storage. Holiday schedules select an effective operating mode during their
local-time interval, which controls remote operation and the wire read of
`OperatingMode`. The synthetic lock advertises these schedule features; its
official chip-tool test checks a scheduled PIN across restart.

A holiday boundary does not yet generate a data-version change or subscription
report without another interaction. ExpiringUser, DisposableUser, and other
advanced user policies remain incomplete. The AliroProvisioning and
AliroBLEUWB feature bits are rejected at initialization until their required
reader-configuration attributes and commands are implemented. The missing
AliroProvisioning attributes are `0x0080`–`0x0083` and `0x0087`–`0x0088`, with
commands `0x28`/`0x29`; AliroBLEUWB also requires `0x0084`–`0x0086`. These
gaps keep the advertised cluster revision at 9; the tests do not establish
complete Matter 1.6 revision 10 conformance.
