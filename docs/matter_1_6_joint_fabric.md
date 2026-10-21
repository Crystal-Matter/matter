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
  Commissioning window. A freshly commissioned but unprovisioned Administrator
  serves the specified fail-safe and ICAC validation statuses while its
  AdministratorFabricIndex remains null.
- The Docker two-administrator test bootstraps separate fabrics, performs the
  JCM credential exchange between the Crystal implementations, and checks the
  stored cross-signed ICAC. CommissioningComplete is deferred to the Anchor
  JFA and acknowledged before the controller publishes the joined identity.
  The pending handoff survives restart and an acknowledged result can be
  reconciled after the fail-safe deadline.
- Anchor transfer has a persisted candidate journal and participant follow-up
  for cross-signing and removal of the old fabric. Administrator removal has a
  consent gate, persisted journal, Datastore update, and Administrator CAT/NOC
  rotation. The Docker three-administrator test jointly commissions B and C,
  transfers the Anchor from A to B, and removes A. It restarts B after a lost
  RemoveFabric acknowledgement, verifies the persisted journal blocks replay,
  reconciles the result, and confirms B and C remain registered. The former
  Anchor subscribes to the new Anchor's authenticated Datastore and suspends
  Joint Commissioning when that view is stale. The subscription discovers the
  active Datastore endpoint through Descriptor reads and verifies its root and
  Node ID over CASE; promotion binds the copied store to B's fabric and retires
  B's bootstrap store. A rotated nonzero Anchor CAT version remains valid after
  restart. The subscription is invalidated if its fabric changes. A joined
  Crystal JFA verifies its committed cross-signed ICAC against the fabric root.
  A local signer must prove possession of the committed key; an SDK-owned
  remote signer may use a different ICAC ID when the cross-signed public key
  matches its commissioned ICAC public key.
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
  authenticated CASE and Datastore reads allow explicit reconciliation when a
  command took effect or provably had no effect. The latter restores the prior
  journal stage so an operator can retry. A partially applied command remains
  uncertain until its postcondition is met or an operator repairs the device
  and Datastore state. Completion reconciliation checks both A's committed
  NodeList entry and B's absent device fabric and NodeList entry, guarding
  against split ownership. Rollback is available before B removal. An
  interrupted rollback can be resumed explicitly: authenticated reads check
  whether each A NodeList and device fabric removal took effect before issuing
  only the remaining command. The JFA example now publishes its IPK as
  GroupKeySetID zero.
  The migration journal also records the device's CommissioningComplete
  acknowledgement before the controller node record is saved. If a process
  crashes in that window, recovery validates both fabric CASE sessions, B's
  committed NodeList entry, A's absent NodeList entry, and the A fabric
  descriptor before restoring the local node record. The journal also records
  the device's reported maximum cumulative fail-safe duration immediately
  after ArmFailSafe. If CommissioningComplete's reply is lost, recovery waits
  that full duration plus a safety margin using a fresh monotonic interval,
  then repeats the authenticated checks to establish durable A ownership.
  The saved UTC deadline is diagnostic and never shortens this wait, even if
  the controller clock changes during a restart. A fabric visible before the
  wait may still be provisional. A restarted `migrate-device` automatically
  performs this proof and continues if it succeeds;
  other uncertain mutation stages still require explicit reconciliation.
  Older journals lacking the reported duration remain uncertain and require
  manual repair rather than adopting A from a UTC timestamp alone.
  The local command channel accepts `reconcile-device-migration` after an
  authenticated completed postcondition, `reconcile-device-migration-no-effect`
  after authenticated proof that the command had no effect, and
  `resume-rollback-device-migration` for a partially completed rollback. All
  retain the same consent and selected fabric/device identity checks as
  `migrate-device`.
  If AddPendingNode has created an A NodeList entry but propagation remains
  Pending or CommitFailed, `resume-anchor-registration` explicitly sends
  RefreshNode and waits for a Committed entry without repeating AddPendingNode.
  With `MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE=1`, endpoint 2 keeps both B's JFA
  service and Datastore bound to B after endpoint 1 joins A. The two services
  retain separate AdministratorFabricIndex, ICAC and Anchor role records, and
  B's NodeList remains available until migration completes. On restart, the
  bootstrap fabric is restored before the joined fabric; removal of A keeps
  B's JFA credentials and endpoint available. The
  Docker two-JFA test migrates a real switch from B201 to A201 and verifies A
  CASE, absence of the B fabric, and NodeList movement in both Datastores.
  The local `migrate-device` command requires explicit device consent and an
  attestation trust configuration. An embedding application sets
  `Device#migration_attestation_trust=` with an `AttestationTrustStore` holding
  DER PAA certificates, CD signer SKI-to-public-key entries, and a revocation
  callback. The callback must return `Good` only after its own trust source
  confirms the DAC/PAI/PAA chain; `Unavailable` fails commissioning. The
  example's Matter test-root option is enabled only in the Docker fixture.

## Official certification scenario mirrors

`spec/cluster/joint_fabric_certification_parity_spec.cr` runs local command
sequences drawn from connectedhomeip v1.6.0.0's `TC_JFADMIN_1_1`, `1_2`,
`1_4` and `TC_JFDS_2_1` through `2_4`. It checks the Anchor's advertised
Datastore values, reserved key set and CAT groups, key set/group/admin command
outcomes, JFA fail-safe statuses, and Joint Commissioning window parameter
boundaries. The `TC_JFDS_2_2` invalid security policy is injected as raw TLV:
the handler returns `ConstraintError` as the certification test requires.

These are local parity checks. They do not run the official Python scripts or
verify discovery, CASE ACLs, mDNS window expiry, controller certificate stores,
and full commissioning against an independent implementation. Those remain
part of the interoperability work below.

## Official SDK certification runner

`e2e/interop/sdk_jfadmin_certification.py` launches a fresh Crystal JFA and
runs connectedhomeip v1.6.0.0's `TC_JFADMIN_1_2.py` with the SDK Python
controller. It supplies the device's generated setup code and discriminator,
and retains the SDK and device logs under
`tmp/interop-jfadmin-certification`. The Linux workflow
`.github/workflows/sdk-jfadmin-certification.yml` builds the SDK Python
controller from the tagged source and runs this case on pull requests that
change the JFA implementation. The case covers the JFA command and fail-safe
sequence before Joint Commissioning; it does not cover the controller's JCM
or the Datastore scenarios. The runner inserts one missing `jf_admin = None`
initialization into the v1.6.0.0 test copy for its non-CI teardown path; the
certification steps and assertions are unchanged.

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

The opt-in `HttpDclRevocationSource` queries the v1.6 DCL
`/dcl/pki/revocation-points/{issuerSKID}` index at an explicitly selected
HTTPS gateway. `DclAttestationRevocation` accepts one complete, directly
signed CRL for each of the PAA and PAI only. It downloads from explicitly
approved HTTPS hosts with a 1 MiB streaming limit and no redirects, then
reuses the signed CRL verifier. Missing or duplicate points, indirect signers,
partitioned CRLs, and unknown digest metadata return `Unavailable`. The host
must authenticate and freshen its DCL gateway; this adapter does not establish
the gateway's ledger synchronization or replace production PAA/CD provisioning.

## Security boundaries

Only authenticated CASE NOC subjects may satisfy an Administrator or Anchor
CAT check. The controller's `OperationalTrustAnchors` implementation must
validate the source of an operational root or VID Verification Statement. An
absent trust decision fails the JCM verification step. Applications must make
an explicit user consent decision for each ecosystem joining a fabric.

For DCL-backed operational VID checks, construct
`VidVerification::DclOperationalTrustAnchors.new(VidVerification::HttpDclSource.new("https://<trusted-dcl-gateway>"))`
and pass it to the JCM verifier. The gateway URL is explicit. The adapter reads
the DCL's active, VID-scoped NOC root, ICA, and signer indexes. It verifies the
operational RCAC public key against an approved OperationalPKI root or validates
a VVS signature through a VIDSignerPKI chain of at most three certificates.
Missing, malformed, expired, mismatched, or removed records fail closed.
Applications may implement `DclSource` for a locally authenticated DCL mirror.
An untrusted gateway can lie about the active/revoked status, so deploy with a
gateway whose ledger synchronization and transport you trust.

For administrator removal, Matter 1.6 recommends transferring to a fresh
trusted root after rotating Administrator CAT credentials, because an ICAC
issued under the old root cannot be revoked. The removal coordinator does not
automatically perform that optional root transition.
