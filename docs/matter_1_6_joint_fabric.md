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
- For a Joint Fabric whose ICAC signing key is available locally,
  `SharedFabric.delegate_joint` issues a controller NOC with a non-reserved
  group CAT. `SharedFabric.grant_joint_admin` verifies that identity and the
  Anchor Datastore root, then uses AddGroup,
  AddGroupIDToEndpointForNode, and AddACLToNode as needed. Repeating the
  grant checks existing Datastore entries before sending commands and calls
  RefreshNode when a matching membership or ACL has CommitFailed. The
  Datastore propagates the pending membership and ACL to the target node;
  callers should observe its status before assuming the controller can access
  that node. Existing `grant_admin` remains available for fabrics that do
  not use the Joint Fabric Datastore.
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
  The transfer journal records each completed Administrator credential rotation
  and identifies an uncertain in-flight rotation. After restart, the caller
  must inspect that Administrator's NOC/CAT and reconcile the rotation before
  resuming; completed rotations are skipped. A three-Administrator spec covers
  interruption during the second rotation.
- The Datastore accepts CASE reads and commands only while this device is the
  Anchor. During transfer it remains readable for the candidate's frozen
  snapshot; after TransferAnchorComplete, the former Anchor rejects Datastore
  reads and commands, including after restart. Its propagation worker stops
  when the Datastore freezes.
- A dedicated Docker RefreshNode test observes an offline node fail propagation,
  then commissions it and confirms live endpoint and ACL reconciliation to
  Committed over CASE.
- Opt-in controller Datastore registration journals AddPendingNode before the
  device's final CASE, then RefreshNode after acknowledged commissioning. The
  Anchor CASE adapter reads NodeList before retrying a command; known failures
  remove the pending entry. A lost CommissioningComplete result requires
  explicit reconciliation before removal. Focused controller specs cover the
  journal, retry, and network command behavior. A dedicated Docker scenario
  first commissions a Crystal switch with official chip-tool, then joins the
  Anchor fabric through the opt-in registrar; it observes the pending NodeList
  record before final CASE and the committed node, endpoint, and ACL afterward.
- `JointFabricDeviceMigration` provides the post-JCM Fabric B device migration
  sequence from Core §12.2.5. It keeps B's A-fabric operational ICAC separate
  from the cross-signed ICAC used to issue device NOCs. It verifies the latter
  against B's original ICAC key, the
  current Administrator CAT on B's authenticated Datastore, and A's root and
  IPK on A's authenticated Datastore. It then opens an enhanced commissioning
  window over B CASE, attests and commissions A, verifies A CASE, waits for A
  NodeList to commit, removes B from the device, and removes the B NodeList
  entry. A per-device journal blocks automatic replay of uncertain commands;
  read-only CASE checks allow explicit recovery. Rollback is available before
  B removal. The JFA example now publishes its IPK as GroupKeySetID zero.
  An opt-in second JFA Datastore endpoint remains bound to B after endpoint 1
  joins A, so B's NodeList remains available until migration completes. The
  Docker two-JFA test migrates a real switch from B201 to A201 and verifies A
  CASE, absence of the B fabric, and NodeList movement in both Datastores.
  The local `migrate-device` command requires explicit device consent and an
  attestation trust configuration. An embedding application sets
  `Device#migration_attestation_trust=` with an `AttestationTrustStore` holding
  DER PAA certificates, CD signer SKI-to-public-key entries, and a revocation
  callback. The callback must return `Good` only after its own trust source
  confirms the DAC/PAI/PAA chain; `Unavailable` fails commissioning. The
  example's Matter test-root option is enabled only in the Docker fixture.

## Work required for interoperable Joint Commissioning

1. Integrate a DCL-backed operational VID trust source and exercise
   independent consent decisions with real ecosystem policies. Matter 1.6
   Core §6.4.10.1 requires looking up Operational Trust Anchors by VID and
   SKID, then validating either a root entry (`IsRoot`) or a VID Verification
   Statement signer (`IsVIDVerificationSigner`). The current
   `StaticOperationalTrustAnchors` accepts only explicitly provisioned,
   self-signed roots and cannot validate a VID Verification Statement. The
   official SDK's `DeviceCommissioner::OnLookupOperationalTrustAnchor`
   delegate is the reference integration point; authenticated DCL transport,
   signer entries, and statement-chain validation remain follow-up work.
2. Run the JCM sequence against the official SDK `jf-control-app` and
   `jf-admin-app`. The current Docker test proves Crystal-to-Crystal JCM;
   the official `chip-tool` separately commissions the example device.
3. Extend Anchor transfer and administrator removal network tests beyond two
   administrators and exercise interruption at each journal transition. The
   three-Administrator rotation and restart path currently has local spec
   coverage.
4. Run the [official Joint Fabric administrator tests](https://github.com/project-chip/connectedhomeip/tree/v1.6.0.0/src/python_testing)
   and real device interoperability before claiming Matter 1.6 conformance.
5. Deploy a production PAA/CD signer and revocation trust source through the
   JFA example's explicit injection point. The Docker fixture deliberately
   opts into the Matter test PAA/CD roots. Provisioned Datastores created before IPK seeding need their
   GroupKeySetID zero repaired before the fail-closed migration path can run.
   Exercise restart and network interruption at each per-device journal stage
   with independent ecosystem devices before claiming conformance.

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
