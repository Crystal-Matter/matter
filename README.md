# Matter

[![CI](https://github.com/Crystal-Matter/matter/actions/workflows/ci.yml/badge.svg)](https://github.com/Crystal-Matter/matter/actions/workflows/ci.yml)

Matter protocol implemented in pure Crystal Lang.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     matter:
       github: Crystal-Matter/matter
   ```

2. Run `shards install`

## Architecture

The library is a stack of layers, each one depending only on the layers below it.
`src/matter.cr` requires them in that order, one aggregator per subsystem, with no globs.

| Layer | Namespace | What lives there |
|---|---|---|
| Device | `Matter::Device` | the runtime and the declarative DSL: lifecycle, advertisements, persistence |
| Node | `Matter::Node`, `Matter::Endpoint`, `Matter::EventJournal` | endpoints, the clusters they own, the flat cluster index, the event rings |
| Clusters | `Matter::Cluster` | 35 clusters built on the cluster DSL, plus `Cluster::Registry` |
| Protocol | `Matter::Protocol` | `MessageHandler` and the objects it routes through, the interaction model handler, subscriptions |
| Commissioning | `Matter::Commissioning` | the failsafe, commissioning window and credential services |
| Session | `Matter::Session` | PASE and CASE, `SecureContext`, `SecureMessage` framing |
| Transport | `Matter::Transport` | the UDP transport, exchanges, message counters |
| Discovery | `Matter::MDNS` | the responder that answers commissionable and operational queries |
| Storage | `Matter::Storage` | backends, documents, records, the migrator — depends on nothing else |
| Primitives | `Matter::Codec`, `Crypto`, `Certificate`, `Datatype`, `InteractionModel`, `Error` | the wire codec, cryptography, certificates, id wrappers, statuses and paths |

`require "matter"` gives you all of that: it is the **device** library, and it has no controller
in it. Commissioning *other* devices — the mDNS scanner, the secure client, PASE/CASE pairing and
the commissioning flows — lives behind a second entrypoint:

```crystal
require "matter"            # build a device
require "matter/controller" # also commission and talk to other devices
```

Two more modules stay out of the default tree and are required explicitly:
`matter/storage/legacy` (the 0.1 storage importer) and `matter/storage/cli` (the `matter-storage`
binary). [docs/architecture.md](docs/architecture.md) follows a datagram through the whole stack.

## Building a device

A device is a `Matter::Device` subclass that declares what it is. This is the switch example in
full — `examples/matter_switch_device.cr` is the same class with an interactive console attached:

```crystal
require "matter"

# Development ids. Ship with a vendor and product id allocated by the CSA.
SWITCH_PRODUCT_ID = 0x8001_u16

class SwitchDevice < Matter::Device
  identity vendor: "Spider-Gazelle", product: "Crystal Switch",
    vendor_id: Matter::SetupPayload.test_vendor_id,
    product_id: SWITCH_PRODUCT_ID,
    discriminator: Matter::SetupPayload.generate_random_discriminator,
    pin: Matter::SetupPayload.generate_random_pin,
    device_type: Matter::DeviceType::ON_OFF_LIGHT,
    appearance: :satin

  storage yaml: "matter_switch_storage.yml"

  endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT do
    cluster Matter::Cluster::OnOff, feature_map: :lighting, as: :switch
    cluster Matter::Cluster::Identify, identify_type: :visible_light
    cluster Matter::Cluster::Groups
    cluster Matter::Cluster::ScenesManagement
  end

  on(:switch, :state_changed) do |state|
    puts "switch is now #{state ? "on" : "off"}"
  end
end

device = SwitchDevice.new
device.start          # returns as soon as the device is advertising
device.await_shutdown # blocks; call device.shutdown! to flush storage and stop
```

The declarations are:

* `identity` — vendor, product, ids, discriminator, setup pin and primary device type, plus the
  optional `appearance:`, hardware/software versions, `serial_number:` and `unique_id:`. Each value
  is evaluated once into a constant, so a randomised id stays stable for the life of the process.
* `storage yaml: "path"` / `storage json: "path"` / `storage :memory` — generates the constructor
  that opens the backend. Every `Device#initialize` argument stays available, so a spec can pass its
  own backend: `SwitchDevice.new(Matter::Storage::Memory.new)`.
* `network :ethernet | :wifi | :thread` — the Network Commissioning cluster's type and feature map.
* `endpoint number, device_type: do ... end` — an endpoint and, inside the block, one `cluster`
  declaration per cluster. `as: :switch` adds a typed accessor (`switch : Cluster::OnOff`).
  The endpoint is validated against its device types when it is registered, so a device type
  missing one of its mandatory clusters is an error at start-up rather than a controller
  complaining later.
* `endpoint_template :name, device_type:, parameters: {...} do ... end` — the shape of an endpoint
  added at runtime with `add_endpoint(:name, key: value)`. Template parameters are persisted, so
  dynamic endpoints survive a restart. `examples/matter_bridge_device.cr` uses this.
* `on(:accessor, :event) { |...| }` — binds a block to a cluster callback. Callbacks are wired once
  every endpoint exists, so one may reference an accessor on another endpoint.

The DSL rules are documented at the top of `src/matter/device/dsl.cr`, and the cluster DSL that
backs the cluster classes at the top of `src/matter/cluster/dsl.cr`.

### Cluster values

Cluster reads return `TLV::Any` or an interaction model status. Attribute writes take `TLV::Any`;
command requests and `CommandResponse#response` use `TLV::Any?`. Pass `TLV::Any.new(50_u8)` to
write a scalar or `request.to_tlv(nil)` for a `TLV::Serializable` command struct. Wire encoding
stays in the protocol layer.

## Examples

Ten example devices live in `./examples`, all written on the DSL.

* Build one with `crystal build examples/matter_switch_device.cr -o bin/matter_switch`
* Validate with [chip-tool](https://project-chip.github.io/connectedhomeip-doc/development_controllers/chip-tool/chip_tool_guide.html)
  * Launch `bin/matter_switch`, grab the chip-tool command line in the output
  * Clear any previous sessions: `chip-tool storage clear-all`
  * Commission using chip-tool

Confirmed working with iOS.

`examples/matter_level_control_device.cr` exposes a dimmable light with Groups on
endpoint 1, an extended color light on endpoint 2, and a window covering on endpoint 3.
The Docker e2e suite commissions it with the official chip-tool and exercises group
membership, hue, color temperature, and lift position commands.

### Example projects

These projects show off how custom matter interfaces can be built for almost any device.

* Control a [Home Connect oven](https://github.com/Crystal-Matter/homeconnect-oven-matter) using siri
* [Control a rangehood](https://github.com/Crystal-Matter/elica-rangehood-matter)
* Control a [Windows media center PC](https://github.com/Crystal-Matter/matter_media), plugged into your TV, from your phone

## Controller

`require "matter/controller"` adds the commissioner side: discovery, pairing and an interaction
model client. `examples/chip-tool.cr` is a full CLI built on it — see
[examples/chip-tool/README.md](examples/chip-tool/README.md).

CASE pairing can reuse a persisted secret after the first certificate exchange.
The Crystal chip-tool enables this with its controller store. Library callers
can share a `ResumptionStore` with their controller state backend:

```crystal
resume_store = Matter::Session::Case::ResumptionStore.new(state_store.backend)
pairing = Matter::Controller::Pairing::CasePairing.new(resumption_store: resume_store)
session = pairing.pair(client, peer, fabric, peer_node_id: node_id)
```

The first call performs full CASE and saves a record. Later calls, including
after restart, use Sigma2Resume when the peer recognizes that record; otherwise
the peer can answer with full Sigma2. Records are scoped to fabric root, fabric
ID, controller node ID, and peer node ID.

For one-way group commands, use a controller store backed by a durable file.
Provision the same epoch key and Group ID on each receiving device through
GroupKeyManagement, add endpoint membership through Groups, and grant a Group
ACL before sending. The controller retains only the derived operational key.

```crystal
group = Matter::Controller::GroupInvoker.new(client, store)
group.install_epoch_key(fabric.fabric_id, fabric.root_public_key,
  0x1234_u16, epoch_key)
group.invoke(fabric.fabric_id, 0x1234_u16,
  Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON,
  root_public_key: fabric.root_public_key)
group.write(fabric.fabric_id, 0x1234_u16,
  Matter::Cluster::LevelControl::CLUSTER_ID,
  Matter::Cluster::LevelControl::ATTR_OPTIONS, TLV::Any.new(1_u8, nil),
  root_public_key: fabric.root_public_key)
```

`invoke` and `write` select the controller identity on that fabric, reserve a durable
message counter, and send an authenticated private request to the fabric and
group multicast address. They have no response; confirm effects with a
separate CASE read if needed. Specify `controller_node_id:` as well when
multiple controller identities share a fabric. Install the new epoch key before
rotating a group's key set; `remove_group_key` erases the stored key.

Find commissionable devices:

```crystal
require "matter/controller"

DISCOVERY_WINDOW = 2.seconds

scanner = Matter::Controller::Scanner.new
scanner.start
scanner.query_commissioning
sleep DISCOVERY_WINDOW
scanner.commissioning_devices.each do |found|
  puts "discriminator #{found.discriminator} at #{found.addresses.first?}"
end
scanner.close
```

Commission one, then read an attribute over the operational session. Controller state — the
fabric, its certificates, the known nodes and the unsecured message counter — lives in a storage
backend, so the counter has to be written back before the process exits:

```crystal
require "matter/controller"

NODE_ID      = 0x1_u64
ENDPOINT     = 1_u16
PAIRING_CODE = "1495-753-5193"

store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new("controller.yml"))
state = store.load

client = Matter::Controller::Client.new(
  unsecured_source_node_id: state.commissioner_node_id,
  initial_unsecured_message_counter: state.unsecured_message_counter
)

begin
  # Discovers the device over mDNS from the discriminator in the pairing code,
  # runs PASE, installs the fabric's credentials and stores the node.
  # Supply DER PAA roots and CD signer P-256 public keys (uncompressed bytes)
  # from your own trust bundle. Test credentials are never loaded by default.
  # The verifier also checks the signed CD's optional DAC origin VID/PID and
  # authorized PAA SKID list against the attestation chain.
  paa_certificates = [File.read("trusted-paa.der").to_slice]
  cd_signers = {"CD_SIGNER_SKI_HEX" => File.read("cd-signer-p256.bin").to_slice}
  revocation_check = ->(_dac : Bytes, _pai : Bytes, _paa : Bytes) {
    # Replace with a trusted revocation source; unavailable is rejected.
    Matter::Controller::RevocationStatus::Unavailable
  }
  # For a local CRL bundle, use:
  # revocation_check = Matter::Controller::OfflineAttestationRevocation.new([
  #   File.read("paa.crl.der").to_slice, File.read("pai.crl.der").to_slice,
  # ]).callback
  trust = Matter::Controller::AttestationTrustStore.new(
    paa_certificates, cd_signers, revocation_check: revocation_check)
  verifier = Matter::Controller::DeviceAttestationVerifier.new(trust)
  commissioner = Matter::Controller::Commissioning::Commissioner.new(
    store, client, attestation_verifier: verifier)
  commissioner.pairing_code(NODE_ID, PAIRING_CODE)
  commissioner.close

  state = store.load
  fabric = state.fabric || raise Matter::CommissioningError.new("no controller fabric")
  node = state.nodes[NODE_ID]
  peer = Socket::IPAddress.new(node.address || "::1", node.port)

  session = Matter::Controller::Pairing::CasePairing.new
    .pair(client, peer, fabric, peer_node_id: NODE_ID)
  im = Matter::Controller::ImClient.new(client)

  report = im.read_attribute(
    session: session, peer: peer,
    endpoint_id: ENDPOINT,
    cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
    attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF
  )
  report.attribute_reports.try &.each do |attribute_report|
    puts attribute_report.attribute_data.try &.data.try &.value
  end

  im.invoke(
    session: session, peer: peer,
    endpoint_id: ENDPOINT,
    cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
    command_id: Matter::Cluster::OnOff::CMD_TOGGLE
  )
ensure
  state.unsecured_message_counter = client.transport.message_counter.counter
  store.save(state)
  client.close
end
```

`OfflineAttestationRevocation` accepts DER CRLs provisioned by the host. It
verifies the issuer, authority key identifier, CRL signature, signing usage,
CRL number, and update interval for both the PAA and PAI before deciding that
a DAC chain is clear. Missing, stale, or invalid coverage returns `Unavailable` and blocks
commissioning. The host must obtain the CRLs through a trusted channel;
automated DCL retrieval, partitioned CRLs, and indirect CRL signers are not
implemented by this local provider.

For DCL revocation points with direct, partitioned, or delegated CRLs,
`DclAttestationRevocation` can query an explicitly selected HTTPS DCL
gateway and download CRLs from explicitly approved HTTPS hosts:

```crystal
source = Matter::Controller::HttpDclRevocationSource.new("https://<trusted-dcl-gateway>")
revocation = Matter::Controller::DclAttestationRevocation.new(
  source, Set{"<approved-crl-host>"})
trust = Matter::Controller::AttestationTrustStore.new(
  paa_certificates, cd_signers, revocation_check: revocation.callback)
```

Some DCL records contain HTTP CRL URLs. A host may explicitly opt into those
using `allowed_http_crl_hosts: Set{"<approved-http-crl-host>"}`. The default
accepts HTTPS only. The downloader permits only the standard port for each
scheme, rejects redirects, and reads at most 1 MiB before buffering a CRL.
HTTP content is authenticated by the CRL signature and update interval, but
an on-path attacker can withhold a newer CRL until the signed `nextUpdate`;
the deployment must decide whether this tradeoff is acceptable.

The DCL gateway must be authenticated and kept current by the deploying
application. A partition set is accepted only when every point has a unique
label and URL, and every CRL has a critical Issuing Distribution Point URI
equal to its DCL URL. A delegated signer must chain directly to the candidate
PAA or PAI and satisfy the Matter 1.6 CRL signer profile. Missing or invalid
coverage, unsupported IDP scope flags, delta CRLs, and unknown DCL digest
metadata return `Unavailable`; commissioning then fails closed. The library does not infer an
approved CRL host from the DCL's `dataURL`. An injected `DclRevocationSource`
can use a separately authenticated DCL mirror; it must supply the complete
point set with `vendor_id`, `label`, and `product_id` where the PAI carries one.
An injected fetch callback must
apply the same byte limit, scheme/host/port allowlist, and redirect policy.

`ImClient` also has `write_attribute`, `write_attributes` and `invoke`. Large
list writes are sent as an empty replacement followed by append items in
bounded WriteRequest chunks on one exchange. The client waits for each
WriteResponse, stops after a failed status, and returns the collected statuses.
Timed writes that would require multiple chunks fail before sending.
`subscribe`, `subscribe_events`, `subscribe_attributes` and `subscribe_attribute`
accept `keep_subscriptions: true` to set the SubscribeRequest KeepSubscriptions
field. The default is `false`.
`Commissioning::CommissioningWindowOpener` opens an enhanced commissioning window on an already
commissioned node and hands back a manual pairing code for it.

### Sharing a fabric between controllers

An existing controller that owns a fabric's root signing key can issue a
separate operational identity to another controller. Both identities use the
same fabric ID, trust root, and IPK, but have distinct Node IDs and private
keys. Provision the second controller into an empty store:

```crystal
authority = authority_store.load.fabric || raise Matter::ConfigurationError.new("no authority fabric")
delegate = Matter::Controller::SharedFabric.delegate(authority, 0x102_u64)
Matter::Controller::SharedFabric.install(delegate_store, delegate)
```

Use `delegate_store.load.fabric` with `Pairing::CasePairing#pair` to connect
to a device on the fabric. An existing administrator must grant the new
controller access on each device. With its active administrator CASE session:

```crystal
Matter::Controller::SharedFabric.grant_admin(im, session, peer, delegate.controller_node_id)
```

The delegated store intentionally has no CA signing key. To commission a new
device from that controller, keep the authority in a separate store and pass
a certificate issuer and a trusted device attestation verifier to
`Commissioning::Commissioner` (construct `verifier` as in the controller
example above):

```crystal
commissioner = Matter::Controller::Commissioning::Commissioner.new(
  delegate_store,
  client,
  certificate_issuer: Matter::Controller::SharedFabric.issuer(authority),
  attestation_verifier: verifier
)
commissioner.pairing_code(new_device_node_id, pairing_code)
```

When that fabric has a Matter 1.6 Joint Fabric Datastore Anchor, opt in to
node lifecycle registration. The controller store must already contain the
Anchor's operational Node ID and address. The registrar uses the controller's
CASE identity to call AddPendingNode before the new device's final CASE,
RefreshNode after CommissioningComplete, and RemoveNode when commissioning
fails before completion. No root signing key is sent to the Anchor.

```crystal
delivery = Matter::Controller::DatastoreNodeRegistrar::NetworkDelivery.new(
  delegate_store, client, anchor_node_id, datastore_endpoint
)
registrar = Matter::Controller::DatastoreNodeRegistrar.new(delegate_store, delivery)
commissioner = Matter::Controller::Commissioning::Commissioner.new(
  delegate_store, client,
  certificate_issuer: Matter::Controller::SharedFabric.issuer(authority),
  attestation_verifier: verifier,
  datastore_registrar: registrar
)
commissioner.pairing_code(new_device_node_id, pairing_code, friendly_name: "Living room lamp")
```

Call `registrar.resume(delegate_store.load.fabric.not_nil!)` after a restart
to retry an interrupted RefreshNode or clean up a pending registration after
the fail-safe deadline. If CommissioningComplete was sent but its result was
lost, the registrar retains an ambiguous entry and raises; verify the device's
fabric state before calling `registrar.complete(fabric, node_id)` followed by
`registrar.refresh(fabric, node_id)`, or `registrar.abort(fabric, node_id,
confirmed_failure: true)` if the device did not join. A known failed
CommissioningComplete response is cleaned up automatically.
`JointCommissioning::Workflow` accepts the same registrar through its
`datastore_registrar:` option and uses the Administrator name as the node's
friendly name.

Grant each controller access to the new device with `SharedFabric.grant_admin`
over the commissioning controller's CASE session. The ACL has a minimum of
four entries per fabric; large controller groups need an ACL strategy that
fits the target device's limits.

This provides shared trust and explicit ACL administration for a locally owned
fabric. Matter 1.6 Joint Fabric support is in progress: the Administrator and
Datastore clusters, VID verification, CAT-aware commissioning, Anchor-led
Joint Commissioning, Datastore RefreshNode, and Anchor transfer are exercised
between Crystal devices in Docker. See
[Joint Fabric status](docs/matter_1_6_joint_fabric.md) for current coverage and
the remaining interoperability work.

For a Joint Fabric, a controller identity can carry a group CAT issued under
the local Administrator ICAC. Grant access through the Anchor Datastore so it
propagates the group membership and ACL to the target node:

```crystal
joint_delegate = Matter::Controller::SharedFabric.delegate_joint(
  joint_authority, controller_node_id, group_cat, group_cat_version)
Matter::Controller::SharedFabric.grant_joint_admin(
  im, anchor_case_session, anchor_peer, datastore_endpoint,
  device_node_id, device_endpoint, group_id, group_name, joint_delegate)
```

Wait for the Datastore entries to become Committed before the delegated
controller opens CASE to the device. The ICAC signing key stays with
`joint_authority`.

## Error handling

Everything the library raises on its own behalf descends from `Matter::Error`:

| Error | Raised for |
|---|---|
| `CodecError` | malformed messages, TLV and DER |
| `CryptoError` / `AuthenticationError` | key and cipher failures; a failed decrypt or signature |
| `CertificateError` | attestation and operational certificate problems |
| `StorageError` | an unreadable, closed or newer-schema store |
| `SessionError` | missing, expired or exhausted sessions |
| `ProtocolError` / `TimeoutError` | exchange and interaction model failures |
| `CommissioningError` | failsafe, window and credential failures |
| `TransportError` | socket and datagram failures |
| `ConfigurationError` | a device or cluster declared incorrectly |
| `ClusterError` | carries an interaction model status back to the wire |

Nothing raises a bare string, so `rescue error : Matter::StorageError` is a reliable way to react
to one class of failure. Inside a cluster you rarely need to: an exception escaping a command
handler or an attribute write is converted to an interaction model status at the boundary, so a
hostile payload cannot make the device drop the exchange.

Statuses are built with factories rather than enum literals, one per usable status code:

```crystal
require "matter"

status = Matter::InteractionModel::Status.success
status = Matter::InteractionModel::Status.unsupported_attribute
status = Matter::InteractionModel::Status.constraint_error

# `Failure` carrying a cluster-specific code
status = Matter::InteractionModel::Status.cluster_failure(
  Matter::Cluster::DoorLock::StatusCode::InvalidField
)
```

## Logging

Log sources mirror the file tree, so a subsystem can be turned up on its own:
`matter.session.pase`, `matter.protocol.message_handler`, `matter.transport.udp_transport`,
`matter.cluster.level_control`. A file without its own source falls back to its namespace
(`matter.storage`, `matter.mdns`), and a spec fails if a source ever drifts from its path.

Examples log at `info` by default; set `MATTER_LOG` to change the level (specs use
`MATTER_SPEC_LOG` the same way, defaulting to `warn`):

```
MATTER_LOG=debug bin/matter_switch
MATTER_SPEC_LOG=trace crystal spec
```

Applications wire this up themselves — `Log.setup` with a
[Log::Builder](https://crystal-lang.org/api/Log.html) if a single level is not enough:

```crystal
require "matter"

Log.setup do |config|
  config.bind "matter.*", :info, Log::IOBackend.new
  config.bind "matter.session.*", :debug, Log::IOBackend.new
end
```

## Storage

Device state (fabrics, sessions, subscriptions, cluster state, identity) is persisted
through `Matter::Storage::Backend`. Three backends ship with the library:

* `Matter::Storage::YamlFile` - one human readable YAML file (recommended)
* `Matter::Storage::JsonFile` - the same layout as JSON
* `Matter::Storage::Memory` - nothing persisted; state is rebuilt on every start

A store is a set of *collections* (`fabrics`, `sessions`, `subscriptions`, `device`,
`clusters`, `app`, `meta`), each holding *documents* keyed by id, so a file looks like
`{collection: {id: document}}`. Documents hold 64-bit integers, floats, booleans,
strings, byte strings, timestamps, arrays and nested maps. Bytes are written as
`!!binary` base64 in YAML and `{"$bytes": "<base64>"}` in JSON; timestamps as
`!!timestamp` / `{"$time": "<RFC 3339 UTC>"}`. `meta/schema` records the layout version.

Writes are debounced through `Matter::Device::Persistence` into a single transaction, and
`Device#shutdown!` flushes them, so cluster state survives a crash and not only a clean shutdown.
`persistence.reset!` factory-resets a device.

`bin/matter-storage` (built with `shards build matter-storage`) copies and prints stores.
Store URIs are `memory:`, `yaml:<path>`, `json:<path>`:

```shell
bin/matter-storage migrate --from json:matter_storage.json --to yaml:matter_storage.yml
bin/matter-storage inspect yaml:matter_storage.yml   # keys, certs and byte strings are redacted
```

Devices that ran a release before the storage refactor wrote a different flat JSON file
(`{"<context>": {"<key>": <json string>}}`). Convert it once with the `legacy:` scheme:

```shell
bin/matter-storage migrate --from legacy:matter_storage.json --to yaml:matter_storage.yml
```

Unrecognised entries are kept under `app/legacy-<context>-<key>` and each is reported with
a warning, so nothing is dropped silently. The importer lives in `src/matter/storage/legacy/`
and is only loaded by `require "matter/storage/legacy"` (the CLI does this); it is a
temporary module that will be removed once deployed devices have migrated.

## End to end tests

The full suite (unit specs + chip-tool driven end-to-end specs against every example
device) runs inside docker compose, so the only requirement is Docker with compose v2
(Docker Desktop on macOS, or docker engine 27+ on Linux):

```shell
./test                 # build images, run everything, tear down, exit 0/1
./test --e2e-only      # skip the unit specs
./test --unit-only     # only the unit specs
./test -- e2e/spec/switch_spec.cr   # a single e2e spec file
```

* `docker-compose.yml` starts one container per `examples/matter_*_device.cr` and a
  `tests` container built from the official [chip-tool](https://github.com/matter-js/matter.js-chip)
  image with crystal added.
* `e2e/spec/*_spec.cr` are regular crystal specs that commission each device with
  `chip-tool pairing code` (mDNS discovery over the compose network) and then read
  and write the relevant cluster attributes.
* Container logs (device output, pairing codes, protocol debug logs) are saved to
  `tmp/e2e/logs/` after every run.

Persistence is checked by restarting devices in place. The `tests` container has no
docker socket, so `E2E::Device#restart!` creates a marker file
`/e2e/logs/<example>.restart` on the shared log volume; `e2e/device-entrypoint.sh`
(a small supervisor loop) removes it, sends `SIGTERM` to the device for a clean
shutdown, appends `=== e2e restart <n> ===` to `<example>.log` and starts the binary
again in the same working directory, where its storage lives. The spec then waits for
the operational-mode banner after that line and checks that no new pairing code was
printed before reading the persisted state back with chip-tool. A device that exits
without a restart having been requested takes its container down with its exit code.

The same validation can be run directly on the host against a locally installed
chip-tool:

```shell
./examples/run_validation.sh
```

We have our own implementation of chip-tool for running end-to-end tests too (used in the CI)
Aiming to be compatible with the official tool

```shell
crystal build ./examples/chip-tool.cr -o ./bin/chip-tool --error-trace
./examples/run_validation.sh --chip-tool ./bin/chip-tool
```

## Contributing

1. Fork it (<https://github.com/Crystal-Matter/matter/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Stephen von Takach](https://github.com/stakach) - creator and maintainer
