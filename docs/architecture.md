# Architecture

How a datagram becomes a cluster read, and where everything else sits. File paths are relative to
`src/`, and every name below is a real class or method — the code is the authority, this is the map.

## Layers

The library is a stack. `src/matter.cr` requires it bottom-up, one aggregator per subsystem, with
no glob requires, so a layer can only reach downwards.

```
                      Matter::Device            device.cr, device/{dsl,runtime,persistence,lifecycle_manager}.cr
                              |
        Matter::Node / Endpoint / EventJournal   node.cr, endpoint.cr, event_journal.cr
                              |
                     Matter::Cluster            cluster/*.cr (38 clusters + dsl.cr + registry)
                              |
        Matter::Protocol      |      Matter::Commissioning
   protocol/*.cr              |      commissioning/*.cr
                              |
                     Matter::Session            session/{pase,case}/*.cr, secure_message.cr, context.cr
                              |
                    Matter::Transport           transport/{udp_transport,btp_codec,exchange,message_counter}.cr
                              |
   Matter::MDNS   Matter::Network   Matter::Storage   Matter::Codec / Crypto / Certificate
   mdns/*.cr      network/*.cr      storage/*.cr      codec/*.cr, crypto/*.cr, certificate/*.cr
                              |
      Matter::Datatype   Matter::InteractionModel   Matter::Error   Matter::Hex
```

`Matter::Storage` is the strictest of these: it requires nothing from the rest of the library, which
is why it can be driven by the `matter-storage` CLI on its own.

`Matter::Network.local_ip_addresses` supplies the device runtime's mDNS A/AAAA records. On Unix it
enumerates addresses on active, non-loopback interfaces, including local IPv6 addresses that have
no public route. It uses IPv4 loopback only when no usable interface address exists. Windows uses
outbound route probes until native interface enumeration is available there.

`Transport::ExchangeManager` keys each exchange by session, numeric exchange ID,
local initiator role, and peer address. Two controllers or opposite initiators
may use the same numeric ID without taking over each other's exchange state.

`Transport::BtpCodec` encodes and validates Matter BLE BTP handshakes and data
segments. It does not manage a BLE connection or BTP send and receive windows;
the current controller client still uses UDP for PASE and CASE.

Two rules keep the tree honest:

* `require "matter"` is the **device** library. The controller — scanner, client, PASE/CASE pairing,
  commissioner — is behind `require "matter/controller"`, and nothing in the device tree may
  reference it.
* `matter/storage/legacy` (the 0.1 importer) and `matter/storage/cli` are not in the default tree
  either. Both are required explicitly by the CLI.

## The inbound path

```
                          UDP :5540
                              |
  transport/udp_transport.cr  v
  UDPTransport#receive_loop -> #handle_received_data
      decode_packet, drop runts, dedupe unsecured counters,
      answer unsecured messages that need an ack
                              |
                              v  on_message callback
  protocol/message_handler.cr
  MessageHandler#handle_message               (inside SessionRegistry#synchronize)
      session_id == 0 ? unsecured : look up the session, check its peer counter
        Duplicate -> MrpCache#resend?  (the cached response goes out; no handler runs)
        Stale     -> drop
        Ok        -> Session::SecureMessage.decode
                              |
                    #route on the protocol id
             +----------------+-----------------+
             |                                  |
   SecureChannel#handle                InteractionRouter#handle
   protocol/secure_channel.cr          protocol/interaction_router.cr
     PbkdfParamRequest / Pake1 / Pake3   ReadRequest / SubscribeRequest
     Sigma1 / Sigma3 / StatusReport      WriteRequest / InvokeRequest / TimedRequest
     StandaloneAck -> SubscriptionManager#advance
             |                                  |
     session/{pase,case}                protocol/im_handler.cr
     PaseResponder / CaseResponder      IMHandler.parse_* then
             |                            .read_attributes / .write_attributes
   SessionRegistry#establish_session      .invoke_commands / .read_events
                                                |
                                       node.cr  v
                                       Node#clusters[{endpoint, cluster}]
                                       (the flat index; wildcards iterate it)
                                                |
                                       cluster/cluster.cr
                                       Cluster::Base#read_attribute / #write_attribute
                                                  / #invoke_command
```

BDX protocol ID `0x0002` is a third route for authenticated CASE messages.
`protocol/bdx/responder.cr` authorizes a file designator through an application
callback, negotiates synchronous v0 transfer parameters, and streams blocks
on the same encrypted exchange. `ResponseSender` encrypts each block or
StatusReport and caches the packet against the incoming counter for MRP replay.
`SessionRegistry` removes an active BDX stream with its secure session and
sweeps idle streams. The controller entry point is
`Controller::BdxClient#download` or `#upload` behind `require "matter/controller"`.
Device callbacks and stream IO run under the `SessionRegistry` protocol lock;
they must finish promptly and must not wait for another Matter exchange.

For DiagnosticLogs, `Bdx::Initiator` queues a named device-to-controller
SendInit while `IMHandler` dispatches RetrieveLogsRequest, then opens the BDX
exchange after the InvokeResponse is sent. CASE session identity, fabric, and
peer node are checked before queuing; pending and active streams end on session
removal. Short logs remain in RetrieveLogsResponse with Exhausted status.
If no BDX sender is installed on a standalone cluster, it follows the
ResponsePayload command behavior.

The response goes back the way it came: `IMHandler.encode_*` builds the payload,
`ResponseSender#send_im_response` (`protocol/response_sender.cr`) encrypts it with
`Session::SecureMessage.encode`, hands a copy to `MrpCache#store` so a retransmitted request is
answered from cache, and writes it with `UDPTransport#send_reliable_raw`.

Outbound messages that request an MRP acknowledgement use
`UDPTransport#send_reliable_raw`. The transport retains the exact encoded bytes,
including ciphertext and counter, and retries them with Matter's bounded
backoff. An acknowledged counter clears only the matching session/exchange
entry; secure acknowledgements reach that table only after AEAD verification.
The table also covers unsecured controller handshake requests. Four retries
are allowed before removal. Session removal clears that session's entries,
and transport shutdown clears the table.

Unsecured Secure Channel replies use a separate bounded replay cache keyed by
the sending socket, optional source Node ID, and request counter. The transport
keeps the exact request and response datagrams for one minute. If an identical
PASE or CASE request is retransmitted, it sends a new MRP acknowledgement when
requested and replays the original response bytes without entering the
handshake again. Altered or stale packets never solicit a cached response.

`Session::SecureMessage` (`session/secure_message.cr`) encrypts and decrypts unicast
secure messages. There is one definition of the authenticated data — the complete packet
header, including the optional node ids and opaque Message Extensions — used by both
`encode` and `decode`.
`MessageCodec` also skips length-delimited Secured Extensions after decryption, and carries
vendor-qualified protocol IDs as a 32-bit vendor/protocol pair. Group privacy
uses the separate authenticated packet path below.

Groupcast uses a separate authenticated inbound path. The codec implements the
Matter 1.6 §§3.7/4.9 group privacy transform: `MessagePrivacy` derives the
privacy key, builds the MIC-based nonce, and obfuscates the counter and optional
IDs. `MessageCodec::Base.encode_private_packet` requires an already encrypted
AES-CCM payload and MIC. `decode_private_packet` recovers only a **candidate**
header; its fields must be authenticated with the operational group key and
clear-header AAD before any replay or application processing. The ordinary
codec rejects private packets without an explicit privacy key.

`Session::GroupSecurePacket` takes installed and mapped operational keys,
derives their privacy keys and session IDs, tries every colliding session ID,
authenticates the AES-CCM payload, then checks the mapped Group ID. It tracks
separate data and control replay windows per fabric/source, retaining peer
entries until restart as the TrustFirst policy requires. The caller must supply
only currently installed epoch keys. `Session::GroupOutgoingCounters` reserves
blocks of node-global data and control counters in durable storage before use;
it skips unused values after restart and refuses wraparound. A sender passes
the returned value to `GroupSecurePacket#encode`.

The device runtime joins PerGroupId IPv6 multicast addresses for groups with
both fabric-scoped GroupTable membership and a GroupKeyMap binding. Groups
membership may be provisioned before its key mapping.
Fabric removal clears its key sets, mappings, group names, and multicast joins
before the local FabricIndex can be reused.
It authenticates private group packets against mapped epoch keys before
parsing commands, replay checks, or ACL evaluation. A group command path
without an Endpoint tag expands over member endpoints; an explicit Endpoint
tag is invalid on a group command path. Each expansion passes
its own Group ACL check. No group response or acknowledgement is sent.
Authenticated group WriteRequests fan out over the same member endpoints and
Group ACL, reject timed/chunked writes, endpoint and node paths, and
DataVersion, and emit no response. The sender sets SuppressResponse as required
by Core §8.7.2.2; the receiver also accepts the official SDK v1.6 chip-tool's
false value while still emitting no response. Writable, untimed attribute
metadata determines whether each matching endpoint applies the value.
`Protocol::GroupMessageSender` emits one-way group InvokeRequests and
WriteRequests using durable
`Session::GroupOutgoingCounters`; callers supply the fabric identity, installed
operational key, and interaction paths. `Controller::GroupInvoker` selects a
stored fabric-scoped key and sends a one-way group Invoke or Write. Group control
messages and the provisional CacheAndSync/MCSP path remain unsupported.

Matter 1.6 Core §4.18.1.2 makes CacheAndSync and MCSP optional; the advertised
GroupKeyManagement policy is TrustFirst. The separate Groupcast cluster in
§11.27 is also provisional and is not implemented.

### Who owns what in the protocol layer

`MessageHandler` is 364 lines and does nothing but route. It constructs and holds:

| Object | File | Responsibility |
|---|---|---|
| `MrpCache` | `protocol/mrp_cache.cr` | responses cached by `{session id, counter}` so a retransmit is answered without re-running the handler |
| `SessionRegistry` | `protocol/session_registry.cr` | sessions, active subscriptions, pending cleanups, the sweep fiber, and **the one protocol lock** |
| `SubscriptionManager` | `protocol/subscription_manager.cr` | session-scoped chunk ladders for reads, subscriptions, and invoke responses; drains the event journal per subscription |
| `SecureChannel` | `protocol/secure_channel.cr` | the PASE and CASE state machines, keyed by peer endpoint and exchange id so concurrent commissioners cannot collide; resumed CASE rotates its ID only after Success from that exchange |
| `InteractionRouter` | `protocol/interaction_router.cr` | interaction model message types, timed-request bookkeeping, access control context |
| `ResponseSender` | `protocol/response_sender.cr` | encrypt, cache, send — the single outbound seam |
| `Node` | `node.cr` | endpoints, the flat cluster index and the event journal |

`IMHandler` serializes request-context assignment and handler execution per
cluster. This keeps a concurrent request from replacing the authenticated
session, fabric, or CASE subject while a cluster operation is in progress.
Read and Subscribe requests pass typed DataVersionFilterIB values to
`IMHandler`; a matching endpoint, cluster and data version omits that cluster's
attribute reports from the initial response. The controller can supply these
filters through `ImClient#read` and `#subscribe`.

When a WriteRequest carries an AttributeDataIB DataVersion, `IMHandler`
compares it with the cluster's current version after access checking and
returns DataVersionMismatch before invoking the writer if it is stale.
For a chunked list replacement, the version supplied on the successful
replacement also authorizes following appends to that list on the same exchange.
An unsuccessful replacement clears that authorization.

For list writes, the `AttributePath` TLV codec preserves an omitted ListIndex
for whole-list replacement and an explicit null ListIndex for append. A numeric
ListIndex receives `InvalidAction`, matching the SDK's supported write paths.
`IMHandler` requires a successful replacement before an append to the same
attribute; an orphan append receives `Busy`. `InteractionRouter` retains that
list state across WriteRequest chunks on the same secure session and exchange,
responds to each chunk, and drops the state after the final chunk or timeout.
Timed writes cannot be chunked.
The controller budgets each WriteRequest to 1,100 TLV bytes. An oversized
list becomes an empty replacement plus null-ListIndex appends; all chunks use
one exchange and each WriteResponse is read before the next chunk is sent.
One list item that cannot fit in a chunk is rejected before network I/O.

## Node, endpoints and clusters

`Endpoint` (`endpoint.cr`) owns `clusters : Hash(UInt32, Cluster::Base)`. `Node#add_endpoint`
populates the endpoint's Descriptor, calls `Endpoint#validate` — which holds the endpoint to the
mandatory clusters of every device type it declares — wires scene extensions, and copies each
cluster into the flat index `Node#clusters : Hash({UInt16, UInt32}, Cluster::Base)` that the
protocol layer resolves against. `#remove_endpoint` unwires all of it.

Every cluster is written on the cluster DSL (`cluster/dsl.cr`), which generates the id constants,
typed accessors, the metadata tables, feature-gated dispatch, constraint validation, the global
attribute lists and the persistence record. `Cluster::Registry` maps cluster ids to classes at
compile time.

## Events

```
Cluster::Base#emit_event  (cluster/cluster.cr, or the DSL's emit_<name>)
        |
Node#event_callback  ->  EventJournal#record        event_journal.cr, per-priority rings
        |
Node#on_event_emitted -> SubscriptionManager#notify_events
```

Reads take the same journal: `InteractionRouter#read_events` passes `Node#event_journal` to
`IMHandler.read_events`, which shares the report chunk budget with attribute reads. A subscription
carries its event paths and a persisted cursor; an urgent event bypasses the minimum-interval
damping.
When a SubscribeRequest sets `KeepSubscriptions` false, `SubscriptionManager`
discards in-flight subscriptions and `SessionRegistry` removes active ones
owned by that CASE node on the same fabric. Ownership is checked across secure
session renewals, and removal deletes the persisted subscription document.

Oversized list attributes are emitted as an initial array plus append item reports; an
indivisible attribute or event larger than the message budget receives ResourceExhausted.

## Persistence

`Device::Persistence` (`device/persistence.cr`) is the hub. It opens the backend, owns one
`Debouncer` (250 ms), and hands that same debouncer to the fabric table and to protocol
persistence, so everything dirtied in a burst is written once, in one transaction.

| Collection | Written by | When |
|---|---|---|
| `fabrics/<index>` | `FabricTable` (`fabric_table.cr`) | immediately on add/update/remove; `mark_fabric_used` is debounced |
| `case_resumptions/<id>` | `Session::Case::ResumptionStore` | after full CASE or authenticated resumed CASE; rotated on reconnection and removed with a device fabric |
| `sessions/<id>`, `subscriptions/<id>`, `device/counters` | `Protocol::Persistence::StorageBackend` (`protocol/persistence.cr`) | establishment writes immediately, counter and activity updates are debounced |
| `clusters/<endpoint>-<cluster>` | `Device::Persistence` via `Cluster::Base#save_state` | on the dirty flag set by `increment_version` |
| `device/identity` | `Device::Persistence` | on change |
| `app/<id>` | the application, and `endpoint_template` parameters | on write |
| `meta/schema` | the backend itself | on open |

The endpoint 0 OTA Requestor keeps one DefaultOTAProviders entry per fabric
in its cluster document. It binds an administrator's write to that request's
fabric and removes the entry before the local FabricIndex can be reused.
An optional OTA Provider cluster routes QueryImage, ApplyUpdateRequest, and
NotifyUpdateApplied to application callbacks with the authenticated fabric
and peer Node ID. Its command handlers do not own image files or update tokens;
the application supplies those and registers any BDX file designator separately.

On start, `Protocol::Persistence::StorageBackend#restore` brings back only CASE sessions whose
fabric still exists, and only subscriptions whose session came back. `Device#shutdown!` persists
sessions, closes the handler, flushes and closes persistence, then closes the transport and the
responder — so state survives a clean shutdown, and the debounce window is the only thing at risk
in a crash.

Backends are `Storage::Memory`, `Storage::YamlFile` and `Storage::JsonFile`, all under the abstract
`Storage::Backend` (`storage/backend.cr`); the two file backends share `FileBackend`, which does the
atomic write and fsync. `Storage::Record` derives `to_document`/`from_document` from a type's
instance variables, and `Storage::Migrator` copies any store to any other.

## Commissioning

The commissioning logic is not in the clusters. `Matter::Commissioning` holds it, and the clusters
are thin fronts:

| Service | File | Fronted by |
|---|---|---|
| `FailsafeService` | `commissioning/failsafe_service.cr` | `Cluster::GeneralCommissioning` (ArmFailSafe, SetRegulatoryConfig, CommissioningComplete) |
| `WindowService` | `commissioning/window_service.cr` | `Cluster::AdministratorCommissioning` (Open/Revoke commissioning window) |
| `CredentialService` | `commissioning/credential_service.cr` | `Cluster::OperationalCredentials` (attestation, CSR, NOC, fabrics) |

The require cycle that this would otherwise create — commissioning needing the clusters it rolls
back — is broken by `commissioning/rollback_targets.cr`, an interface the device satisfies.

`WindowService`'s callbacks are wired by the device to `MessageHandler#configure_pase_server` /
`#configure_pase_pin` / `#reset_pase_server` and to the mDNS responder, so opening a window both
arms PASE and starts advertising.

## Discovery

`MDNS::Responder` (`mdns/responder.cr`) runs an IPv4 and an IPv6 socket, answers instance,
service and subtype PTR queries (`_L`, `_S`, `_T`, `_V`, `_CM`), and sends a three-packet
announcement burst when an advertisement changes.

`Device::LifecycleManager` (`device/lifecycle_manager.cr`) decides what is advertised:
`_matterc._udp` while `fabric_table.empty?`, and one `_matter._tcp` record per fabric once
commissioned. It hooks `OperationalCredentials#on_fabric_added` / `#on_fabric_removed`, so the
first fabric switches the device to operational mode and removing the last one switches it back.
An administrator commissioning window can re-open the commissionable advertisement on an already
commissioned device, which is how multi-admin works.

The scanner is the other half of discovery and belongs to the controller:
`Controller::Scanner` (`controller/scanner.cr`), behind `require "matter/controller"`.
It matches each service instance's SRV target hostname to that host's A/AAAA
records, including address replies that arrive in a separate mDNS packet.
Host addresses are cached for their DNS TTL and removed on goodbye records;
unrelated host records never become addresses of a discovered instance.
The scanner listens on IPv4 and IPv6 mDNS. On Unix it joins and queries the
IPv6 multicast group on each available interface; where interface enumeration
is unavailable, it uses the system's default IPv6 multicast interface. An
IPv6-only peer can therefore be discovered from its AAAA records. Link-local
AAAA records are cached with the receiving IPv6 peer's interface scope, and
are ignored when that scope cannot be established (for example, when the
record arrives over IPv4 mDNS). This prevents an unscoped `fe80::` address
from being handed to CASE pairing.

## The device runtime

`Matter::Device` (`device/runtime.cr`) is the assembly point. `#initialize(storage : Storage::Backend, ...)`
builds, in order, `Device::Persistence` (which creates the fabric table), `Transport::UDPTransport`,
`Protocol::MessageHandler` (which creates the `Node`), and `MDNS::Responder`; then it builds and
wires the clusters, restores cluster state, installs the `LifecycleManager` and restores dynamic
endpoints.

* `#start` — advertise, start the responder, start the transport. Returns immediately.
* `#await_shutdown` — blocks until `#shutdown!` is called.
* `#shutdown!` — persist sessions, close the handler, flush and close persistence, close the
  transport, stop the responder.

Subclasses supply the identity (`device_name`, `vendor_id`, `product_id`, `discriminator`,
`setup_pin`, `primary_device_type_id`) and may override `before_start`, `on_started`, `on_shutdown`,
`started_commissioning_mode`, `started_operational_mode`, `commissioned` and `decommissioned`.
In practice the DSL in `device/dsl.cr` writes all of that, and the example devices under
`examples/` are the reference for it.

## The controller side

`require "matter/controller"` adds a parallel, much smaller stack on top of the same transport,
session and codec layers:

```
Controller::Scanner            mDNS discovery of commissionable and operational nodes
Controller::Client             the UDP client and its unsecured message counter
Controller::Pairing::PasePairing / CasePairing
Controller::Commissioning::Commissioner / CommissioningWindowOpener
Controller::ImClient           read attributes/events, subscribe, write_attribute(s), invoke
Controller::GroupInvoker       fabric-scoped one-way group Invoke with durable counters
Controller::StateStore         the fabric, its certificates and known nodes, over Storage::Backend
```

`examples/chip-tool.cr` is the worked example; see [../README.md](../README.md#controller) for the
short version.

Controller reads accept attribute paths, event paths, or both. `read_events`
adds an optional minimum event number; the same bounded ReportData chunk
ladder collects event and attribute reports. `subscribe_events` and `subscribe`
allow event-only or mixed subscriptions, including EventFilterIB values.
Subscription reports check both attribute and event status entries.

`GroupInvoker` derives an operational key from a provisioned epoch key and the
selected fabric's compressed ID, then stores the derived key in controller
state. Its sender uses the same node-global durable group data counter as the
device path. Key selection includes the fabric root and Group ID, so equal
Group IDs on separate fabrics remain isolated. Removing the last controller
identity for a logical fabric also removes its group keys.

### Joint Fabric

`Controller::JointCommissioning::Workflow` performs the Matter 1.6 joining
sequence. `SharedFabric` holds controller identities issued under an existing
root. `DatastoreSynchronizer` and `DatastorePropagator` apply the Anchor
Datastore to participant nodes. `AnchorDatastoreSubscription` tracks the new
Anchor's authenticated Datastore after transfer. `AnchorTransfer` and
`AdministratorRemoval` record lifecycle stages before network or credential
changes so an interrupted operation can be reconciled. The opt-in
`DatastoreNodeRegistrar` journals AddPendingNode before final CASE and
RefreshNode after acknowledged completion; its CASE network delivery talks
to the Anchor Datastore and retries interrupted registration. The
device-facing services are
`Commissioning::JointFabricAdministratorService` and the Joint Fabric
Administrator and Datastore clusters. The worked device is
`examples/support/joint_fabric_administrator_device.cr`; its provisioning,
trust, consent, and lifecycle limits are tracked in
[Matter 1.6 Joint Fabric status](matter_1_6_joint_fabric.md).
