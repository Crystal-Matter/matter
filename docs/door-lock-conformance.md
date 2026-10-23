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
must protect its files or database with appropriate access controls. The lock
does not yet enforce time-of-day or year-day access schedules, and its
ExpiringUser and DisposableUser policies remain incomplete. The optional
AliroProvisioning feature flag also lacks reader-configuration attributes
`0x0080`–`0x0083` and `0x0087`–`0x0088`, and commands `0x28`/`0x29`;
AliroBLEUWB additionally requires attributes `0x0084`–`0x0086`. These gaps
keep the advertised revision at 9;
the tests do not establish complete Matter 1.6 revision 10 conformance.
