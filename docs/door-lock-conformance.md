# Door Lock conformance

The [Matter 1.6 Door Lock definition](https://github.com/project-chip/connectedhomeip/blob/v1.6.0.0/data_model/1.6/clusters/DoorLock.xml)
declares cluster revision 10. Crystal Matter currently advertises revision 9.
Revision 10 removes obsolete Zigbee commands and the reportable attribute
quality; the Crystal cluster already omits those commands.

Unbolting is no longer advertised by default. To enable it, pass both a
feature map containing `DoorLock::Feature::Unbolting` and an application-owned
`DoorLock::UnboltingActuator`. The actuator must confirm physical `unbolt`,
`pull_latch`, and `release_latch` completion before returning true. The
constructor rejects an Unbolting feature without this actuator. The example
Door Lock supplies an explicit simulation actuator; hardware devices must
replace it with a real one.

`UnboltDoor` retracts the bolt without pulling the latch, then reports
`Unlocked` state and an `Unlock` operation event. `UnlockDoor` retracts the
bolt, reports transient `Unlatched` state and an `Unlatch` event after the
latch is pulled, then reports `Unlocked` and an `Unlock` event after release.
An actuator failure before bolt retraction produces only an `Unlock` error.
Failures after bolt retraction produce an `Unlatch` error and an `Unlock`
event while retaining the last confirmed physical state. The host callback
owns the physical timing; the cluster does not invent a latch hold interval.

The server now uses the specified `SoundVolume` values (`High = 2`,
`Medium = 3`) and an inverse `SupportedOperatingModes` bitmap. Its default
supports the mandatory Normal and NoRemoteLockUnlock modes, marks optional
modes unsupported, and sets reserved bits 5–15. Writes selecting an
unsupported mode return `ConstraintError`. A credential feature requires the
User feature in the advertised feature map.
When Privacy is explicitly enabled, it can be selected only while locked.
A manual unlock changes Privacy back to Normal while remote lock commands
and exterior credential readers remain blocked in Privacy.

The Door Lock user, credential, and week/day/year/holiday schedule tables now
share the cluster's persisted document with its writable attributes and data
version. Device shutdown or a normal persistence flush saves those tables
through the configured `Storage::Backend`; startup restores them only when
the saved FeatureMap matches. Corrupt tables leave the constructor defaults
in place. A restored PIN remains tied to its user and fabric attribution;
disabled and non-access users cannot operate the lock with that PIN. The
example's chip-tool test creates a user and PIN credential, restarts the
device, reads them back, and unlocks with the restored PIN.

Failed remote PIN attempts and an active temporary lockout deadline are also
saved in the cluster document. A normal persistence flush and restart retain
both the partial retry count and the remaining lockout interval; successful
PIN authorization clears them. Older documents without these fields restore
with a fresh retry count. The lockout deadline uses the host's UTC wall clock,
so deployed locks need a trustworthy clock and durable storage. The official
chip-tool scenario restarts during a lockout and confirms the correct PIN
remains blocked.
Verified RFID and biometric presentations share this persisted attempt count
and lockout deadline with remote PIN attempts. Invalid reader credentials count
toward the same limit; a successful credential resets it. An unavailable or
failing reader does not count as a wrong credential.

SetCredential rejects duplicate PIN or RFID bytes in another slot of the
same credential type with the Door Lock `Duplicate` status. Add and Modify
check this before changing users or credentials; the official chip-tool
scenario verifies a rejected duplicate PIN over the wire. The two credential
types have separate value spaces. A saved database containing duplicate PIN
or RFID data fails restoration before changing live lock state, so the host
must correct those records rather than silently assigning one code to two
users.

RFID and biometric feature bits now require a configured
`DoorLock::LocalCredentialVerifier` that reports readiness for every advertised
credential type. A host calls `perform_local_credential_transaction` with an
opaque physical reader transaction and its credential type; the verifier must
check the actual reader or biometric result, freshness and replay protection
before returning an existing credential identity and its enrolled bytes. The
cluster compares those bytes with the current persisted credential, so a
reader mapping left behind by a Matter credential update cannot unlock. It
then checks the user's enabled status,
schedules, expiry and one-use policy, and emits attributed lock operation or
error events. A direct call to `unlock(source: Rfid)` or
`unlock(source: Biometric)` is rejected because a source label is not proof.
The synthetic RFID fixture uses a test hook to exercise this boundary with
official chip-tool credential management, restart, state and event reads;
it is not a production RFID reader. Applications must supply their own trusted
reader implementation. Aliro BLE/UWB requires a separate radio capable
delegate.

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
report without another interaction. DisposableUser becomes disabled after its
first successful open; a lock operation does not consume it. ExpiringUser starts
an absolute deadline on first successful credential use. The deadline is stored
with the user record, survives a normal persistence flush and restart, and a
restored timer disables the user when the deadline passes. Authorization and
GetUser also check the deadline, so a delayed timer never extends access.
Unknown local time denies an ExpiringUser. Automatic status changes emit
LockUserChange and mark the cluster dirty for persistence. ForcedUser PIN
access emits the ForcedUser operation and silent alarm; failed PIN operations
emit LockOperationError with the available user, credential, fabric, and node
metadata. SendPINOverTheAir defaults to false and ExpiringUserTimeout accepts
only 1–2880 minutes.

The host must provide a trustworthy wall clock for absolute expiry across a
restart. The advertised cluster revision remains 9; these tests do not
establish complete Matter 1.6 revision 10 conformance.

The optional one-touch, inside LED, and privacy button settings default to
false, and LocalProgrammingFeatures defaults to zero, following the Matter
1.6 XML. Applications that previously relied on enabled defaults should
pass explicit constructor values; `0x0F` is the all-enabled mask for the four
defined LocalProgrammingFeatures bits. Persisted boolean values retain their
saved values across an upgrade. CredentialRulesSupport advertises Single
only, and SetUser rejects Dual and Tri until the host can enforce access
with multiple credentials. A saved database containing a Dual or Tri user
fails restoration and the cluster retains its constructed state, so a
previous multi-credential configuration cannot silently become
single-credential access. Affected hosts must explicitly migrate those
records to a supported Single rule. Stored masks with reserved bits are also
rejected before changing live state, except the former `0xFF` default, which
is normalized to `0x0F` and saved on the next flush without dropping users.

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
requires an `AliroBleUwbReaderDelegate` that reports a ready physical radio,
supplies 1–16 two-byte BLE/UWB protocol versions and a fixed BLE advertising
version, and applies configuration and clear operations to both the radio and
reader as one host operation. The cluster then exposes administrator-only
attributes `0x0084`–`0x0086`. `0x0084` is NULL before configuration and the
16-byte group resolving key afterward. SetAliroReaderConfig requires that key
when ALBU is selected and rejects it when ALBU is absent. Access fails closed
if the radio later becomes unavailable; an unavailable radio on restoration
stops both ALIRO and ALBU advertisement. The delegate must implement the
actual Bluetooth LE/UWB transport and Aliro cryptographic verification; the
unit-test delegate is only a fixture. No hardware radio interoperability is
claimed by these software tests.
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
