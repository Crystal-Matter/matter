# Matter 1.6 Joint Fabric implementation status

This page tracks the Crystal implementation against the [Matter 1.6 Core
Specification](https://csa-iot.org/wp-content/uploads/2026/06/23-27349-011_Matter-1.6-Core-Specification.pdf)
and the [official Joint Fabric guide](https://project-chip.github.io/connectedhomeip-doc/guides/joint_fabric_guide.html).
The implementation is still under interoperability development. Treat each
item below as covered only to the extent of its cited tests.

## Available building blocks

- Controller state stores multiple fabrics and scopes known nodes to a fabric.
  Commissioning and chip-tool selection accept explicit fabric identity.
- Device AddNOC and UpdateNOC bind the issued NOC to the CSR public key. CASE
  verifies the peer's certificate chain, Node ID, and CATs. The verified
  subjects survive session persistence and reach cluster handlers.
- A controller can install an externally issued identity with an ICAC, delegate
  a separate identity under an existing root, and grant that Node ID an ACL
  entry. See `SharedFabric` in the controller library.
- Joint Fabric Administrator (0x0753) and Datastore (0x0752) have typed Matter
  1.6 schemas and cluster handlers. Datastore entries track Pending,
  Committed, DeletePending, and CommitFailed. The controller synchronizer
  applies key sets, groups, ACLs, and bindings to nodes and records outcomes.
- The Joint Commissioning workflow verifies the joining administrator's
  operational VID proof, NOC chain, and Administrator CAT before issuing a
  NOC. The reachable Anchor Administrator device performs Announce and the
  ICAC exchange; the returned certificate is checked against the previously
  authenticated key and Anchor root. Trust anchors, attestation, and consent
  are explicit host decisions. Pending registration and the cross-signed ICAC
  persist across restart.
- The device implements SignVIDVerificationRequest and
  SetVIDVerificationStatement, including signed challenge binding, fabric
  filtering, persistence, and fail-safe rollback. The controller verifier
  requires a trusted operational root or verified VID statement.
- DNS-SD understands Joint Fabric `JF` role bits and `CM=3`. A Joint Fabric
  Administrator example exposes the mandatory device type (0x0130) and both
  clusters. It advertises Anchor status only when explicitly provisioned with
  an Anchor CAT and ICAC, and requires explicit local consent to open a Joint
  Commissioning window.
- The Docker two-administrator test bootstraps separate fabrics, performs the
  JCM credential exchange between the Crystal implementations, and checks the
  stored cross-signed ICAC. CommissioningComplete is deferred to the Anchor
  JFA and acknowledged before the controller publishes the joined identity.
  The pending handoff survives restart and an acknowledged result can be
  reconciled after the fail-safe deadline.
- Anchor transfer has a persisted candidate journal and participant follow-up
  for cross-signing and removal of the old fabric. Administrator removal has a
  consent gate, persisted journal, Datastore update, and Administrator CAT/NOC
  rotation. The Docker two-administrator test exercises both paths over the
  network, including a lost RemoveFabric acknowledgement, reconciliation, and
  an idempotent removal retry. The former Anchor subscribes to the new
  Anchor's authenticated Datastore and suspends Joint Commissioning when that
  view is stale. The subscription is invalidated if its fabric changes.
- A dedicated Docker RefreshNode test observes an offline node fail propagation,
  then commissions it and confirms live endpoint and ACL reconciliation to
  Committed over CASE.

## Work required for interoperable Joint Commissioning

1. Integrate a production operational trust anchor source and exercise
   independent consent decisions with real ecosystem policies.
2. Run the JCM sequence against the official SDK `jf-control-app` and
   `jf-admin-app`. The current Docker test proves Crystal-to-Crystal JCM;
   the official `chip-tool` separately commissions the example device.
3. Extend Anchor transfer and administrator removal network tests beyond two
   administrators and exercise interruption at each journal transition.
4. Run the [official Joint Fabric administrator tests](https://github.com/project-chip/connectedhomeip/tree/v1.6.0.0/src/python_testing)
   and real device interoperability before claiming Matter 1.6 conformance.

## Security boundaries

Only authenticated CASE NOC subjects may satisfy an Administrator or Anchor
CAT check. The controller's `OperationalTrustAnchors` implementation must
validate the source of an operational root or VID Verification Statement. An
absent trust decision fails the JCM verification step. Applications must make
an explicit user consent decision for each ecosystem joining a fabric.
For administrator removal, Matter 1.6 recommends transferring to a fresh
trusted root after rotating Administrator CAT credentials, because an ICAC
issued under the old root cannot be revoked. The removal coordinator does not
automatically perform that optional root transition.
