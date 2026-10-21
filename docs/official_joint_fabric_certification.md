# Official Matter 1.6 Joint Fabric cases

The `sdk_jf_cert_matrix.py` fixture runs the unmodified connectedhomeip
`v1.6.0.0` test scripts against a fresh Crystal Joint Fabric Administrator.
The SDK JFC commissions the Crystal device as Anchor, and the SDK Python
controller performs the CASE reads and command assertions in each script.
The bridge serves the JFC Pigweed RPC stream. A separate device state and
controller store are created for every case, so one result cannot depend on
another case's provisioning.

The CI workflow currently runs these cases:

| Official case | Coverage |
| --- | --- |
| `TC_JFADMIN_1_1` | Anchor commissioning, AdministratorFabricIndex and Operational Credentials Fabrics over CASE |
| `TC_JFDS_2_1` | Anchor root, Node ID, vendor ID, friendly name and Datastore status over CASE |

Run them with `python3 e2e/interop/sdk_jf_cert_matrix.py --sdk
<connectedhomeip-v1.6.0.0> --jfa <crystal-jfa> --log-dir <output>` after
building the SDK JFC and Python environment described in
`.github/workflows/sdk-jf-cert-matrix.yml`. The script accepts `--case` for a
single case. It preserves the official test, SDK JFC, bridge and Crystal logs.

The remaining official cases have these prerequisites:

| Case | Test fixture and protocol path still to exercise |
| --- | --- |
| `TC_JFADMIN_1_4` | The same Anchor fixture, plus three complete commissioning window expiry cycles and DNS-SD advertisement checks. The official test uses 180 seconds per cycle outside its SDK CI mode. |
| `TC_JFDS_2_2` | The same Anchor fixture, then KeySetList and Add/Update/RemoveKeySet over CASE, including invalid security policy status. |
| `TC_JFDS_2_3` | The same Anchor fixture, then GroupList and Add/Update/RemoveGroup over CASE, including protected CAT groups. |
| `TC_JFDS_2_4` | The same Anchor fixture, then AdminList and Add/Update/RemoveAdmin over CASE. |
| `TC_JFADMIN_2_1` | Two SDK JFC ecosystems, two JFAs, two ordinary devices and SDK-driven Joint Commissioning of a joining JFA. |
| `TC_JFADMIN_2_2` | Two SDK JFC ecosystems and SDK-driven Joint Commissioning of the Crystal JFA, including its DNS-SD `JF` advertisement and the joined fabric's Administrator CAT NOC. |

Local parity specs for these command sequences do not substitute for a passing
official test. CI results and uploaded logs establish which independent tests
have actually passed.
