# Access Control ManagedDevice foundation

Matter 1.6 Access Control revision 3 defines the ManagedDevice (MNGD) feature
for devices whose hosts impose additional access restrictions. Crystal Matter
does not advertise MNGD yet. The first internal foundation lets a host enforce
an Access Restriction List (ARL) on attribute reads, writes, and command
invocations by CASE clients.

The host installs a separate list for each fabric using
`AccessControl#configure_access_restrictions(fabric_index, entries)`. Each
`AccessRestrictionEntry` names an endpoint and cluster and contains one or more
`AccessRestriction` values. An `AttributeAccessForbidden` restriction matches
its attribute ID, or every nonglobal attribute in the cluster when the ID is
`nil`. `AttributeWriteForbidden` blocks only a write; `CommandForbidden` blocks
an invocation. These restrictions likewise accept `nil` as a wildcard ID.
Passing an empty list removes that fabric's restrictions. Removing the fabric
also clears its list.

The Matter 1.6 standard restriction provider accepts entries only for Wi-Fi
Network Management (`0x0451`), Thread Border Router Management (`0x0452`),
and Thread Network Directory (`0x0453`) on non-root endpoints. The host rejects
entries for other clusters or endpoint 0 without replacing the installed list.

The Interaction Model checks ordinary ACL privilege first. A permitted read,
write, or invocation blocked by the host list returns `AccessRestricted`
(`0x9D`). Other fabrics remain governed by their own policy. Standard global
attributes, including `FeatureMap`, remain readable according to their
ordinary ACL privileges. Both concrete and wildcard attribute reads use this
rule.

The host policy is memory-only and must be installed again after restart. The
MNGD wire attributes `CommissioningARL` and `ARL`,
`ReviewFabricRestrictions` command and response, and
`FabricRestrictionReviewUpdate` event are not exposed. Event restrictions,
persistent policy and the review lifecycle remain future work. MNGD must
remain disabled until those paths are implemented and tested.
