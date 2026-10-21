# Three Administrator Joint Fabric network scenario

`e2e/spec/joint_fabric_two_jfa_spec.cr` runs three Crystal Joint Fabric
Administrators on separate bootstrap fabrics. A jointly commissions B and C,
and each retains its own bootstrap Anchor service alongside the service joined
to A. The scenario verifies both cross-signed ICAC registrations and the
Administrator CAT ACL granted on C's joined fabric.

B then transfers the Anchor role from A. The test checks that the new Anchor
Datastore contains A, B, and C, and that C removes its A fabric and installs
B's fabric. A follows B's Datastore over a verified CASE session. Its
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
journal blocks replay until the operator reconciles A's fabric state. After
reconciliation, B completes removal and retains B and C in its Administrator
list. A repeated removal is idempotent.

Run just this scenario with `./test --e2e-only --
e2e/spec/joint_fabric_two_jfa_spec.cr`.
