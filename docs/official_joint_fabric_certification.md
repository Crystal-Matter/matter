# Official Matter 1.6 Joint Fabric cases

The `sdk_jf_cert_matrix.py` fixture runs five unmodified connectedhomeip
`v1.6.0.0` scripts and one narrowly adapted script against a fresh Crystal
Joint Fabric Administrator.
The SDK JFC commissions the Crystal device as Anchor, and the SDK Python
controller performs the CASE reads and command assertions in each script.
The bridge serves the JFC Pigweed RPC stream. A separate device state and
controller store are created for every case, so one result cannot depend on
another case's provisioning.

Before each official script starts, the fixture starts JFC once to persist its
issuer keys, then configures the bridge with that issuer's public root key and
the JFA with a matching ICAC CSR mailbox. The official script reopens the
same JFC store, and Crystal can delegate ICAC CSR signing without importing
the SDK's private key. The SDK controller and Crystal device stores contain
private keys and are kept outside the uploaded log directory.

The CI workflow runs these cases and reports every failure in one run:

| Official case | Coverage |
| --- | --- |
| `TC_JFADMIN_1_1` | Anchor commissioning, AdministratorFabricIndex and Operational Credentials Fabrics over CASE |
| `TC_JFDS_2_1` | Anchor root, Node ID, vendor ID, friendly name and Datastore status over CASE |
| `TC_JFDS_2_2` | KeySetList and Add/Update/RemoveKeySet over CASE, including invalid security policy status |
| `TC_JFDS_2_3` | GroupList and Add/Update/RemoveGroup over CASE, including protected CAT groups |
| `TC_JFDS_2_4` (adapted input) | AdminList and Add/Update/RemoveAdmin over CASE |
| `TC_JFADMIN_1_4` | Commissioning window bounds, DNS-SD advertisement, expiry and busy status |

The SDK `TC_JFDS_2_4` script reads a 410-byte X.509 DER certificate from JFC
storage and sends it as `AddAdmin.ICAC`. Matter 1.6 limits that field to 400
bytes, so Crystal correctly returns `ConstraintError` for the original input.
The [adapter](../e2e/interop/sdk_jfds_2_4_adapter.py) subclasses the official
test and converts only its certificate input to Matter TLV using the SDK's
converter. It checks the X.509 subject and public key after a round trip. All
official commands and assertions remain inherited unchanged. This case is
reported as adapted; the other five run unmodified.

Run them with `python3 e2e/interop/sdk_jf_cert_matrix.py --sdk
<connectedhomeip-v1.6.0.0> --jfa <crystal-jfa> --log-dir <output>` after
building the SDK JFC and Python environment described in
`.github/workflows/sdk-jf-cert-matrix.yml`. The script accepts `--case` for a
single case. It preserves the official test, SDK JFC, bridge and Crystal logs.

The remaining official cases have these prerequisites:

| Case | Test fixture and protocol path still to exercise |
| --- | --- |
| `TC_JFADMIN_2_1` | Two SDK JFC ecosystems, two JFAs, two ordinary devices and SDK-driven Joint Commissioning of a joining JFA. |
| `TC_JFADMIN_2_2` | Two SDK JFC ecosystems and SDK-driven Joint Commissioning of the Crystal JFA, including its DNS-SD `JF` advertisement and the joined fabric's Administrator CAT NOC. |

Local parity specs for these command sequences do not substitute for a passing
official test. CI results and uploaded logs establish which independent tests
have actually passed.
