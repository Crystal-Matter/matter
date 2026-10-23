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
advanced user policies remain incomplete. The advertised cluster revision
remains 9; these tests do not establish complete Matter 1.6 revision 10
conformance.

Matter-side Aliro reader configuration and public-key credential management
are available through local `DoorLock` methods. They persist with the Door Lock
user database after a normal device persistence flush and validate P-256 keys
and configured capacities on restore. Local key provisioning accepts an explicit
`fabric_index:` when the host has a fabric provenance; otherwise its fabric
attribution is unset. This is host state, not a Matter command execution.
To advertise `AliroProvisioning`, an application must provide a trusted
`DoorLock::AliroReaderDelegate` and nonzero issuer/endpoint key capacities.
Its `ready?` method must confirm that a real reader transport and verifier are
available. The delegate supplies a fixed 16-byte group subidentifier and 1–16 two-byte
expedited protocol versions, applies reader configuration, and obtains local
user permission before clearing it. Most critically, its `authenticate`
method must verify the complete Aliro reader transcript, key possession,
freshness and replay protection. For an issuer step-up, it must request the
`matter1` data element and validate the Access Credential before returning
the issuer and new endpoint public keys. The cluster accepts only identities
returned by that delegate, maps them to an enabled, authorized user, applies
schedule policy, creates or evicts only that user's evictable endpoint keys,
and reports Aliro-sourced user and lock events. A delegate without a real
Aliro transport must not be used in a deployed lock.
If endpoint capacity is full and the issuer's user has no evictable endpoint
key, a validated step-up can still operate the lock; no new key is stored and
the LockOperation event names the issuer credential. A non-evictable key is
never displaced to make room.

With the delegate, the cluster exposes the required Aliro attributes
`0x0080`–`0x0083` and `0x0087`–`0x0088`, plus administrator-only timed
Set/Clear reader configuration commands `0x28`/`0x29`. Aliro public keys can
be managed through the regular credential commands; GetCredentialStatus
returns their public key in `CredentialData`. Reader configuration and key
tables survive normal persistence flushes and restart. A reader that rejects
restored configuration causes the cluster to stop advertising Aliro rather
than accepting unauthenticated access. The signing key is secret material,
so the chosen storage backend must protect it accordingly. `AliroBLEUWB`
remains rejected until a real BLE/UWB radio adapter supplies attributes
`0x0084`–`0x0086` and the corresponding transport behavior.
Configure `number_of_aliro_credential_issuer_keys_supported` and
`number_of_aliro_endpoint_keys_supported` when constructing the lock; both
default to zero. `configure_aliro_reader` accepts an `AliroReaderConfig` with
a matching 32-byte P-256 signing key and 65-byte uncompressed verification
key, a 16-byte group identifier, and an optional 16-byte resolving key.
`provision_aliro_key` accepts a valid 65-byte P-256 public key, an existing
user index, and an optional explicit `fabric_index:`. Issuer keys and the two
endpoint-key types have separate index ranges; endpoint keys share one capacity
across both types. `clear_aliro_reader_config` and `clear_aliro_key` remove the
staged material locally. When Aliro is enabled, local reader configuration
clear also requires the delegate's user-permission callback. Callers should
flush device persistence after changes
to make them survive a restart.
