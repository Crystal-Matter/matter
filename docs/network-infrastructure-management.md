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
(`0x0452`) and Thread Network Directory (`0x0453`). Those clusters require a
real Thread dataset backend, validation, and lifecycle integration and remain
unimplemented. Adding the Wi-Fi cluster alone must not be treated as support
for the Network Infrastructure Manager device type.
