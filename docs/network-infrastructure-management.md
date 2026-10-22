# Network infrastructure management

`Matter::Cluster::WiFiNetworkManagement` implements the Matter 1.6 cluster
`0x0451` as an opt-in server. A network infrastructure host adds it to an
endpoint and supplies the currently active Wi-Fi credentials:

```crystal
cluster = endpoint.get_cluster!(Matter::Cluster::WiFiNetworkManagement)
cluster.update_credentials(ssid_bytes, passphrase_bytes, durable_surrogate)
```

`SSID` and `PassphraseSurrogate` are nullable until credentials are supplied.
`NetworkPassphraseRequest` requires Manage privilege on an authenticated CASE
session. The passphrase is copied from the host input, held only in memory, and
never saved by the cluster to a `Storage::Document`. The host must own durable
credential storage and persist the surrogate alongside the passphrase. Before
serving after a restart, call `update_credentials` with the same surrogate for
the unchanged passphrase. Pass a different surrogate whenever the passphrase
changes. The cluster rejects surrogate reuse on a live passphrase change,
including after a clear and reprovision in one process. Call
`clear_credentials` when the network is removed.

This cluster does not configure a Wi-Fi access point. A full Matter 1.6 Network
Infrastructure Manager device also needs Thread Border Router Management
(`0x0452`) and Thread Network Directory (`0x0453`). Adding the Wi-Fi cluster
alone must not be treated as support for that device type.

`Matter::Cluster::ThreadBorderRouterManagement` implements the Matter 1.6
`0x0452` command and attribute surface as an opt-in server. Construct it with
an implementation of `ThreadBorderRouterManagement::Backend` and the root
`GeneralCommissioning` cluster. The backend must own the Thread interface,
dataset storage, activation and rollback. Its `valid_dataset?` method must
check radio/channel/security-policy constraints using its Thread stack (for
OpenThread, `otDatasetIsValid`); the cluster independently checks the required
TLV structure and bound. `GetActiveDatasetRequest` and
`GetPendingDatasetRequest` require CASE and Manage privilege, returning an
empty octet string when no dataset exists. `SetActiveDatasetRequest` requires
a timed invoke and an armed fail-safe belonging to the calling fabric. The
backend receives the remaining fail-safe time as a deadline and must finish
activation before it expires. If activation fails or the fail-safe expires,
the cluster asks the backend to restore the previous state. Its optional
Breadcrumb advances General Commissioning only after a successful activation.
`SetPendingDatasetRequest` is exposed only with PANChange and requires a timed
invoke. The host must call `refresh_host_state` after external Thread changes
to notify attribute subscribers. This library does not ship a physical
OpenThread backend or claim Thread Border Router device conformance without
one. Dataset secrets are not stored in the cluster's ordinary persistence.
