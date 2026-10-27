# Three Administrator Joint Fabric network scenario

`e2e/spec/joint_fabric_two_jfa_spec.cr` runs three Crystal Joint Fabric
Administrators on separate bootstrap fabrics. A jointly commissions B and C,
and each retains its own bootstrap Anchor service alongside the service joined
to A. The scenario verifies both cross-signed ICAC registrations and the
Administrator CAT ACL granted on C's joined fabric.

B's original ICAC fabric carries a signed VVS without a VVSC. The test serves
VID-scoped Root, ICA, and VID signer records from a fixture HTTPS DCL mirror.
Live CASE verification rejects removed records, the wrong VID, root, or signer,
then accepts the active signer for Joint Commissioning. The VVS and original
ICAC stay installed through B's restart and Anchor transfer. Administrators
use explicitly provisioned roots for no-VVS fabrics and the DCL signer for a
VVS; rejection of a VVS never falls back to root trust.

Before the normal B registration, the scenario deliberately interrupts A's
controller after B has accepted AddICAC and before CommissioningComplete. A
new controller Workflow reads the persisted pending registration, while an
original-fabric CASE read still sees A's provisional fabric on B. Recovery is
blocked before B's cumulative fail-safe expiry. After expiry, an authenticated
original-fabric CASE read proves that A's fabric rolled back, allowing A to
clear the pending record and retry normal Joint Commissioning. The fixture
sets a test-only 120-second cumulative fail-safe limit through B's local
command channel, adding about two minutes to this scenario. It leaves B
running until expiry; restarting B earlier tests a separate rollback path.

B then transfers the Anchor role from A. The fixture first interrupts after
B durably copies A's Datastore and again after A and C rotate their credentials;
each restart checks the persisted stage and copied or rotated state before
resuming. It then interrupts after TransferAnchorComplete, restarts B from its
persisted `Completing` journal, and reconciles the old Anchor's completion
witness. A later interruption resumes only the participant follow-up from
`FollowingUp`. C then commits B's cross-signed
ICAC, while B stops after durably saving the `CrossSigned` stage and before
sending RemoveFabric. B restarts again and resumes C's old-fabric removal;
C's new-fabric NOC is unchanged. C still has A's fabric before that resume,
and B's NOC and Administrator CAT version stay unchanged. The test checks
that the new Anchor Datastore contains A, B, and C,
and that C removes its A fabric and installs B's fabric. A follows B's
Datastore over a verified CASE session. Its
subscription discovers Descriptor endpoints carrying the Datastore cluster,
then selects the single endpoint that is readable on B's fabric and reports
the authenticated Anchor root and Node ID. During promotion, the copied
Datastore on endpoint 1 is rebound to B and the former bootstrap Datastore on
endpoint 2 is retired.
The promoted Anchor's NOC carries a rotated Anchor CAT version. Startup
recognizes the Anchor CAT identity with a nonzero version and restores the
promoted role, rather than requiring the bootstrap version.

Finally, B removes A. The test interrupts after the remote RemoveFabric
acknowledgement is lost, restarts B, and verifies that the persisted removal
journal blocks replay until the operator reconciles A's fabric state. It also
restarts B after a lost RemoveAdmin acknowledgement and verifies the persisted
AdminList before reconciliation. B then completes removal and retains B and C
in its Administrator list. A repeated removal is idempotent.

Run just this scenario with `./test --e2e-only --
e2e/spec/joint_fabric_two_jfa_spec.cr`.
