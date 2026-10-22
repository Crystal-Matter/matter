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

The remaining revision 10 work includes durable, protected user, credential,
and schedule storage across restart. AliroProvisioning is exposed as an
optional feature flag but lacks its required reader-configuration attributes
and commands. The official chip-tool test covers the supported mode bitmap,
mode writes, SoundVolume values, and remote operation denial while in
NoRemoteLockUnlock mode. It does not establish complete revision 10 behavior.
