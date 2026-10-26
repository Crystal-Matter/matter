# Access Control ManagedDevice host integration

Matter 1.6 Access Control revision 3 defines the ManagedDevice (MNGD) feature
for devices whose hosts impose additional access restrictions. Crystal Matter
advertises MNGD only when a device configures both review callbacks and a
durable storage backend. The host API lets a host enforce
an Access Restriction List (ARL) on attribute reads, writes, command
invocations, and event reads by CASE clients.

The host installs a separate list for each fabric using
`AccessControl#configure_access_restrictions(fabric_index, entries)`. Each
`AccessRestrictionEntry` names an endpoint and cluster and contains one or more
`AccessRestriction` values. An `AttributeAccessForbidden` restriction matches
its attribute ID, or every nonglobal attribute in the cluster when the ID is
`nil`. `AttributeWriteForbidden` blocks only a write; `CommandForbidden` blocks
an invocation. `EventForbidden` blocks event reads. These restrictions likewise
accept `nil` as a wildcard ID.
Passing an empty list removes that fabric's restrictions. Removing the fabric
also clears its list.
Host policy updates reject reserved fabric indexes (0 and 255), the reserved
endpoint and data model IDs, and entries with no restrictions. Validation
happens before replacement, so an invalid update leaves the existing policy
in force.

The Matter 1.6 standard restriction provider accepts entries only for Wi-Fi
Network Management (`0x0451`), Thread Border Router Management (`0x0452`),
and Thread Network Directory (`0x0453`) on non-root endpoints. The host rejects
entries for other clusters or endpoint 0 without replacing the installed list.

The Interaction Model checks ordinary ACL privilege first. A permitted read,
write, or invocation blocked by the host list returns `AccessRestricted`
(`0x9D`). Other fabrics remain governed by their own policy. Standard global
attributes, including `FeatureMap`, remain readable according to their
ordinary ACL privileges, even when a host entry explicitly names one. Both
concrete and wildcard attribute reads use this rule. A concrete restricted
event path returns `AccessRestricted`, while a
wildcard event path silently omits restricted data. Active subscriptions apply
the same check to later journal updates and advance past events that cannot be
reported on that fabric.
Attribute subscriptions also recheck ACL and ARL before every changed-value
report. A concrete denied path receives its current status; a wildcard path
omits that value.

The host policy and fixed commissioning list are saved in the Access Control
cluster document and restored after restart. Device startup removes saved
restrictions and reviews for fabric indexes absent from the fabric table before
CASE can reuse an index. Host policy updates write through to storage; a
failed save leaves the previous policy in force.

The device DSL can opt in with two instance methods:

```crystal
class MyDevice < Matter::Device
  storage yaml: "matter-device.yml"
  managed_restrictions requested: :review_requested, updated: :review_updated

  private def review_requested(request : Matter::Cluster::AccessControl::RestrictionReviewRequest) : Nil
    # Queue host consent work keyed by request.token.
  end

  private def review_updated(fabric : UInt8,
                             update : Matter::Cluster::AccessControl::FabricRestrictionReviewUpdate) : Nil
    # Record the correlated result keyed by update.token.
  end
end
```

Handwritten devices may instead pass `on_restriction_review_requested:` and
`on_restriction_review_updated:` procs to `Device#initialize`. Both callbacks
are required; volatile storage, including `Storage::Memory`, is rejected.
Durable file and SQL backends are accepted even when they have no local file
path, as with PostgreSQL.
The host owns the consent decision and installs only policy it explicitly
approves. Callbacks may run again after a crash with the **same token**; host
side effects must be idempotent by token.

The internal review lifecycle accepts a fabric-specific request with a snapshot
of the requested ARL entries. An empty request list means a generic review.
The host installs `on_restriction_review_requested` and
`on_restriction_review_updated` callbacks, then calls
`request_restriction_review`. The request callback should promptly queue an
asynchronous consent decision. A request or its token never changes policy.
While consent is pending, the host may call
`publish_restriction_review_update` with instructions or a URL without
consuming the token. `deny_restriction_review` leaves ARL unchanged;
`approve_restriction_review` installs exactly the complete replacement list
the host supplies and persists it with the completed review. Both decisions
are bound to the request's fabric and token. The low-level
`complete_restriction_review` still reports a correlated update without
changing ARL, for hosts that manage policy separately. The wire update has no
approval or denial field, so hosts should explain a denial in the optional
instruction or URL.
Pending requests retain their token, deadline, and fabric identity across
restart. Runtime installs callbacks after restoring Access Control and pruning
orphaned or replaced fabric reviews and their retained events. Unexpired requests are replayed
with the original token, while expired requests produce their fallback update.
If a request callback makes an immediate approval or denial, that decision is
applied after the request's initial durable marker is cleared.
If the host request callback fails before the token is returned, the library
persists a compensating cancellation so restart does not replay that request
when the rollback save succeeds.
Completion delivery is at least once if storage fails after an update callback
or event. If the host has not completed a request after 59 minutes, the library
invokes the update callback with that token and no optional instructions. Removing a
fabric cancels its pending reviews. The update fields use the Matter 1.6 TLV
schema and enforce the 512-byte instruction and 256-byte URL limits.

The Matter 1.6 wire schema is now present behind the MNGD feature gate. The
default `AccessControl` feature map omits MNGD, so its attributes,
command, and event are absent from default metadata and global lists. With
callbacks and durable storage configured, `CommissioningARL` is a View-readable fixed
list configured once during setup, `ARL` is View-readable and fabric scoped,
and `ReviewFabricRestrictions` requires Administer privilege and a CASE fabric.
The response carries a review token; completion emits a fabric-sensitive
`FabricRestrictionReviewUpdate` event. Malformed wire requests fail before
the host callback runs. The command is accepted only on the root endpoint.
With MNGD explicitly enabled, CommissioningARL restricts PASE attribute reads
and writes, command invocations, and event reads. CASE sessions continue to use
their fabric's ARL.

An application-specific consent UI or service and independent managed-device
interoperability remain host and integration work. The pinned SDK accepts ARL entries by
allowed endpoint and cluster ID without requiring the target to be installed;
this implementation follows that rule so policy can precede a dynamic endpoint.
The saved ARL policy and review records bind to the fabric's FabricID and root
public key. On startup, an opted-in device erases policy and review records
whose identity differs from the current occupant of that fabric index. Legacy
policy or pending reviews without a saved identity are also erased. Cleanup is
persisted before host callbacks can replay, and a failed cleanup save stops
startup.
An ARL read or access decision also checks the fabric identity, so direct
same-process replacement of a fabric cannot reuse its predecessor's policy.
If stale policy cannot be durably erased, the access fails closed.
