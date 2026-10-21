# Changelog

All notable changes to this project are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The 0.2 refactor. Every layer of the library was reworked: storage, the device API, all 35
clusters, the interaction model and the protocol objects. It is a breaking release, and
**device storage written by 0.1 will not load** — see [Migrating from 0.1](#migrating-from-01).

### Shared fabric and certificate validation

- Add delegated controller identities on an existing fabric, a separate
  certificate issuer for commissioning, and an ACL grant helper for shared
  controller access.
- Validate controller CASE peer certificates and device NOC updates against
  the fabric trust root, signed validity period, and intermediate fabric ID;
  bind commissioned NOCs to the device CSR key.
- Store multiple controller fabrics with explicit selection and fabric-scoped
  known nodes; retain authenticated CASE CATs across session persistence.
- Complete the TimedRequest handshake for controller writes and invokes, and
  expose Matter 1.6 Basic Information revision and version attributes.
- Consume chunked controller Read reports through the Interaction Model
  acknowledgement ladder, with bounded accumulation, global status handling,
  and list item reassembly for split attribute arrays.
- Add Matter 1.6 Joint Fabric Administrator and Datastore cluster schemas,
  VID verification commands, a persistent Joint Commissioning workflow,
  Datastore propagation, and a dedicated administrator example. Two Crystal
  administrators complete JCM in Docker, including mutual VID verification
  and ICAC cross-signing. Add journaled Anchor transfer participant follow-up
  and consent-gated Administrator removal with CAT/NOC rotation. A two-JFA
  Docker test covers network transfer, removal, and lost-acknowledgement
  reconciliation. The Anchor JFA now completes the deferred JCM handoff, and
  the former Anchor subscribes to the new Anchor Datastore after transfer.
  A separate Docker test covers offline propagation failure and live
  RefreshNode endpoint/ACL reconciliation. Broader lifecycle and official SDK
  JFA interoperability remain to be verified; see
  [the status page](docs/matter_1_6_joint_fabric.md).

### Added

#### Device API

- `Matter::Device` gained a declarative DSL: `identity`, `storage`, `network`, `endpoint`,
  `endpoint_template` and `on`. A device class now declares its identity, its storage backend,
  its endpoints and their clusters, and binds callbacks to typed cluster accessors (`as: :switch`
  generates `switch : Cluster::OnOff`). Documented at the top of `src/matter/device/dsl.cr`.
- `endpoint_template :name, device_type:, parameters: {...}` describes an endpoint added at
  runtime with `add_endpoint(:name, key: value)`. Template parameters are persisted, so dynamic
  endpoints (bridges) come back after a restart without hand-rolled persistence.
- `Matter::Node` and `Matter::Endpoint` own the cluster registry. Endpoints hold their clusters,
  a flat index keeps protocol lookups O(1), descriptor population and scene wiring live on
  `Endpoint`, and `Node#add_endpoint` validates the endpoint against its declared device types.
- `Matter::Device::Persistence` owns the storage backend, the fabric table, protocol persistence,
  device identity, application documents, orphan cleanup, `flush`, `close` and `reset!`.
  Dirty state is written through a debounce into a single transaction.
- `examples/support/` provides a shared interactive console and `Examples.main`, used by all ten
  example devices.

#### Storage

- A new storage layer under `Matter::Storage` that depends on nothing else in the library:
  `Storage::Backend` (collections of documents, transactions, `destroy!`) with three
  implementations — `Storage::Memory`, `Storage::YamlFile` and `Storage::JsonFile` (the latter two
  over a shared `FileBackend` doing atomic write, fsync and mutex).
- A document model of `Nil | Bool | Int64 | UInt64 | Float64 | String | Bytes | Time | Array | Hash`,
  laid out as `{collection: {id: document}}` across the `fabrics`, `sessions`, `subscriptions`,
  `device`, `clusters`, `app` and `meta` collections. Files are human readable; `Bytes` and `Time`
  are first-class.
- `meta/schema` records the storage layout version.
- `Storage::Record`, a macro that derives `to_document`/`from_document` from a type's instance
  variables. Fabrics, sessions, subscriptions, cluster state, device identity, bridge documents and
  controller state are all records.
- `Storage::Migrator` and the `matter-storage` shard target (`shards build matter-storage`), with
  `migrate` and `inspect` subcommands over `memory:`, `yaml:<path>` and `json:<path>` store URIs.
  `inspect` redacts keys, certificates and byte strings.
- A one-shot importer for the 0.1 flat JSON file, isolated behind `require "matter/storage/legacy"`
  and the `legacy:<path>` store URI. Entries it does not recognise are preserved under
  `app/legacy-<context>-<key>` with a warning, so nothing is dropped silently. This module is
  temporary and will be deleted once deployed devices have migrated.
- `Matter::Debouncer` (single fiber, `trigger`/`flush`/`cancel`) backing the cluster, fabric and
  session writes.

#### Clusters

- A declarative cluster DSL (`src/matter/cluster/dsl.cr`): `cluster`, `feature`/`conflicts`,
  `attribute`, `command`, `event`, `before_write`/`after_write`. It generates the id constants,
  typed accessors with change notification, memoised metadata tables, feature-gated read/write/command
  dispatch, constraint validation, the global attribute lists and the persistence record.
  Keywords added during the migration: `computed:`, `present_if:`, `event ... requires:`,
  `before_write` value replacement, `cluster ... name:`, `persist_state: false`, `command ... handler:`,
  generated `CMD_<NAME>_RESPONSE` constants and constant `requires:`.
- A mandatory command without a handler, or a computed attribute without a reader, is now a
  compile error.
- `Matter::Cluster::Registry` maps cluster ids to cluster classes at compile time.

#### Events

- `Matter::EventJournal` on `Node`, with per-priority rings.
- `Cluster::Base#emit_event` and the DSL's generated `emit_<name>` helpers.
- `EventDataIB`, `EventStatusIB` and `EventReportIB`; `IMHandler` reads events sharing the report
  chunk budget; subscriptions carry event paths and a persisted cursor, and urgent events bypass
  the minimum-interval damping.
- Door Lock and both Basic Information clusters emit events.

#### Errors and the interaction model

- A `Matter::Error` hierarchy: `CodecError`, `CryptoError`/`AuthenticationError`, `CertificateError`,
  `StorageError`, `SessionError`, `ProtocolError`/`TimeoutError`, `CommissioningError`,
  `TransportError`, `ConfigurationError` and `ClusterError`. No bare-string raises remain in `src/`.
- `InteractionModel::Status` factory methods (`Status.success`, `Status.unsupported_attribute`,
  `Status.cluster_failure(code)`, …), generated from the status enum.
- Cluster-specific status codes now reach the wire through `StatusIB.cluster_status`.

#### Protocol and commissioning

- `Session::SecureMessage.encode`/`.decode` centralise encryption, nonce construction and framing
  behind one definition of the authenticated data.
- `Protocol::MrpCache`, `Protocol::SessionRegistry`, `Protocol::SubscriptionManager`,
  `Protocol::SecureChannel`, `Protocol::InteractionRouter` and `Protocol::ResponseSender` — the
  pieces `MessageHandler` was decomposed into.
- A `Matter::Commissioning` module holding `FailsafeService`, `WindowService` and `CredentialService`,
  with the cluster require cycle broken by `RollbackTargets`.
- The mDNS responder answers subtype PTR queries (`_L`, `_S`, `_T`, `_V`, `_CM`) and instance
  queries, and sends a three-packet announcement burst.
- `Crypto::MatterCertificate::Asn1` renders an operational certificate as the ASN.1 DER its issuer
  signed, `::Validation` verifies a node certificate against its intermediate and root, and `::Builder`
  issues a root and the node certificates under it. Checked against the operational certificates of
  the specification and of Apple, Google, Amazon, SmartThings and Aqara.

#### Controller and tooling

- `require "matter/controller"` is the controller entrypoint: the mDNS scanner, secure client,
  PASE/CASE pairing and the commissioning flows. The core library is device-only.
- `MATTER_LOG` sets the log level for the examples; `MATTER_SPEC_LOG` does the same for the specs
  (defaulting to `warn`).
- `Matter::Hex` and `Matter::Network.local_ip_addresses` replace copy-pasted helpers.
- End-to-end persistence coverage: devices are restarted in place inside the compose network and
  their state is read back with chip-tool.
- CI type-checks every example, the storage CLI and the e2e helpers.
- The in-repo controller is a real certificate authority: it signs its root, and the node certificates
  it issues to itself and to each device it commissions. `Controller::FabricInfo` gained
  `root_private_key`; a fabric stored without one can still connect to the devices it commissioned but
  cannot commission new ones.

### Changed

- **The `tlv` shard moved to 2.0.0, which brings `bindata` 3.x.** 1.1.0 fixed a decoder gap this
  library hit: a type registered through `define_id` encoded as a field but could not be decoded once
  the field was nilable, because the decoder's union branch matched a closed list of members. 2.0.0 is
  the bindata bump, a major because `TLV::Header` is a `BinData` and so a consumer cannot hold
  bindata 2.x alongside it.
- **`Device::Base` is now `Matter::Device`**, with the runtime in `src/matter/device/runtime.cr`.
- **`Device.new` takes a storage backend**; `build_storage_manager` is gone.
- **All 35 cluster classes and files dropped the `Cluster` suffix**: `Cluster::OnOffCluster` in
  `cluster/on_off_cluster.cr` is `Cluster::OnOff` in `cluster/on_off.cr`.
- **`Cluster::Definitions::*` were folded into the cluster classes** they belong to (large ones under
  `cluster/<name>/types.cr`; wire structs that collide with a domain type live in a nested `Tlv`
  module). `cluster/definitions/` is gone.
- **`EntryPrivilege` moved to `InteractionModel`** (`interaction_model/access.cr`).
- **`CLUSTER_REVISION` is the revision value** in every cluster, not the attribute id; the base macro
  generates the `cluster_revision` accessor. Every cluster now declares its real specification revision.
- **The cluster boundary is `TLV::Any`.** Reads return `TLV::Any` or an interaction model status;
  writes and command requests take `TLV::Any`; `CommandResponse#response` is `TLV::Any?`. Wire
  encoding stays in the protocol layer.
- **`MDNS::Scanner` is `Controller::Scanner`.**
- **`Constants::DeviceTypes` (16-bit) is `Matter::DeviceType` (32-bit)**, one registry.
- `src/matter.cr` is an explicit, layered require tree with one aggregator per subsystem; the `**`
  glob is gone and `require "matter"` loads the device library only.
- `MessageHandler` went from 2635 to 364 lines and now only routes; handshakes are keyed by exchange
  id, the session registry owns the one lock, and the subscription manager has a single chunk ladder.
- Operational Credentials (1570 → 591 lines), Administrator Commissioning (694 → 335) and General
  Commissioning (725 → 473) are thin fronts over the commissioning services.
- CASE has one certificate validation and one key derivation path.
- `SecureContext` owns the single message counter implementation; there is no longer a second one.
- Datatype id wrappers are value structs generated by one macro, with equality, hash, TLV encoding
  and `to_s`.
- Cluster enums use `UInt8` bases so they encode as `enum8`.
- Log sources mirror the file tree (`matter.session.pase`), with namespace fallbacks; a spec fails on
  drift.
- Exceptions raised inside a cluster are mapped to interaction model statuses at the boundary
  (`invoke_command`, `write_attribute`, `IMHandler.safe_invoke_command`), so a hostile payload can no
  longer make the device drop the exchange.
- Wire-reachable raises became statuses: Network Commissioning `OutOfRange`, Group Key Management
  `ResourceExhausted`/`NotFound`/`ConstraintError`, Administrator Commissioning
  `ConstraintError`/`Busy` and the PAKE codes.
- An optional attribute with no value is absent from `AttributeList` and rejects writes; an
  undecodable ACL or Extension write answers `InvalidDataType` like every other DSL write;
  `CurrentFabricIndex` has no setter.
- Reading the ACL and Extension attributes requires the Administer privilege.
- A corrupt storage file is renamed `.corrupt-<timestamp>` instead of being wiped.
- Silent rescues now log with context; hot-path logs are `debug` and no longer dump payloads.
- Controller state persists through a storage backend; the chip-tool example writes `controller.yml`.
- The ten example devices were rewritten on the device DSL (3383 → 1191 lines plus 347 shared).
- `spec/` mirrors `src/`, with `spec/compatibility/` holding the matter.js and iPhone golden vectors.

### Fixed

#### Wire format and interoperability

- The destination group id was encoded as 32 bits; it is 16 bits. Group-addressed messages were
  malformed on the wire.
- The authenticated data for message encryption is now the complete message header, including the
  optional node ids, in both directions — previously the two directions disagreed.
- Groups, Colour Control and Window Covering decoded command payloads as raw little-endian slices
  instead of TLV. They now consume annotated request structs, and the real TLV requests that failed
  before pass.
- Door Lock event and response payloads typed their fabric index and source node as datatype wrappers
  with no TLV encoder, so every lock command failed against chip-tool once a node wired the event
  callback.
- The CASE initiator used neither the specification salts nor its constants, so it could never have
  interoperated.
- The CASE responder decrypted Sigma3 and took the peer's node id and CATs from the certificate inside
  it without ever verifying the signature over `TBS_Data3`. The certificate was therefore only a claim:
  anyone who reached Sigma3 could replay a node operational certificate read off the wire and inherit
  its node id, its CASE authenticated tags and every access control entry written for them. The
  responder now verifies the signature against the public key the certificate carries and drops the
  handshake when it does not match.
- A basic commissioning window advertised a discriminator of `0`.
- Fan `Step` and the signed Thermostat commands never reached their handlers; they now go through the
  same dispatch path as every other cluster.
- Scene extension fields survive `Add`/`View`/`Recall` and persistence, including numeric On/Off
  scene booleans.
- Group Key Management commands were not reachable over the wire, and the cluster did not bump its
  data version on mutation.
- The Carbon Dioxide Concentration Measurement cluster reported an empty feature map.
- A command carrying a value outside its enum answers `InvalidCommand` instead of raising.
- Null writes to Level Control attributes are handled.

#### Sessions, subscriptions and storage

- Reordered authenticated datagrams within the receive window are accepted; a failed authentication
  can no longer advance a counter or cancel a cleanup.
- Two cleanup fibers could race each other.
- A subscription completed by a standalone acknowledgement was never persisted, so it was lost on
  restart.
- Handshake state was never cleared after Sigma3, and two commissioners could collide on it.
- The session sweep could write to a closed store; the dirty session set is now locked.
- Fabric ids above `Int64::MAX` survive a round trip — the 0.1 loader silently factory-reset on them.
- One malformed entry made the fabric table load wipe the whole table.
- The persistence redaction regex did not match, so keys were logged in the clear.
- Node id range checks and the group node id byte order were wrong.
- The memory backend handed out its live hash.
- Cluster state survives a crash, not only a clean shutdown.
- A duplicate `window_open?` definition and several enum alias conflicts.

### Removed

- `Storage::Base`, `Storage::Manager`, `Storage::JsonFileBackend` and `Storage::MemoryBackend`,
  together with the JSON-in-JSON key/value layout they wrote. The old `Storage::Scalar` value
  alias is gone; `Storage::Type` is now the document value type, narrowed to what a document can
  actually hold (`Int64`/`UInt64`/`Float64` rather than every width, plus `Time`).
- `Device::Base#build_storage_manager`, `Persistence.redact` and the hand-rolled `to_h` /
  `PersistedState` JSON structs.
- The legacy mDNS stack: `MDNS::Advertiser`, `MDNS::Server`, `MDNS::MulticastSocket`,
  `MDNS::ServiceDescription` and `MDNS::CommissionableAdvertisement`.
- `CommissioningController`, `CommissioningServer`, `CommissioningWindow`, `FabricManager`,
  `SessionManager`, `Protocol::SessionManager`, `Matter::Logger`, `Matter::Schema::*`,
  `Utilities::Cache` and `Utilities::DeepEqual` — all dead.
- The legacy Scenes cluster (`0x0005`), deprecated since Matter 1.3, and 32 unused cluster
  definitions.
- The `Constants::DeviceTypes` (16-bit) registry, and the `FabricId`, `VendorId`, `SubjectId` and
  `FabricIndex` datatype wrappers. A fabric index is a bare `UInt8`; `DataType::NO_FABRIC` names
  the specification's reserved index 0.
- `FabricTable#export` / `#import`, five never-wired commissioning callbacks, the dead second
  interaction model path, and the transport's MRP retransmit engine (it had no caller and could
  never have run).
- `Session::Case.validate_certificate_chain` and its two wrappers. It parsed X.509 DER, so it could
  never have read the Matter TLV certificate a CASE peer presents; nothing outside its own spec called
  it. Chain validation is `Crypto::MatterCertificate::Validation`.
- The CASE Sigma3 "test compatibility" fallback — the handshake now fails closed on a decrypt or
  signature failure.
- DER decoding and the X.509 helpers; `DERCodec` is limited to the certification declaration encoder.
- The raw byte width helpers, the TLV null sentinel and the per-cluster `encode_*` helpers made
  redundant by the `TLV::Any` boundary.

## Migrating from 0.1

**Storage.** The file format changed completely, and 0.1 files will not load. Convert each device's
storage once, offline:

```shell
shards build matter-storage
bin/matter-storage migrate --from legacy:matter_storage.json --to yaml:matter_storage.yml
bin/matter-storage inspect yaml:matter_storage.yml
```

Fabrics, sessions, subscriptions, cluster state and the device identity are carried over, so
commissioned controllers stay paired. Anything the importer does not recognise lands in
`app/legacy-<context>-<key>` and is reported with a warning. The `legacy:` scheme is temporary.

The in-repo chip-tool example writes `controller.yml` where it used to write `controller.json`;
delete the old file and re-commission, or migrate it the same way.

**Device classes.** Subclass `Matter::Device` instead of `Matter::Device::Base` and drop
`build_storage_manager`: `Matter::Device#initialize(storage : Storage::Backend, ip_addresses, port,
hostname, max_fabrics)` takes the backend itself, so pass a
`Matter::Storage::YamlFile.new("my_device_storage.yml")`. The lifecycle methods are `start`,
`await_shutdown` and `shutdown!`.

Most devices can go further and use the DSL — `identity`, `storage`, `network`, `endpoint` and `on` —
which replaces the constructor, the endpoint construction and the callback wiring. The ten examples
under `examples/` are all written this way.

**Clusters.** Drop the `Cluster` suffix from every class name (`Cluster::OnOffCluster` →
`Cluster::OnOff`) and reference the types that were in `Cluster::Definitions::OnOff` on the cluster
class itself. `EntryPrivilege` is now `InteractionModel::EntryPrivilege`. If you read
`CLUSTER_REVISION` expecting an attribute id, it is the revision value now.

**Cluster values.** Reads return `TLV::Any` or a status, and writes and commands take `TLV::Any`:
pass `TLV::Any.new(50_u8)` for a scalar, or `request.to_tlv(nil)` for a `TLV::Serializable` command
struct.

**Requires.** `require "matter"` no longer pulls in the controller; add `require "matter/controller"`
if you commission other devices. The legacy storage importer is behind
`require "matter/storage/legacy"`.

**Errors.** Rescue `Matter::Error` (or one of its subclasses) rather than matching on exception
messages, and build statuses with the factories — `InteractionModel::Status.success`,
`.unsupported_attribute`, `.cluster_failure(code)`.
