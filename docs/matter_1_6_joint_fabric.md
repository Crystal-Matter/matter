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
- Device UpdateNOC and UpdateFabricLabel use the accessing CASE fabric. Their
  command payloads do not carry FabricIndex; a legacy extra field cannot
  redirect an update, and a fabricless PASE invoke is rejected. UpdateNOC
  accepts omitted ICACValue as specified by the Matter 1.6 wire schema.
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
- After JCM, a joining Administrator can use
  `JointFabricDeviceMigration.cross_signed_issuer` with its original ICAC
  private key and A's cross-signed ICAC. The resulting issuer's
  `delegate_controller` method gives a B-ecosystem controller its own
  operational key and a group CAT NOC on Fabric A. Install that identity in a
  controller store, then call `SharedFabric.grant_joint_admin` through A's
  Datastore for each target device and wait for the node ACL to commit.
  The issuer keeps B's ICAC private key; the delegated controller receives
  only its operational key. The two-JFA E2E scenario verifies that the
  migrated A device denies access before the Datastore grant, accepts B's
  cross-signed controller afterward, and retains access after restart.
- Joint Fabric Administrator (0x0753) and Datastore (0x0752) have typed Matter
  1.6 schemas and cluster handlers. Datastore entries track Pending,
  Committed, DeletePending, and CommitFailed. The controller synchronizer
  applies key sets, groups, ACLs, and bindings to nodes and records outcomes.
  An opt-in Groupcast Listener target accepts the provisioned key sets through
  GKM, adopts the fabric, and applies endpoint group membership through root
  Groupcast JoinGroup/LeaveGroup. RefreshNode imports Groupcast membership
  when present. The target derives fabric-scoped AuxiliaryACL entries for
  authorized group endpoints and hides legacy GKM maps from an adopted fabric.
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
  AddNOC and SetVIDVerificationStatement enforce operational Vendor IDs from
  1 through 0xFFF4; reserved IDs return their Matter 1.6 command statuses.
  SignVIDVerificationRequest reports ConstraintError for a challenge with an
  invalid length while preserving the command's typed TLV decoding. VID
  metadata changes and fail-safe rollback report Fabrics and NOCs updates to
  active subscribers. ArmFailSafe(0) removes a pending AddNOC fabric or restores
  an UpdateNOC identity while the device remains running. The fail-safe's NOC
  rollback snapshot is currently in memory: a process crash after AddNOC or
  UpdateNOC and before expiry can leave the provisional fabric record in
  persistent storage. A durable pending-credential journal and startup recovery
  remain necessary before claiming crash-safe commissioning rollback.
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
  and reconciles the result. It also restarts B after a lost RemoveAdmin
  acknowledgement, checks the removal in B's persisted AdminList over CASE,
  and resumes CAT/NOC rotation only after checked reconciliation. B and C
  remain registered. Before A's authorized removal, B rejects an unconsented
  request to remove C and the test checks that C's fabric, B's AdminList, and
  the Administrator CAT version are unchanged. The former
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
  The default JFA has only endpoint 1. Endpoint 2 is removed before startup
  unless the bootstrap Datastore retention option is enabled, so wildcard JCM
  reads cannot encounter an unprovisioned second JFA.
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

Local restart and transport-interruption specs cover both possible outcomes
at each persisted Anchor transfer command boundary (request, Datastore copy,
credential rotation, candidate promotion, and completion), including restart
during participant follow-up, and each
Administrator removal boundary (RemoveFabric, Datastore RemoveAdmin, Anchor
rotation, and participant rotation). They verify that an observed completed
command is not replayed and an observed no-effect command can be retried after
reconciliation. Stable journal stages resume without repeating earlier
commands. B-to-A device migration already has the same five-command recovery
matrix, plus rollback and a fresh file-backend restart test. These local tests
exercise journal logic; wider live network interruption coverage remains open.

## Official certification scenario mirrors

`spec/cluster/joint_fabric_certification_parity_spec.cr` runs local command
sequences drawn from connectedhomeip v1.6.0.0's `TC_JFADMIN_1_1`, `1_2`,
`1_4` and `TC_JFDS_2_1` through `2_4`. It checks the Anchor's advertised
Datastore values, reserved key set and CAT groups, key set/group/admin command
outcomes, JFA fail-safe statuses, and Joint Commissioning window parameter
boundaries. The `TC_JFDS_2_2` invalid security policy is injected as raw TLV:
the handler returns `ConstraintError` as the certification test requires.

These are local parity checks. The independent SDK cases and their exact
coverage are tracked below and in `docs/official_joint_fabric_certification.md`.

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
The [integrated SDK run](https://github.com/Crystal-Matter/matter/actions/runs/39691585152)
passed `TC_JFADMIN_1_2` against the merged Crystal JFA.

`e2e/interop/sdk_jf_cert_matrix.py` runs the official SDK v1.6.0.0
`TC_JFADMIN_1_1`, `1_4`, and `TC_JFDS_2_1` through `2_3` scripts unchanged
against Crystal. `TC_JFDS_2_4` inherits every official step and assertion but
converts the SDK fixture's 410-byte X.509 DER ICAC input to Matter TLV before
AddAdmin's 400-byte field. The dedicated Linux workflow passed all six cases.
The [integrated matrix run](https://github.com/Crystal-Matter/matter/actions/runs/39688721274)
passed all six cases against the expanded two-controller Joint Fabric E2E
branch, which was subsequently merged as PR #112.

`e2e/interop/sdk_jfc_jcm_live.py` separately commissions a Crystal B JFA
with the official v1.6 JFC, verifies its SDK-held Anchor ICAC CSR, then has a
Crystal A Anchor complete JCM and validate the cross-signed ICAC and Datastore
registration. Its dedicated Linux workflow passed with the official SDK
JFC/JFA binaries. This checks an independent JCM implementation; the official
multi-ecosystem certification cases are separate coverage.
The [integrated JCM run](https://github.com/Crystal-Matter/matter/actions/runs/39691566828)
passed against merged `develop`, including a streamed Anchor ICAC CSR signature
and Datastore registration.

The opt-in SDK JFC JCM fixture also publishes the SDK issuer's **public**
operational root through an ephemeral HTTPS DCL-shaped mirror on loopback.
Crystal's `DclOperationalTrustAnchors` must reject the SDK-issued joining
Administrator root when its DCL record has the wrong VID or has been removed,
then accept it when the active VID `0xFFF1` record is restored. A separate
attempt with the trusted root and explicit `consent=false` must stop before
credential issuance and Datastore registration. The fixture then reopens the
window and completes JCM with consent. The JFA example selects this mirror
only when `MATTER_JFA_TEST_DCL_GATEWAY_URL=https://127.0.0.1` is set; its
normal configured root source remains available for other test deployments.
The HTTPS certificate is generated per run and trusted only by fixture
processes. This verifies the SDK's independently issued operational root and
Crystal's trust and consent gates; it does not verify production DCL ledger
freshness, VVS interoperability, or a production consent policy.

`e2e/interop/sdk_jfadmin_multi.py` supplies isolated SDK issuer stores and a
Crystal JFA to the unmodified official `TC_JFADMIN_2_2.py` and
`TC_JFADMIN_2_1.py` scripts. The latter imports the SDK issuer's private key
into a test-only Crystal Anchor fixture; its private input and state stay
outside the uploaded CI artifact. The SDK persists issuer certificates as
X.509 DER, so the fixture converts them with the SDK's `chip-cert` tool
before passing Matter TLV certificates to Crystal. The converter checks that
the round trip retains the certificate subject and public key, and the Crystal
fixture checks each certificate against its corresponding private key.
For `2_2`, the fixture holds the Crystal JFA's commissionable mDNS record
until the official SDK has commissioned its first test device. Both devices
share the CI host address, and advertising the external DUT before that step
can make the SDK's on-network pairing select the wrong listener.
When Crystal B verifies the SDK Anchor's operational Vendor ID after an
authenticated Announce, its controller client shares the JFA device's UDP
listener. This keeps the verifier's fresh CASE handshake on the same source
port as the JFA's commissioned operational address; an ephemeral source port
can cause the SDK peer route to point away from the JFA. The shared client
claims only its own CASE exchange and secure session replies. Device requests
remain on an ordered worker so the verifier can receive its replies while the
Announce command waits. Missing operational trust or a failed CASE/VID check
still leaves the initiator unverified. Once verification succeeds, the JFA
adopts that CASE session into its device registry. The SDK may use the newest
session for its next ICACCSRRequest; adopting it keeps the authenticated
session available after the temporary controller client closes while the
original Announce exchange finishes on its earlier session.
The SDK may also refresh CASE between Announce, ICACCSRRequest, and AddICAC.
Crystal keeps the VID decision and CSR owner bound to the authenticated
Anchor node and fabric across those sessions; a different node or fabric
cannot reuse either decision.
The local Anchor ICAC exchange handoff retains a discovered link-local IPv6
peer's interface scope in its persisted request, so the Anchor's follow-up
CASE and Announce use the same interface. A scoped-address round-trip spec and
the Docker two-JFA handoff path cover the request; a live multi-interface
link-local network run remains to be exercised.
The unmodified official SDK v1.6.0.0 `TC_JFADMIN_2_2` and
`TC_JFADMIN_2_1` each passed all steps against Crystal in
[the integrated multi-ecosystem CI run](https://github.com/Crystal-Matter/matter/actions/runs/39691543775)
against merged `develop`.

## Work required for interoperable Joint Commissioning

1. Exercise independent consent decisions with real ecosystem policies and
   validate operational roots against a deployed, authenticated DCL gateway.
   The local SDK fixture above covers an independently issued root with an
   ephemeral HTTPS mirror and explicit test consent choices. The explicit
   `HttpDclSource` reads VID-scoped DCL
   OperationalPKI roots, ICAs, and VIDSignerPKI leaves. The local adapter binds
   an RCAC to a DCL root by VID, RCAC ID, public key, and SKID, and validates
   a VVS signature through a signer-specific leaf and a Root/ICA CA chain. The
   official SDK v1.6 implements the root lookup path but marks its VVS path
   unsupported, so independent VVS interoperability remains unproven.
   Deployment must authenticate and freshen its DCL gateway. The optional
   Matter-TLV VVSC is checked for its signed signer profile and issuer path.
   The Appendix F.5 fixed-vector spec checks fabric-binding and VVS-bearing
   signed-message byte layout against official SDK bytes. Its signed-message
   case substitutes a locally generated root key because the published vector
   does not supply that root's private key. This establishes encoding agreement,
   not independent VVS certificate-chain or live DCL interoperability.
2. Exercise interruption at each remaining Anchor transfer and administrator
   removal journal transition. The Docker three-administrator scenario covers
   A-to-B transfer, A removal, B restart after a lost RemoveFabric
   acknowledgement, persisted RemoveAdmin with a lost acknowledgement, and
   B/C registration; local specs cover interrupted second credential rotation.
   Other network interruption points remain.
3. Deploy production PAA/CD signers and a trusted CRL distribution source
   through the JFA example's explicit injection point. The bundled
   `OfflineAttestationRevocation` verifies issuer, signature, time, and chain
   scope for host-provisioned DER CRLs; automated DCL CRL retrieval is outside
   this library. The Docker fixture opts into Matter test PAA/CD roots.
   Provisioned Datastores created before IPK seeding now repair their
   GroupKeySetID zero from the installed Anchor fabric IPK on startup. The
   repair is saved before the Datastore is served and startup fails closed if
   it cannot be saved; a file-backed restart regression covers process loss
   before the normal debounced save.
   Exercise restart and network interruption at each per-device journal stage
   with independent ecosystem devices before claiming conformance.

The opt-in `HttpDclRevocationSource` queries the v1.6 DCL
`/dcl/pki/revocation-points/{issuerSKID}` index at an explicitly selected
HTTPS gateway. `DclAttestationRevocation` validates direct and delegated
PAA/PAI CRLs, including complete partition sets indexed by the issuer SKID.
Each partition needs a distinct DCL label and URL, and its critical IDP URI
must match the URL byte for byte. The signer must be the candidate PAA/PAI or
a certificate signed by it with the delegated CRL signer profile. It downloads from explicitly
approved HTTPS hosts (or separately opted-in HTTP hosts) with a 1 MiB streaming
limit and no redirects, then checks every CRL signature, freshness, extensions,
issuer mapping, and serial. Missing coverage, malformed partitions, unmatched
delegators, unsupported IDP scope flags, delta CRLs, and unknown critical CRL
extensions return `Unavailable`. CRLs with more than 32 points for one issuer
are outside this bounded profile. The host
must authenticate and freshen its DCL gateway; this adapter does not establish
the gateway's ledger synchronization or replace production PAA/CD provisioning.

## Security boundaries

The Ecosystem Information cluster on a Bridged Node exposes names and
locations only when the bridge host publishes them for a fabric. Use
`Cluster::EcosystemInformation#publish` after the host's consent decision;
its read-only directories require Manage privilege and are filtered by fabric.
The device removes their entries when that fabric is removed. An empty
directory means the host has no metadata to share. Matter 1.6 requires this
cluster on a FabricSynchronizedNode Bridged Node and makes it optional on other
Bridged Nodes. Commissioner Control is required on an Aggregator with the
FabricSynchronization condition; its approval, UI and reverse commissioning
flow still needs a host policy implementation.

`examples/matter_ecosystem_bridge_device.cr` is an opt-in interoperability
fixture. It publishes clearly synthetic names and a location for each newly
commissioned fabric, so the official chip-tool E2E can read both directories,
restart the bridge and verify two-fabric isolation.
The ordinary bridge example does not enable this fixture.

`Cluster::CommissionerControl` provides the Matter 1.6 wire schema and a
host-driven approval state machine for a fabric-synchronizing Aggregator. It
advertises `FabricSynchronization` only after a host configures both callbacks:
one to start approval and one to prepare a response with deferred commissioning
work. `RequestCommissioningApproval` records the CASE fabric,
client NodeID and RequestID, and the host later calls `resolve_approval` to
emit a result event visible only on that fabric. Without a host, requests
receive a failure result and `CommissionNode` cannot return a window. The
approval callback must enqueue consent work and return promptly; the host
resolves the request asynchronously after a decision. Approval is consumed
when a matching `CommissionNode` has prepared a valid response. The host calls
`expire_approval` when its manufacturer-defined validity interval ends. Fabric
removal and restart also discard outstanding approvals.
At most 64 requests are tracked; accepting a new one retires the oldest and
emits a failure result if that older request was still pending. Each accepted
request has a local generation token so a late host decision cannot approve a
later request that reuses the same wire RequestID.

The host must obtain any user consent it requires before approving. The
`prepare_window` callback creates a `PreparedWindow`: public enhanced-window
parameters and a private commissioning task holding the setup PIN. The cluster
validates the wire parameters and returns them immediately. Only after the
matching encrypted InvokeResponse has been sent does the protocol layer start
the task, outside its session lock. This ordering matters: the client opens
the intended target's window only after receiving `ReverseOpenCommissioningWindow`.
The host must finish preparation within `ResponseTimeoutSeconds` and its task
must use the approved VendorID/ProductID when calling
`Controller::Commissioning::Commissioner#pairing_code` with `expected_identity`.
That option checks both IDs after device attestation and before AddNOC. A
failed preparation leaves the approval available for a retry; a prepared
response consumes it even if the response send fails, so a fresh approval is
required. Ordinary device and bridge examples do not advertise this cluster,
and the current slice is not a complete reverse-commissioning flow.
`examples/matter_commissioner_control_device.cr` is an opt-in synthetic
Aggregator used only for chip-tool interoperability testing. It auto-approves
one test VID/PID pair and returns dummy reverse-window bytes with a no-op
deferred task; it does not open a target window or commission a node.

For a real two-fabric SDK interoperability run, use
`e2e/interop/sdk_reverse_commissioning.sh` on Linux x64. It pins the official
SDK to `v1.6.0.0`, builds its RPC-enabled `fabric-admin` and
`fabric-bridge-app`, and uses `examples/matter_reverse_commissioning_device.cr`
as the Crystal Aggregator. The fixture first commissions that Aggregator onto
a Crystal-owned source fabric. The SDK FabricAdmin commissions its local bridge
onto an independent destination fabric, then joins the Aggregator to that
fabric through an Enhanced Commissioning Window. The SDK's real
`fabricsync add-bridge` command requests approval, receives the
`ReverseOpenCommissioningWindow` response, and opens its local bridge window
over Pigweed RPC. Crystal then attests and commissions the SDK bridge onto the
source fabric, checking the approved test VID/PID before AddNOC. The harness
verifies both nodes report two commissioned fabrics over fresh CASE sessions.
Logs are retained under `tmp/interop-sdk-reverse/`. This test requires
`MATTER_REVERSE_TEST_CONSENT=1` and loads the pinned SDK FFF1 test PAA and
development Certification Declaration signer certificates into this example's attestation
trust store. Those are opt-in test policy and trust, not a production consent UI
or a production attestation authority.
The [official SDK v1.6.0.0 run](https://github.com/Crystal-Matter/matter/actions/runs/39799454842)
completed this flow: SDK approval and enhanced-window handoff, Crystal's
attestation and AddNOC of the SDK bridge, and fresh CASE reads showing two
fabrics on both the Aggregator and bridge. The SDK test fixture did not
configure a DAC revocation delegate; production deployments must supply their
own revocation policy and consent UI.

Only authenticated CASE NOC subjects may satisfy an Administrator or Anchor
CAT check. The controller's `OperationalTrustAnchors` implementation must
validate the source of an operational root or VID Verification Statement. An
absent trust decision fails the JCM verification step. Applications must make
an explicit user consent decision for each ecosystem joining a fabric.

For DCL-backed operational VID checks, construct
`VidVerification::DclOperationalTrustAnchors.new(VidVerification::HttpDclSource.new("https://<trusted-dcl-gateway>"))`
and pass it to the JCM verifier. The gateway URL is an explicit HTTPS origin.
The adapter reads the DCL's active, VID-scoped NOC root, ICA, and signer indexes.
It verifies the operational RCAC ID, public key, and SKID against an approved
OperationalPKI root. Without a supplied VVSC, it validates a VVS signature
through a DCL VIDSignerPKI leaf issued by an OperationalPKI Root/ICA CA chain
of at most three certificates. That signer must carry the Matter VID signer
subject, use P-256 ECDSA-SHA256, and have the leaf digital-signature profile.
With a supplied VVSC, it validates the signed Matter certificate through the
DCL OperationalPKI Root/ICA CA path without requiring a duplicate DCL signer
leaf. CA parents need the Matter Root/ICA subject and certificate-signing
profile. The built-in fetcher uses a 1 MiB streaming limit,
five-second connection/read timeouts, and rejects redirects.
CA path length constraints are enforced for the signer chain.
Missing, malformed, expired, mismatched, or removed records fail closed.
Applications may implement `DclSource` for a locally authenticated DCL mirror.
An untrusted gateway can lie about the active/revoked status, so deploy with a
gateway whose ledger synchronization and transport you trust. The optional
Matter-TLV VVSC is checked for its VVS identifier, issuer name, validity,
digital-signature usage, non-CA status, SKID/AKID, and signature under its
DCL-approved Root/ICA issuer. The
SDK v1.6 does not implement independent VVS path verification, so this path
still needs an independent ecosystem interoperability run.

For administrator removal, Matter 1.6 recommends transferring to a fresh
trusted root after rotating Administrator CAT credentials, because an ICAC
issued under the old root cannot be revoked. The removal coordinator does not
automatically perform that optional root transition.
