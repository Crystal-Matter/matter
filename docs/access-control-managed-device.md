# Access Control ManagedDevice foundation

Matter 1.6 Access Control revision 3 defines the ManagedDevice (MNGD) feature
for devices whose hosts impose additional access restrictions. Crystal Matter
does not advertise MNGD yet. The first internal foundation lets a host enforce
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

The host policy is memory-only and must be installed again after restart. The
internal review lifecycle now accepts a fabric-specific request with a snapshot
of the requested ARL entries. An empty request list means a generic review.
The host installs `on_restriction_review_requested` and
`on_restriction_review_updated` callbacks, then calls
`request_restriction_review`. The returned token correlates a subsequent
`complete_restriction_review` call and update payload. A host may adjust its
ARL independently before completion; the review method never changes policy.
If the host has not completed a request after 59 minutes, the library invokes
the update callback with that token and no optional instructions. Removing a
fabric cancels its pending reviews. The update fields use the Matter 1.6 TLV
schema and enforce the 512-byte instruction and 256-byte URL limits.

The Matter 1.6 wire schema is now present behind the MNGD feature gate. The
default `AccessControl` feature map still omits MNGD, so its attributes,
command, and event are absent from default metadata and global lists. If a
host explicitly enables MNGD, `CommissioningARL` is a View-readable fixed
list configured once during setup, `ARL` is View-readable and fabric scoped,
and `ReviewFabricRestrictions` requires Administer privilege and a CASE fabric.
The response carries a review token; completion emits a fabric-sensitive
`FabricRestrictionReviewUpdate` event. Malformed wire requests fail before
the host callback runs.

Persistent ARL policy, completion delivery across restart, semantic validation
of allowed endpoint/cluster targets, and independent managed-device
interoperability remain future work. Device configurations should leave MNGD
disabled until those paths are implemented and tested.
