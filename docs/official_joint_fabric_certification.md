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
All six passed in the [integrated SDK matrix run](https://github.com/Crystal-Matter/matter/actions/runs/39688721274)
against the expanded Joint Fabric E2E branch later merged as PR #112.

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

The multi-ecosystem fixture runs the following official cases without changing
their scripts or assertions. Both passed in the
[integrated Matter 1.6 SDK CI run](https://github.com/Crystal-Matter/matter/actions/runs/39691543775)
against merged `develop`:

| Case | Verified protocol path |
| --- | --- |
| `TC_JFADMIN_2_1` | Two SDK JFC ecosystems, two JFAs, two ordinary devices and SDK-driven Joint Commissioning with Crystal as the Anchor JFA. |
| `TC_JFADMIN_2_2` | Two SDK JFC ecosystems and SDK-driven Joint Commissioning of Crystal as the joining JFA, including its DNS-SD `JF` advertisement and the joined fabric's Administrator CAT NOC. |

The run's uploaded test summaries report PASS 1/1, with no failures or skips,
for each case.

The separate `TC_JFADMIN_1_2` SDK case passed in the
[integrated certification run](https://github.com/Crystal-Matter/matter/actions/runs/39691585152)
against merged `develop`. It covers the pre-Joint-Commissioning JFA command
and fail-safe sequence. Its fixture adds one missing test variable
initialization for teardown; the certification steps and assertions are
unchanged.
