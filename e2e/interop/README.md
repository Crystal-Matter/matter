# Matter SDK Joint Fabric RPC bridge

`joint_fabric_rpc_bridge.py` is a test-only TCP endpoint for the Matter 1.6
`jfc-app` Pigweed `JointFabric` service. It uses only the Python standard library
for the RPC transport. Start it before `jfc-app` so its initial TCP connection
succeeds:

```sh
python3 e2e/interop/joint_fabric_rpc_bridge.py --host 0.0.0.0 --port 33033
```

Pass `--rpc-server-ip <bridge-address> --rpc-server-port 33033` to `jfc-app`.
The bridge keeps `GetStream` open after Anchor commissioning. It is useful
when testing SDK JFC's RPC transport against the Crystal test harness. The
first end-to-end interoperability smoke test should use the SDK's own JFA as
Anchor and commission a Crystal ordinary device with `--regular 1`; that run
uses the SDK JFA's native RPC server and does not need this bridge.

An optional probe checks an already provisioned Crystal JFA through its
`MATTER_JFA_COMMAND_PATH` file interface. It requires `PyYAML` in the test
environment and a dedicated, initially absent command file:

```sh
python3 e2e/interop/joint_fabric_rpc_bridge.py \
  --command-path /e2e/logs/matter_joint_fabric_anchor.command.yml \
  --fabric-id 41216 --root-public-key-hex <130-hex-digit-P256-key>
```

The probe writes `jfa_command/request` with operation `inspect-fabric`, then
requires an `ok` result with the same nonce, Fabric ID, root public key, and
`fabric_present: true`. For initial Anchor commissioning, omit the probe since
the JFA does not have the new fabric when JFC first connects.

For ownership handoff, configure the Crystal JFA with
`MATTER_JFA_COMMAND_PATH` and point the bridge at that same, initially absent
file. The bridge writes one request with a nonce, fsyncs the file and its
directory, then acknowledges the RPC. Crystal records `in-progress`, followed
by `ok` or `error` with the same nonce. Inspect that result separately; the
RPC acknowledgement means the request was queued durably, not that CASE or
`CommissioningComplete` succeeded. A completed file must be archived or
removed before another handoff. This test-only file channel assumes that the
configured JFA device is running and shares the same directory.

```sh
python3 e2e/interop/joint_fabric_rpc_bridge.py \
  --handoff-command-path /e2e/logs/matter_joint_fabric_anchor.command.yml \
  --fabric-id 41216 --root-public-key-hex <130-hex-digit-P256-key>
```

`TransferOwnership(jcm=true)` now queues the trusted B ICAC public key and
peer JFA endpoint from the RPC request. The JFA device verifies their shape,
uses CASE to the expected Node ID, runs its device-originated Anchor exchange,
checks the returned ICAC, then invokes `CommissioningComplete`.
`ResponseStream` still returns Pigweed `UNIMPLEMENTED`; the bidirectional
ICAC CSR stream remains unavailable. The existing
`transfer-anchor` operation is a different protocol step and must not be used
as a substitute. SDK JFC also issues its own Anchor ICAC key during bootstrap;
Crystal JFA requires that private key to activate. A full SDK JFC → Crystal
JFA test therefore also needs a credential import or CSR/signing handoff path.

The SDK JFA implementation checks JCM ownership requests for a 65-byte ICAC
public key and a valid peer endpoint before scheduling work. The bridge makes
the same field checks (`OUT_OF_RANGE` for invalid input), including protobuf
boolean and endpoint range validation. It maps valid standard and JCM requests
only when `--handoff-command-path` and the Anchor fabric identity are configured.

To complete this mapping, the interop setup needs:

1. Verify the JCM `finalize-commissioning` path against official SDK JFC:
   bind the trusted B ICAC public key and peer endpoint supplied by JFC to
   the authenticated target Node ID, then verify the device-originated CASE,
   Announce, ICAC CSR/AddICAC, and `CommissioningComplete` result. The RPC
   acknowledgement proves only durable queue acceptance; check the YAML
   `result` for completion.
2. A headless way to request an ICAC CSR from SDK JFC over `GetStream` and
   consume its `ResponseStream` payload, or a credential import that proves
   the existing Crystal ICAC private key matches JFC's commissioned ICAC.
   The current `jcm_anchor_exchange` file starts after controller-side JCM
   verification and does not implement this SDK JFC stream.
3. An explicit provisioned Anchor identity for the official JFC's issued
   NOC/ICAC and root, so Crystal's JFA activation and CASE credential checks
   agree with that ecosystem.

### SDK handoff mapping

The Matter 1.6 SDK JFC calls `TransferOwnership` for a **joining JFA** after it
has installed operational credentials on that JFA with `CommissioningComplete`
deferred. SDK JFA accepts the RPC by scheduling work and responds immediately;
its later network outcome is logged separately. The SDK JFC waits about one
second for that RPC acknowledgement. A Crystal file adapter should therefore
acknowledge only a durably queued, validated request promptly, then record the
actual CASE/IM outcome under the request nonce. Waiting for CASE before
replying would exceed the JFC deadline; replying before durable acceptance
would be a false success.

| RPC message | SDK JFA/JFC behavior | Crystal behavior needed |
| --- | --- | --- |
| `TransferOwnership(node_id, jcm=false)` | JFA originates CASE to that Node ID and invokes General Commissioning `CommissioningComplete`. | The test JFA now accepts a one-shot `finalize-commissioning` headless request with fabric selectors and nonce, originates CASE as its Anchor identity, checks the target Node ID, and records the IM outcome. |
| `TransferOwnership(node_id, jcm=true, trustedIcacPublicKeyB, peerAdminJFAdminClusterEndpointId)` | JFA originates CASE as Anchor, invokes Announce on B's JFA endpoint, checks B's ICAC CSR public key against `trustedIcacPublicKeyB`, then invokes `CommissioningComplete`. | The bridge queues the key and endpoint. The JFA command validates them, runs its Anchor exchange, verifies the returned ICAC, then sends `CommissioningComplete`. |
| `GetStream` / `ResponseStream` | JFC opens a server stream. When JFA needs its ICAC CSR, JFA emits `RequestOptions(ICAC_CSR)`; JFC generates a CSR with its persisted Anchor intermediate key and returns `Response(ICAC_CSR, csr_bytes)` through `ResponseStream`. | Add a CSR provider on the JFA service that can await that RPC exchange and validate the returned CSR key against the commissioned ICAC. The current service signs its own CSR with a locally provisioned private key. |

There is a second credential gap for full JCM. Crystal's Anchor exchange signs
B's cross-signed ICAC using a locally stored A CA key. SDK JFC keeps its A
issuer keys in its own credential store. Its v1.6 `RequestOptions` enum names
`CROSS_SIGNED_ICAC`, but JFC's `GenerateReplyWork` handles only `ICAC_CSR`.
An SDK patch to answer a signing request, or explicit test-only import of the
issuer key into Crystal, is required before SDK JFC can drive that Crystal
Anchor path. This gap remains even after a `finalize-commissioning` command
and ICAC CSR stream are added.

The SDK credential boundary is precise: `ExampleOperationalCredentialsIssuer`
stores its root issuer key as `kOperationalCredentialsIssuerKeypairStorage` and
its Anchor intermediate key as
`kOperationalCredentialsAnchorIntermediateIssuerKeypairStorage`. It signs the
Anchor ICAC with the root key and the Anchor NOC with the intermediate key.
`ObtainICACSR` signs a CSR using that intermediate key; the RPC stream sends
the CSR bytes, never the private key. Consequently, implementing
`ResponseStream(ICAC_CSR)` alone cannot give a Crystal JFA the key needed to
operate the SDK-issued Anchor NOC or sign joining Administrator NOCs.
`SignICAC` can use the SDK root key to cross-sign a CSR, but SDK v1.6 JFC does
not expose it through `GenerateReplyWork`: that switch only implements
`ICAC_CSR`. A production integration needs authenticated signing operations
delegated to the controller's credential issuer for the Anchor intermediate
and root keys. Key export would only be suitable for an isolated test fixture.

Crystal `Commissioner#pairing_code` now has an explicit `defer_completion`
option for handing standard commissioning to a JFA after AddNOC. JCM uses a
separate authenticated exchange with a cross-signed ICAC before completion;
the JFA file result carries that certificate only after its
`CommissioningComplete` succeeds.

Run the dependency-free smoke tests with:

```sh
python3 -m unittest discover -s e2e/interop -p 'test_*.py' -v
```

## Lean official SDK interoperability run

Run this on a Linux x64 runner with enough free space for the Matter SDK build.
Use the checked out `v1.6.0.0` SDK source. Bootstrap its own environment and
submodules, then build only the two Joint Fabric apps, using the target names
from the SDK's CI workflow:

The executable smoke runner performs this build with the `release-size` profile,
builds the Crystal switch, starts all three processes in one network namespace,
and checks the JFC commissioning and fabric/ACL readback logs. It requires
`dbus` and `avahi-daemon` to be running. The manual GitHub Actions workflow
`.github/workflows/sdk-jfc-smoke.yml` installs and starts them. Run locally with:

```sh
bash e2e/interop/sdk_jfc_switch_smoke.sh
```

Set `MATTER_SDK_ROOT` for an existing v1.6.0.0 checkout, or let the script
clone the tag into `tmp/connectedhomeip`. Logs and process state are kept in
`tmp/interop-sdk-jfc`; set `MATTER_INTEROP_LOG_DIR` to change that path.
Set `MATTER_INTEROP_SKIP_BUILD=1` and `MATTER_INTEROP_SWITCH_BIN` to reuse
existing executables. The smoke test has not been run against a live SDK build
yet; the workflow is manual so its first network result can be reviewed.

```sh
cd tmp/connectedhomeip
./scripts/checkout_submodules.py --shallow --platform linux
source scripts/bootstrap.sh -p linux
./scripts/build/build_examples.py \
  --target linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang \
  --target linux-x64-jf-admin-app-ipv6only-no-ble-no-wifi-clang \
  --build-profile release-size \
  build --copy-artifacts-to objdir-jf
```

The executable runner excludes unused Arm GCC from a copied SDK environment
configuration before bootstrap. This avoids a CIPD extraction failure seen on
constrained runners. It uses the SDK-managed Python environment, avoiding
system Python package restrictions.

For the first network smoke test, start the built `jfa-app` and `jfc-app` as
shown in the SDK's [Joint Fabric guide](https://github.com/project-chip/connectedhomeip/blob/v1.6.0.0/docs/guides/joint_fabric_guide.md):

```sh
objdir-jf/linux-x64-jf-admin-app-ipv6only-no-ble-no-wifi-clang/jfa-app \
  --capabilities 0x4 --passcode 11022033 --discriminator 3840 \
  --secured-device-port 5533 --rpc-server-port 33033 --KVS jfa_a_kvs
objdir-jf/linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang/jfc-app \
  --rpc-server-port 33033 --storage-directory jfc_a_storage \
  --commissioner-vendor-id 0xFFF1
```

Run the two apps in separate terminals. At the JFC prompt, commission its
official JFA with `pairing onnetwork-long 1 11022033 3840 --anchor true`.
Then start a Crystal ordinary device in commissioning mode and enter
`pairing onnetwork 2 <device-passcode> --regular 1`. Finally use JFC
`operationalcredentials read fabrics 2 0` and a device-specific read/write
command over CASE. This isolates SDK controller interoperability before
attempting Crystal JFA ownership exchange.

Wire contract: Matter SDK v1.6.0.0
[`joint_fabric_service.proto`](https://github.com/project-chip/connectedhomeip/blob/v1.6.0.0/examples/common/pigweed/protos/joint_fabric_service.proto)
and Pigweed `pw_rpc/internal/packet.proto` / `pw_hdlc` UI framing.
