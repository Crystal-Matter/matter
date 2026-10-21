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
                    Matter::Transport           transport/{udp_transport,exchange,message_counter}.cr
                              |
   Matter::MDNS   Matter::Network   Matter::Storage   Matter::Codec / Crypto / Certificate
   mdns/*.cr      network/*.cr      storage/*.cr      codec/*.cr, crypto/*.cr, certificate/*.cr
                              |
      Matter::Datatype   Matter::InteractionModel   Matter::Error   Matter::Hex
```

`Matter::Storage` is the strictest of these: it requires nothing from the rest of the library, which
is why it can be driven by the `matter-storage` CLI on its own.

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

The response goes back the way it came: `IMHandler.encode_*` builds the payload,
`ResponseSender#send_im_response` (`protocol/response_sender.cr`) encrypts it with
`Session::SecureMessage.encode`, hands a copy to `MrpCache#store` so a retransmitted request is
answered from cache, and writes it with `UDPTransport#send_raw`.

`Session::SecureMessage` (`session/secure_message.cr`) is the only place that encrypts or decrypts a
message. There is one definition of the authenticated data — the complete packet header, including
the optional node ids and opaque Message Extensions — used by both `encode` and `decode`.
`MessageCodec` also skips length-delimited Secured Extensions after decryption, and carries
vendor-qualified protocol IDs as a 32-bit vendor/protocol pair. Group privacy enhancements
remain unsupported because they need header deobfuscation before packet parsing.

### Who owns what in the protocol layer

`MessageHandler` is 364 lines and does nothing but route. It constructs and holds:

| Object | File | Responsibility |
|---|---|---|
| `MrpCache` | `protocol/mrp_cache.cr` | responses cached by `{session id, counter}` so a retransmit is answered without re-running the handler |
| `SessionRegistry` | `protocol/session_registry.cr` | sessions, active subscriptions, pending cleanups, the sweep fiber, and **the one protocol lock** |
| `SubscriptionManager` | `protocol/subscription_manager.cr` | one chunk ladder for reads, subscriptions and reports; drains the event journal per subscription |
| `SecureChannel` | `protocol/secure_channel.cr` | the PASE and CASE state machines, keyed by exchange id so two commissioners cannot collide |
| `InteractionRouter` | `protocol/interaction_router.cr` | interaction model message types, timed-request bookkeeping, access control context |
| `ResponseSender` | `protocol/response_sender.cr` | encrypt, cache, send — the single outbound seam |
| `Node` | `node.cr` | endpoints, the flat cluster index and the event journal |

`IMHandler` serializes request-context assignment and handler execution per
cluster. This keeps a concurrent request from replacing the authenticated
session, fabric, or CASE subject while a cluster operation is in progress.

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

## Persistence

`Device::Persistence` (`device/persistence.cr`) is the hub. It opens the backend, owns one
`Debouncer` (250 ms), and hands that same debouncer to the fabric table and to protocol
persistence, so everything dirtied in a burst is written once, in one transaction.

| Collection | Written by | When |
|---|---|---|
| `fabrics/<index>` | `FabricTable` (`fabric_table.cr`) | immediately on add/update/remove; `mark_fabric_used` is debounced |
| `sessions/<id>`, `subscriptions/<id>`, `device/counters` | `Protocol::Persistence::StorageBackend` (`protocol/persistence.cr`) | establishment writes immediately, counter and activity updates are debounced |
| `clusters/<endpoint>-<cluster>` | `Device::Persistence` via `Cluster::Base#save_state` | on the dirty flag set by `increment_version` |
| `device/identity` | `Device::Persistence` | on change |
| `app/<id>` | the application, and `endpoint_template` parameters | on write |
| `meta/schema` | the backend itself | on open |

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
Controller::ImClient           read_attribute, write_attribute(s), invoke
Controller::StateStore         the fabric, its certificates and known nodes, over Storage::Backend
```

`examples/chip-tool.cr` is the worked example; see [../README.md](../README.md#controller) for the
short version.

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
