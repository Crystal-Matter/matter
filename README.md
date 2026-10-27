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
| Clusters | `Matter::Cluster` | Matter 1.6 clusters built on the cluster DSL, plus `Cluster::Registry` |
| Protocol | `Matter::Protocol` | `MessageHandler` and the objects it routes through, the interaction model handler, subscriptions |
| Commissioning | `Matter::Commissioning` | the failsafe, commissioning window and credential services |
| Session | `Matter::Session` | PASE and CASE, `SecureContext`, `SecureMessage` framing |
| Transport | `Matter::Transport` | UDP and BTP packet transports, exchanges, message counters, and BTP framing and session windows |
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

An endpoint can declare outbound client clusters with `client_cluster 0x0554_u32`
inside its device DSL `endpoint` or `endpoint_template` block. This adds the ID to Descriptor
`ClientList`; it does not create a server. `DeviceType` definitions can set
`required_client_clusters:` to validate client roles at boot. The optional
`Matter::Controller::WebrtcRequestorClient` sends Matter 1.6 WebRTC Requestor
Offer, Answer, ICECandidates, and End commands over authenticated CASE and
checks the response path and status. The application owns SDP, ICE, media, and
the remote Requestor endpoint. This library does not yet advertise the Camera
device type: its required AV features, Provider server, and root-node conditions
still need integrated device validation and interoperability tests.

`Matter::Transport::BtpMessageTransport` carries PASE and encrypted Interaction
Model packets over BTP. On Linux with BlueZ and the GIO development library
installed (for example, `bluez` and `libglib2.0-dev` on Ubuntu), the experimental
central adapter discovers a Matter advertisement, connects to its GATT service,
writes C1, subscribes to C2 indications, and negotiates BTP v4:

```crystal
require "matter/controller"
require "matter/transport/bluez_gio_bus"

bus = Matter::Transport::Bluez::GioBus.new("/org/bluez/hci0")
central = Matter::Transport::Bluez::Central.new(bus)
device = central.discover(0x234_u16)
transport = central.open(device)
client = Matter::Controller::Client.new(transport: transport)
```

The adapter prefers BlueZ `AcquireNotify` for packet-preserving C2 file
descriptor reads. If C2 does not support acquisition, it subscribes to
`PropertiesChanged(Value)` before calling `StartNotify`, preserving each signal
as a separate BTP frame. The current host has no Linux Bluetooth controller,
so hardware commissioning has not yet been verified. The default controller
and device runtimes continue to use UDP.

The optional `Cluster::TimeSynchronization` server accepts administrator UTC
time with nonzero granularity and advances it with a monotonic clock. It starts
unsynchronized after each restart. Applications add it explicitly to a root
endpoint. The `TimeZone` feature stores offsets and reports transitions. The
`NtpClient` feature accepts a persistent IPv6 fallback through `SetDefaultNTP`
and queries SNTPv4 on UDP port 123 once an hour; DNS resolution is currently
disabled. The opt-in `TrustedTimeClient` feature stores a fabric-scoped peer,
reads its UTC time over authenticated CASE through
`Controller::TrustedTimeClient`, and retries hourly. A device host supplies
`TimeSynchronization#on_trusted_time_query` to bridge its fabric table to that
client. The opt-in `NtpServer` feature exposes `NTPServerAvailable` and can
serve accepted UTC over SNTPv4 using `TimeSynchronization::SntpServer` on a
host-selected IPv6 address and UDP port (normally 123). Availability is false
until the socket is bound and UTC has at least seconds granularity. The running
UTC clock is never persisted; applications start and stop the responder with
their device lifecycle. The synthetic TimeZone example demonstrates that
setup.

`Cluster::FanControl` implements Matter 1.6 revision 6. Select optional
MultiSpeed, Auto, Rocking, Wind, Step, and AirflowDirection features in the
endpoint's feature map. FanMode survives a restart; percent, speed, motion, and
direction settings start from the application's configured values. The
air-conditioner example enables MultiSpeed and Step and is exercised with the
official chip-tool.

`Cluster::DoorLock` uses the Matter defaults for optional local controls:
`enable_one_touch_locking`, `enable_inside_status_led`, and
`enable_privacy_mode_button` start false, and `local_programming_features`
starts at zero for a new lock. Existing saved boolean values continue to
restore; hosts that relied on the previous enabled defaults can pass those
constructor options explicitly for a new lock or update persisted attributes.
The server accepts only the
Single credential rule until a host can enforce multi-credential access.
For the previous all-enabled local programming mask, explicitly pass
`local_programming_features: 0x0F_u8`; higher bits are reserved.
See [Door Lock conformance](docs/door-lock-conformance.md) for its current scope.

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
  Wi-Fi and Thread devices need a `Matter::Network::Backend` passed as `network_backend:` when
  constructed. The backend performs scans, provisioning, removal, and connection; without one,
  wireless commands report an error instead of claiming the network changed.
  A wireless backend that accepts tentative Network Commissioning changes must
  implement `checkpoint_configuration`, `restore_configuration`, and
  `commit_configuration`. Checkpoints and restores must include credentials and
  connection state. The cluster rejects a mutation before calling the backend
  when no checkpoint is available. The backend commits on CommissioningComplete
  and restores the initial checkpoint when the fail-safe expires or is disarmed.
  Network metadata is saved in device storage after commit; credentials remain
  the backend's storage responsibility. The host backend and device storage are
  separate durability boundaries, so implementations should make restore safe
  to retry if one store fails after the other commits. A failed backend restore
  is logged and exposed as `GeneralCommissioning#failsafe.network_rollback_failed?`;
  expiry discards the fail-safe context, so the operator must repair the host
  network configuration manually.
  Wireless devices can pass `regulatory_location_capability:` at construction to set the fixed
  General Commissioning LocationCapability and its initial RegulatoryConfig together. The default
  is `IndoorOutdoor`; Ethernet-only devices must keep that value.
* `endpoint number, device_type: do ... end` — an endpoint and, inside the block, one `cluster`
  declaration per cluster. `as: :switch` adds a typed accessor (`switch : Cluster::OnOff`).
  The endpoint is validated against its device types when it is registered, so a device type
  missing one of its mandatory clusters is an error at start-up rather than a controller
  complaining later. Node-level requirements are checked after endpoint assembly;
  for example, a Smoke CO Alarm device requires a Power Source device type on
  at least one endpoint.
* `endpoint_template :name, device_type:, parameters: {...} do ... end` — the shape of an endpoint
  added at runtime with `add_endpoint(:name, key: value)`. Template parameters are persisted, so
  dynamic endpoints survive a restart. `examples/matter_bridge_device.cr` uses this.
  A Bridged Device Basic Information cluster requires a provisioned, nonempty `unique_id:` of at
  most 32 UTF-8 bytes. Reuse the same ID when restoring that bridged device after a restart;
  the bridge example persists it as a template parameter.
  Bridged `ConfigurationVersion` is optional; provision an initial positive value before
  advertising the endpoint to expose it. Once provisioned, it cannot be removed.
  When the application detects a bridged device configuration change, call
  `device.increase_bridged_configuration_version(endpoint_id)` after applying it. Pass an array
  of endpoint IDs for one logical change spanning several bridged devices: each version advances
  once and the bridge root `ConfigurationVersion` advances once. Versions persist across restarts.
  The bridge application decides which external changes count as configuration changes.
* `on(:accessor, :event) { |...| }` — binds a block to a cluster callback. Callbacks are wired once
  every endpoint exists, so one may reference an accessor on another endpoint.

The DSL rules are documented at the top of `src/matter/device/dsl.cr`, and the cluster DSL that
backs the cluster classes at the top of `src/matter/cluster/dsl.cr`.

Basic Information's `ConfigurationVersion` persists across restarts. Runtime
`add_endpoint` and `remove_endpoint` calls advance it when they change the node's
topology. For other application-managed configuration changes, call
`basic_info.increase_configuration_version` after the change succeeds. The
version wraps from the largest uint32 value to one.

TLS Certificate Management is opt-in: add
`cluster Matter::Cluster::TlsCertificateManagement` to an endpoint that has
appropriate administrator access. The cluster stores each fabric's root
certificates, client certificates, and device-generated P-256 client private
keys in the device's `Storage::Backend`; it erases them on `RemoveFabric`.
Protect file-backed storage at the host level because it contains private
keys. Provisioning a client certificate checks that its public key matches
the saved CSR key. Certificate size can reach 3000 bytes, so enable the
opt-in TCP transport (`tcp_enabled: true`) for large Matter messages. See
`examples/matter_tls_certificate_management_device.cr` for an isolated
chip-tool fixture. TLS Client Management (0x0802) can be enabled beside the
certificate cluster on endpoint 0 with
`cluster Matter::Cluster::TlsClientManagement`. It stores each fabric's
hostname, port, CAID, optional CCDID, and a host-managed reference count. It
requires the certificate cluster, validates certificate references on
provisioning, and blocks removal of referenced certificates. Host consumers
call `change_reference_count(fabric, endpoint_id, delta)` while an endpoint
is in use. A host with an unsynchronized clock can set the cluster's
`time_valid` callback to reject provisioning with `InvalidTime`. The host
still owns TLS sockets, DNS, connection policy, and
certificate verification for those connections; this cluster is the Matter
configuration interface. See
`examples/matter_tls_client_management_device.cr` for the chip-tool fixture.

Push AV Stream Transport (0x0555, revision 2) stores per-fabric transport
configuration and exposes the mandatory Matter commands and events. Hosts
provide stream validation and media lifecycle callbacks; see the
[Push AV Stream Transport guide](docs/push-av-stream-transport.md) for setup
and verification scope.

Every device includes the OTA Software Update Requestor cluster on endpoint 0.
An administrator can write one DefaultOTAProviders entry on each fabric. The
device keeps those entries separate, saves them with its cluster state, and
removes an entry when its fabric is removed. `Controller::OtaRequestorClient`
can query a provider on an established CASE session and stage a BDX image in
caller-owned seekable storage. An optional `Controller::OtaHttpsDownloader`
enables HTTPS image offers with certificate-checked TLS and bounded streaming.
The client checks the provider's BDX URI node ID and verifies the Matter OTA
image header and payload digest for either transport. A wired user-consent
callback is advertised to the provider and must approve a consent-gated offer
before any image bytes are downloaded. Provider QueryImage delays are enforced
per fabric and provider; the application can inspect `next_query_at(session)`
before scheduling a retry.
`request_apply` then asks the provider when the staged version may be
installed. `apply_staged` invokes an application installer only after an
immediate Proceed; `notify_applied` reports a version after the application boots
it. The application owns the storage, installer, token persistence across a
reboot, and rollback policy. It must not advertise `UpdatePossible` until
those paths are ready.

Applications can add the optional `Cluster::OtaProvider` to an endpoint and
register `on_query_image`, `on_apply_update`, and
`on_notify_update_applied` callbacks. Each receives the authenticated fabric
index and peer Node ID. The provider answers `NotAvailable` until an image
selector is registered. An application that offers a `bdx:` image URI also
registers its file designator on the BDX responder and checks the same fabric
and peer there; command callbacks do not expose files by themselves.

### Cluster values

`Cluster::TargetNavigator` exposes an application's menu of targets on an
endpoint. Each target has an identifier from 0 through 254 and a name. A
successful `NavigateTarget` invokes the application's `on_navigate` callback;
the response carries `Success`, `TargetNotFound`, or `NotAllowed` and optional
text. `CurrentTarget` is advertised when an initial value is supplied, and
the host can update the menu or selection locally through `update_targets`
and `report_current_target`. The revision-two `TargetUpdated` event reports
these changes. See `examples/matter_target_navigator_device.cr` for a synthetic
fixture; the host must perform the actual media navigation.

`Cluster::WakeOnLan` exposes a wake-capable interface's optional addresses
on a server endpoint. Give it a 12-digit upper-case hex MAC address and/or a
16-byte IPv6 link-local address:

```crystal
cluster Matter::Cluster::WakeOnLan,
  mac_address: "12345678ABCD",
  link_local_address: Bytes[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
```

Addresses are fixed after construction; nil omits the corresponding attribute.
The host must supply an interface that actually accepts wake packets while
asleep. The library only exposes the addresses over Matter. See
`examples/matter_wake_on_lan_device.cr` for a synthetic wire-test endpoint.

An appliance can opt in to `Cluster::TemperatureControl` to expose either a
numeric setpoint in hundredths of a degree Celsius or ordered, named levels.
`TemperatureNumber` and `TemperatureLevel` are exclusive; `TemperatureStep`
requires the numeric feature. Call `on_set_temperature` with a host callback
that applies the physical setting and returns an interaction model status.
Commands return `InvalidInState` until a host is registered. Accepted settings
persist, and the host can report a local control change with
`update_temperature_setpoint` or `update_selected_temperature_level`.
See `examples/matter_temperature_control_device.cr` for both feature choices.

`Cluster::TemperatureAlarm` exposes the Matter 1.6 Alarm Base attributes and
Notify event with over and/or under temperature thresholds in hundredths of a
degree Celsius. Devices select the OVER or UNDER features (or both), optional
major/minor thresholds, and individual adjustable threshold features. Call
`update_temperature` with physical readings; it recomputes State and reports
transitions. Optional Reset and ModifyEnabledAlarms commands support latching
and masking. Register `on_set_thresholds` to accept threshold changes from a
controller before the cluster commits them. See
`examples/matter_temperature_alarm_device.cr` for a synthetic sensor.

`Cluster::DishwasherAlarm` exposes the Matter 1.6 Alarm Base attributes,
Notify event, optional Reset feature, and optional ModifyEnabledAlarms command.
Configure at least one of the six appliance alarm bits in `supported`, and call
`report_alarms` when physical conditions change. The latest report is kept
in memory so enabling an alarm updates State immediately; Reset can be vetoed
when physical or manual intervention is still required. `Latch` and `Supported`
are fixed capabilities. See `examples/matter_dishwasher_alarm_device.cr` for a
synthetic device.

Refrigerator (`0x0070`, revision 3), Temperature Controlled Cabinet
(`0x0071`, revision 6), and Dishwasher (`0x0075`, revision 2) are available as
device types. A static endpoint may advertise several types with
`device_type: [primary, companion]`; Descriptor.DeviceTypeList retains each
type's revision. A Refrigerator must include Temperature Controlled Cabinet
on the same endpoint and the cabinet must expose Temperature Control with TN
and without TL. The physical Cooler condition is the appliance host's
responsibility. Dishwasher requires Operational State and its
OperationCompletion event. When Dishwasher also exposes On/Off, DF is
required. `Endpoint#validate` checks these requirements plus forbidden
features and attributes for clusters present on the endpoint. The synthetic
refrigerator and dishwasher alarm fixtures advertise these device types and
are read by chip-tool in the focused E2E specs.
Every cluster also exposes the Matter 1.6 global EventList attribute,
including an empty list on clusters with no declared events.

`Cluster::DishwasherMode` and `Cluster::LaundryWasherMode` implement the Matter
1.6 revision 3 Mode Base derivations. Provide 2–255 fixed mode options with
distinct values, labels, and tag sets; each option has 1–8 tags including a
standard tag. Manufacturer tags use values 0x8000–0xBFFF. The host
can use `on_change_to_mode` to perform or refuse a physical transition; a
refusal returns a ChangeToModeResponse with a failure status and text. These
clusters expose neither the OnOff feature nor StartUpMode/OnMode. The synthetic
`examples/matter_appliance_modes_device.cr` exercises both with chip-tool.
SupportedModes is copied at construction and on read. If persisted CurrentMode
is no longer in the host's configured catalogue, the configured initial mode
is restored.

`Cluster::RefrigeratorAndTemperatureControlledCabinetMode` provides the Matter
1.6 revision 3 refrigerator mode server. It adds RapidCool and RapidFreeze
tags to Mode Base, disallows OnOff, StartUpMode, and OnMode, and preserves a
valid CurrentMode across restart. The appliance can accept or refuse changes
through `on_change_to_mode`. The synthetic refrigerator fixture exposes it
alongside `RefrigeratorAlarm`.

`Cluster::DeviceEnergyManagementMode` is the Matter 1.6 revision 2 Mode Base
derivation for No, Device, Local, and Grid Optimization modes. It uses the same
fixed catalogue, host transition callback, and persisted CurrentMode behavior.
The deprecated OnOff dependency, StartUpMode, and OnMode are absent. The
synthetic appliance-mode fixture exercises it with chip-tool.

`Cluster::EnergyEvseMode` is the Matter 1.6 revision 2 Mode Base derivation
for Manual, Time of Use, Solar Charging, and V2X modes. Its fixed catalogue
must include a Manual mode that does not combine with Time of Use or Solar
Charging. CurrentMode persists across restart, while the host callback can
accept or refuse a requested transition. The synthetic appliance-mode fixture
exercises it with chip-tool.

`Cluster::EnergyEvse` provides the Matter 1.6 revision 4 charging interface.
Charging Preferences is mandatory: timed controller commands set, retrieve,
and clear validated daily targets, which persist across restart. Timed
EnableCharging and Disable commands control the retained charging permission
and current limits. Register `on_enable_charging` and `on_disable` so the
physical charger can accept or refuse a change; report pilot, meter, and fault
observations through the cluster's `report_*` methods to publish attributes
and events. `on_targets_changed` can reject targets that the host cannot
schedule; `next_charge_*` attributes let it publish the resulting forecast.
Call `report_next_charge` with the host's next start, target time, required
energy, and target SoC estimate; pass `nil` values when an estimate is unknown.
The appliance-mode example uses a synthetic Aggregator endpoint
for chip-tool coverage. SoC, Plug and Charge, RFID, and V2X are not advertised.

`Cluster::RefrigeratorAlarm` reports the Matter 1.6 DoorOpen alarm after the
appliance's chosen open duration. Its `Mask`, `State`, and fixed `Supported`
attributes and `Notify` event follow Alarm Base. The derived cluster does not
advertise Reset or ModifyEnabledAlarms. Call `report_alarms` as the physical
condition changes; see `examples/matter_refrigerator_alarm_device.cr`.

`Cluster::ClosureControl` and `Cluster::ClosureDimension` implement the Matter
1.6 closure command and state model, including timed target and step commands.
See [the closure guide](docs/closure-control-dimension.md) for host callbacks,
units, and the current composite endpoint limitation.

`Cluster::Chime` exposes Matter 1.6 revision 2 sound selection and playback.
Configure one or more uniquely named sounds and register `on_play` to start
physical playback. Controllers can write `SelectedChime` and `Enabled`; both
survive restart. A successful playback request emits `ChimeStartedPlaying`.
See `examples/matter_chime_device.cr` for a synthetic doorbell.

`Cluster::CameraAvSettingsUserLevelManagement` implements Matter 1.6 mechanical
pan, tilt, and zoom features in configurable combinations. MPAN-only hosts can
use `on_pan_move` and `report_pan_position`; hosts with tilt or zoom use
`on_mptz_move` and `report_mptz_position` for complete targets and measurements.
Measured positions persist across restart. The optional MPRESETS feature adds
a bounded, persisted list and move/save/remove commands. Register
`on_preset_save` and `on_preset_remove` to admit changes. An opt-in
DPTZ profile binds to same-endpoint VDO stream management. The host marks
allocated streams as move-capable and applies viewport changes through a callback.
DPTZRelativeMove and combined digital/mechanical profiles are supported. A synthetic
camera fixture is in `examples/matter_camera_pan_device.cr`.
The fixture uses an Aggregator endpoint for interoperability testing; it is
not a conformant Camera device. The required Camera endpoint topology remains absent.

`Cluster::CameraAvStreamManagement` supports the Matter 1.6 revision 2 Audio and Video features with typed stream
allocation, reference counts, shared bandwidth and encoder limits, privacy
modes, and durable priorities. Hosts provide media admission/release callbacks.
The synthetic examples and official chip-tool tests use Aggregator endpoints;
[the camera AV guide](docs/camera-av-stream-management.md) lists the remaining
camera device and transport work.

`Cluster::WebRtcTransportProvider` adds opt-in Matter 1.6 signaling on the
same endpoint as Camera AV Stream Management. It requires a host `Peer` to
perform SDP/ICE negotiation and deliver media. The
[WebRTC signaling guide](docs/web-rtc-transport-provider.md) explains the
fabric-scoped session lifecycle and the unimplemented media transport pieces.

`Cluster::OvenMode` adds the Matter 1.6 revision 2 oven tags (Bake through
Frozen Food) to the same Mode Base transition contract. It has no OnOff,
StartUpMode, or OnMode surface. `Cluster::OvenCavityOperationalState` is a
separate revision 2 server for physical cavity state, phase and countdown
reporting, errors, and completion. Hosts may expose Start and Stop together;
Pause and Resume are absent. Register `on_command` to admit remote actuation
only when the appliance is ready. The paired synthetic fixture is in
`examples/matter_oven_device.cr`.

`Cluster::MicrowaveOvenMode` exposes the Matter 1.6 revision 2 microwave
catalogue with Normal and Defrost tags. The host selects a supported
`CurrentMode`; the derived cluster disallows `ChangeToMode`, OnOff,
StartUpMode, and OnMode. The synthetic appliance modes example exposes its
fixed catalogue alongside the dishwasher and laundry mode clusters.

`Cluster::MicrowaveOvenControl` couples a Matter 1.6 microwave mode to cooking
time and numeric power. It advertises PowerAsNumber, with optional power limits
and AddMoreTime. `SetCookingParameters` validates all fields before asking the
host to apply them; a refused operation leaves Mode, CookTime, and PowerSetting
unchanged. A missing CookMode selects the advertised Normal mode; omitted time
and power use 30 seconds and maximum power. The host can opt into AddMoreTime
and must provide callbacks for physical changes. PowerInWatts remains
provisional and is not advertised. The synthetic appliance example exercises
these commands through official chip-tool.

`DeviceType::MICROWAVE_OVEN` (Matter 1.6 revision 2) requires Operational
State, Microwave Oven Mode, and Microwave Oven Control on one endpoint. The
Operational State instance must expose CountdownTime and its
OperationCompletion event. The appliance example includes a real Microwave
Oven endpoint alongside its synthetic cluster test endpoint.

Thread device declarations expose Thread Network Diagnostics at endpoint 0.
Applications populate the cluster from their platform Thread stack; absent
link values read as null, and packet/error/MLE/MAC counters require the
corresponding feature bits.

The foundation cluster set includes Localization Configuration, Unit
Localization, Power Source Configuration, Flow Measurement, and Air Quality.
Applications can add these clusters to endpoints through the device DSL.

Content App endpoints can add `Cluster::ApplicationBasic` with an immutable
application name, catalog vendor ID and application ID, version, and an
administrator-readable allowed vendor list. The host reports changes in the
app's visible/focused/running state through `update_status`; the status starts
`Stopped` after each process restart. The
`examples/matter_content_app_device.cr` example shows this configuration.
`Cluster::Messages` supports the opt-in Matter 1.6 CONF, RESP, and RPLY
profiles. Supply a `Messages::Host` and a feature map; the host receives each
queued message with its authenticated origin node and calls `present` when the
UI shows it, then `complete` with a
selected response ID or free-form reply. The cluster validates those values,
emits fabric-scoped completion events, and retains pending messages and expiry
times across restarts. Call `replay_messages_to_host!` after loading storage to
resume the UI. The content-app example enables this profile with
`MATTER_MESSAGES_PROFILE=1`; its automatic confirmation is for demonstration.
ProtectedMessages remains unavailable until a host verifier is integrated.
Basic Video Player endpoints can add the provisional Matter 1.6
`Cluster::ContentControl` server. The supported BlockUnrated, rating, channel,
and application features retain policy across restart; the host calls
`playback_allowed?` and reacts to `on_policy_changed` to stop disallowed
playback. See [the Content Control guide](docs/content-control.md) and
`examples/matter_content_control_device.cr`.
Pump endpoints can add the Matter 1.6 revision 5
`Cluster::PumpConfigurationControl` ConstantSpeed profile. The host validates
remote mode requests and reports observed operation and telemetry. See
[the Pump Configuration guide](docs/pump-configuration-control.md) and
`examples/matter_pump_device.cr`.

Commodity Tariff endpoints can add revision 1 `Cluster::CommodityTariff` for
durable Pricing calendars and current/next price projections. See
[the Commodity Tariff guide](docs/commodity-tariff.md) and
`examples/matter_commodity_tariff_device.cr`.
Zone Management endpoints can add revision 1 `Cluster::ZoneManagement` with
user-defined Cartesian regions and persisted motion triggers. See
[the Zone Management guide](docs/zone-management.md) and
`examples/matter_zone_management_device.cr`.

Locale and temperature unit writes are checked against the supported values;
sensor and power source values are updated by the application.
Temperature Measurement reports Matter 1.6 revision 6. Its fixed minimum and
maximum default to `nil` when a device cannot report a capability limit; readings
are checked against each known limit. Pass `tolerance:` to expose the optional,
fixed Tolerance attribute, including zero. Omit it when unsupported. Sensor
readings start from the configured value after restart and are not persisted.

The root node's General Diagnostics cluster answers TimeSnapshot with monotonic
milliseconds since startup. Its nullable POSIX time remains absent until an
application supplies a synchronized clock through `on_posix_time_ms`. Device
startup journals the configured BootReason as a critical event.
When the application has no platform boot-cause signal, the reported reason is
Unspecified.
General Diagnostics revision 3 also reports DeviceLoadStatus from live protocol
state: active subscriptions, the accessing fabric's share, cumulative
subscription establishments, and sent and received Interaction Model messages.
These counters start with each device process; restored active subscriptions
count as established when restored.
For certification or internal testing, a device may override
`general_diagnostics_test_enable_key` with a nonzero 16-byte key. This opts in
to General Diagnostics `DataModelTest` and enables `PayloadTestRequest` with
Manage privilege, a matching key, and a maximum response of 2,048 bytes.
`TestEventTrigger` uses the same key and needs an `on_test_event_trigger`
callback for application-specific triggers. Production devices leave the key
unset. The level-control example accepts `MATTER_DIAGNOSTICS_TEST_ENABLE_KEY`
as 32 hex digits for the isolated DMTEST E2E fixture.
Each `PowerSource` also exposes the Matter 1.6 mandatory `EndpointList`;
pass the powered endpoint numbers at construction or call
`update_endpoint_list` when the mapping changes.

Boolean State advertises revision 3 and ChangeEvent by default; changing
`StateValue` through `update_state` or its setter emits a typed StateChange
event once per actual change. Pass `feature_map: BooleanState::Feature::None`
to omit the event on devices that do not support it.

Sensors with alarms can also add `BooleanStateConfiguration` revision 2.
It exposes feature-gated alarm, sensitivity and fault state, typed commands
and events, and persisted sensitivity and enabled-alarm settings. See the
[cluster guide](docs/boolean-state-configuration.md) for construction and
state update APIs.

Energy devices can add `ElectricalPowerMeasurement`,
`ElectricalEnergyMeasurement`, and `PowerTopology`. The power and energy
clusters require their fixed measurement accuracy at construction. Select the
DC/AC and imported/exported plus cumulative/periodic feature bits that the
device actually supports; the constructors reject incomplete combinations.
Use `update_ranges`, `record_cumulative`, or `record_periodic` to update
readings and emit the Matter 1.6 measurement events. Power Topology exposes a
fixed set of available endpoints; `update_active_endpoints` changes its
nonvolatile active subset when DynamicPowerFlow is enabled.

Thermostats and other energy-aware devices can add `EnergyPreference` revision
1 with EnergyBalance, LowPowerModeSensitivity, or both. Supply each enabled
feature's ordered `Balance` scale; EnergyBalance also needs two distinct
`EnergyPriority` values and scales from 0 to 100. Controllers write the current
index with Operate privilege. Selections persist across restart and follow
the closest configured step if the manufacturer changes the scale. The
thermostat UI example demonstrates both features.

Electrical utility meters can advertise `MeterIdentification` on a `0x0511`
endpoint. Pass nullable meter type, point-of-delivery and serial metadata at
construction; `protocol_version` is optional. Enable `PowerThreshold` only
when the device can expose its contractual or equipment power limit. The
`examples/matter_utility_meter_device.cr` fixture shows a complete endpoint.

`ElectricalGridConditions` revision 1 adds nullable current carbon conditions,
controller-writable local-generation availability, and the optional Forecasting
list to that utility-meter example. The server checks period ordering and
local/grid agreement when generation is absent, then emits a typed event when
current conditions change. The forecast list is limited to 56 periods.

`CommodityPrice` revision 4 publishes a nullable current tariff price and an
optional ordered forecast of up to 56 periods. Each period contains a price,
price level, or both; detailed price commands can include a description and
component breakdown. The server checks component totals and emits PriceChange
when the current price changes. The utility-meter fixture exercises this
cluster with official chip-tool.

`CommodityMetering` revision 1 publishes measured quantities with tariff
component IDs, a Matter epoch timestamp, tariff unit, and capacity. A host
publishes all four values together with `publish`; `clear_reading` makes all
four nullable attributes unavailable. The utility-meter fixture exposes the
read-only cluster to official chip-tool.

Wi-Fi device declarations expose Wi-Fi Network Diagnostics at endpoint 0.
Applications can update observed link values and counters on that cluster.
Software Diagnostics is available as an optional cluster for applications
that can provide process and heap metrics.

Resource Monitoring exposes the Matter 1.6 HEPA filter, activated-carbon
filter, and water-tank cluster identities with a shared schema. Applications
choose the Condition, Warning, and ReplacementProductList features per
endpoint, report assessments with `update_resource`, and may expose an
optional `ResetCondition` command. Register `on_reset_condition` to confirm
that the physical resource was replaced or refilled before a reset succeeds.
The command restores Condition to 100 for downward degradation or 0 for
upward degradation, and sets ChangeIndication to OK. Optional
LastChangedTime is controller-writable and retained across restarts; an
application may set it when it knows when the resource changed.

Robotic vacuums can pair `RvcRunMode` (revision 4), `RvcCleanMode` (revision 5),
and `RvcOperationalState` (revision 3). Run modes include distinct Idle and
Cleaning options; clean modes include Vacuum or Mop. Both mode clusters offer
the optional DirectModeChange feature, with a non-Idle run mode otherwise
blocking direct changes. The operational cluster can expose paired Pause and
Resume plus optional GoHome. Host callbacks decide whether physical actions
are safe, and the host reports charging, docking, errors, and completion.
The Matter 1.6 Robotic Vacuum Cleaner device type (`0x0074`, revision 4)
requires Identify, RVC Run Mode, RVC Operational State, and its
OperationCompletion event. RVC Clean Mode and Service Area are optional.
`Endpoint#validate` checks this composition. See
`examples/matter_rvc_device.cr` for a synthetic endpoint.

`ServiceArea` revision 2 adds the RVC's area catalogue and the `SelectAreas`
command. The host supplies meaningful area descriptions and decides whether a
requested route is physically reachable through `on_select`; duplicate area
IDs in a request are collapsed in order. Selection persists and is reconciled
when the host catalogue changes at runtime or after restart. MAPS and PROG
are opt-in. Mobile devices may expose `CurrentArea`; `SkipArea` is opt-in and
requires an `on_skip` callback to stop operation in the physical area.

Water Heater Mode and Water Heater Management expose Matter 1.6 appliance
control on a Thermostat endpoint. Configure Mode with at least an Off and a
Manual option; mode labels and tag sets must be distinct, and manufacturer
tags use values 0x8000–0xBFFF. Register `on_change_to_mode` so the host can
accept or reject transitions. On restart, a saved mode that is no longer
supported falls back to the host's configured mode. Management reports
heat-source demand, tank percentage, and estimated heat through host setters.
Register `on_boost` and `on_cancel_boost` before accepting remote Boost
commands; accepted boosts
raise revision-two events and time out after their requested duration. The
server logs a host cancellation failure at timeout and still ends the protocol
boost state. The optional EnergyManagement and TankPercent features gate
their associated attributes. The host remains responsible for physical heater
operation, thermostat setpoint checks, and accurate tank/energy estimates. See
`examples/matter_water_heater_device.cr` for a synthetic endpoint and its
official chip-tool E2E fixture.

BoostInfo fields for one-shot, temporary setpoint, emergency heating and
percentage targets are forwarded to `on_boost`; the host applies those physical
policies and calls `finish_boost` when a target is reached. The server enforces
the duration timeout and basic field constraints.

`Cluster::DeviceEnergyManagement` implements the Matter 1.6 revision 4
PowerAdjustment profile (0x0098) on the synthetic water heater. The host
supplies the ESA type, generation flag, absolute power limits, and current
capability ranges. It registers `on_power_adjust` and
`on_cancel_power_adjust` to approve physical changes; both callbacks receive
the requesting fabric index for host policy. The server validates requested
power and duration, opt-out and online state, reports active state, emits
PowerAdjustStart/End, and ends a session on cancellation, timeout, fault,
offline state, or a new opt-out. A restart begins online without replaying an
old power adjustment. This PA profile never advertises unrelated feature bits.

The same server supports standalone PFR or SFR reporting profiles. A host
reports a nullable `Forecast` with 1–10 bounded slots; PFR slots include power
and energy estimates, while SFR slots include a stable manufacturer state.
Forecasts are copied on assignment and read, require advancing IDs, and are
volatile across restarts. The host can refresh elapsed and remaining slot time
without flooding subscriptions. The synthetic washer-dryer shows PFR reporting.
The PFR+STA profile also accepts a host-approved request to shift a future
forecast within its earliest-start and latest-end window. EarliestStartTime may
be null for immediate availability. CancelRequest restores the host schedule,
and a conflicting opt-out cancels the adjustment. The synthetic washer-dryer
exercises this flow. The separate PFR+PAU profile accepts host-approved pauses
of its active, pausable forecast slot within its advertised duration bounds;
ResumeRequest, expiry, host state changes and conflicting opt-out end the pause
with a Resumed event. The synthetic pausable washer exercises this profile.
The PFR+FA profile accepts a host-approved ModifyForecastRequest within each
slot's advertised power and duration adjustment bounds. It publishes the
replacement Forecast immediately with an advancing ID; CancelRequest or a
conflicting opt-out restores the prior host forecast. A synthetic adjustable
heater exercises the command, cancellation, and restart with official
chip-tool. The separate PFR+CON profile accepts chronological, non-overlapping
future power and energy constraints. The host computes the replacement
forecast; CancelRequest and opt-out restore the earlier forecast. The
synthetic constrained heater exercises request, cancellation, and restart.

Laundry Dryer Controls and Laundry Washer Controls expose mode-dependent
dryness levels, spin speeds, and rinse counts. Configure at least one washer
feature (`Spin` or `Rinse`) and register host selection callbacks before
accepting remote writes. The host can replace supported options when its
appliance mode changes; saved selections are checked against the current
options after restart. See `examples/matter_laundry_combo_device.cr` for a
synthetic washer-dryer endpoint and official chip-tool E2E fixture.

`Cluster::ThermostatUserInterfaceConfiguration` adds Matter 1.6 revision 2
display units, keypad lockout, and optional local schedule programming
visibility to a Thermostat endpoint. All three preferences persist; the
temperature display mode requires Operate privilege to write, while keypad
lockout and schedule visibility require Manage. The
`examples/matter_thermostat_ui_device.cr` fixture includes the cluster on a
Thermostat device and is exercised by official chip-tool.

`Cluster::Thermostat` supports the LocalTemperatureNotExposed (LTNE) feature.
With LTNE enabled, `update_local_temperature` feeds the internal measurement
used by Auto mode while LocalTemperature always reads as TLV null. A direct
`local_temperature=` call cannot expose a value on an LTNE thermostat. See the
synthetic `examples/matter_thermostat_ltne_device.cr` and its chip-tool test.
The opt-in Thermostat Events (TEVT) feature reports typed system-mode, significant local-temperature, setpoint, running-state, and Auto running-mode changes. Local-temperature events are limited to one per minute; LTNE suppresses them. Thermostat Occupancy (OCC) exposes read-only occupancy and separate unoccupied heating/cooling setpoints; the host changes occupancy through `occupancy=`. TEVT also reports occupancy changes and labels setpoint changes when OCC is enabled. The `examples/matter_thermostat_events_device.cr` and `e2e/fixture/matter_thermostat_occupancy_device.cr` fixtures exercise these features with official chip-tool. The Thermostat cluster advertises revision 11 for supported base configurations; MSCH and TSUGGEST remain unavailable in production.

An opted-in production Thermostat advertises Presets (PRES) when constructed
with fixed `preset_types` containing one to seven scenarios and a total preset
capacity of one to 255. `configure_presets` can update the host-owned list but
cannot change those fixed types or their capacity; the Thermostat feature
profile also remains fixed after construction. Controller Presets writes
require `AtomicRequest`; the transaction has secure-peer ownership, timeout,
rollback, commit, and private pending reads. `SetActivePreset` applies a
configured preset's setpoints, while a later manual setpoint change clears its
active handle. The list, active handle, and used handles persist across restart
so deleted handles are not generated again. The production class is exercised
by the official chip-tool fixture in `e2e/spec/thermostat_presets_spec.cr`.

`Cluster::LowPower` provides the Matter 1.6 Sleep command on an opt-in endpoint.
Register `configure_host(accept, sleep)` to accept or refuse requests and to
enter low power. The admission callback returns a status synchronously and must
not begin sleep or perform irreversible work. The physical sleep callback runs
only after the matching InvokeResponse has been
sent and the protocol lock is released. Failed or suppressed responses discard
the transition. The synthetic
`examples/matter_low_power_device.cr` fixture records requests for its
chip-tool interoperability test.

Cluster reads return `TLV::Any` or an interaction model status. Attribute writes take `TLV::Any`;
command requests and `CommandResponse#response` use `TLV::Any?`. Pass `TLV::Any.new(50_u8)` to
write a scalar or `request.to_tlv(nil)` for a `TLV::Serializable` command struct. Wire encoding
stays in the protocol layer.

Pressure Sensor example: `examples/matter_pressure_sensor_device.cr` exposes Matter 1.6 Pressure Measurement revision 5 with the Extended feature. Configure physical bounds and scale at construction; report new readings through `update_pressure` and `update_scaled_pressure`. Measured readings are not persisted.

The opt-in [Ambient Context Sensing server](docs/ambient-context-sensing.md)
exposes provisional Matter 1.6 HumanActivity or the combined
ObjectCounting+ObjectIdentification profile. A host reports classified
observations, while the cluster maintains HoldTime, the active semantic tag,
and typed start/end events. Other feature combinations remain unadvertised.

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
The extended color light also demonstrates Level Control's
`CoupleColorTempToLevel` option: level changes adjust the active color
temperature across the configured mired range. Per-command option masks can
enable or disable coupling for one command.
Color Control revision 9 reports fixed primary coordinates when configured,
and its nonvolatile `StartUpColorTemperatureMireds` setting selects the
power-up temperature and color mode after an ordinary restart.
Level Control defaults to a Lighting range of 1–254. When using Level Control
for a non-lighting application, set `feature_map: Matter::Cluster::LevelControl::Feature::None`
to allow a custom range that starts at zero.
`CurrentLevel` can be unknown (`nil`), including after a stored-state restart. The
server reports TLV null until it learns a level. `MoveToLevel` sets a known target
immediately from that state; relative `Move` and `Step` return Failure because
they have no known starting level. If a level becomes unknown during a timed
transition, the server cancels that transition and clears `RemainingTime`.
`MinLevel` and `MaxLevel` are fixed configuration values: restoring saved
runtime state keeps the newly configured bounds and clamps a restored known
`CurrentLevel` into them.
Direct host updates to `CurrentLevel` must stay within those bounds. Only
`CurrentLevel` and `StartUpCurrentLevel` are nonvolatile; Options, transition
settings, OnLevel, and frequency values start from their configured defaults
after a restart.
For a Lighting endpoint, `StartUpCurrentLevel` takes effect after persisted state
is restored on ordinary `Device#start`: zero selects `MinLevel`, null retains
the previous `CurrentLevel`, and another value selects that level. After an
OTA update, call `Device#start(ota_restart: true)` to retain the pre-update
level regardless of `StartUpCurrentLevel`.
The server continues to advertise revision 6; the remaining revision 7 audit
is in [docs/level-control-revision-7.md](docs/level-control-revision-7.md).

### Example projects

These projects show off how custom matter interfaces can be built for almost any device.

* Control a [Home Connect oven](https://github.com/Crystal-Matter/homeconnect-oven-matter) using siri
* [Control a rangehood](https://github.com/Crystal-Matter/elica-rangehood-matter)
* Control a [Windows media center PC](https://github.com/Crystal-Matter/matter_media), plugged into your TV, from your phone

## Controller

`require "matter/controller"` adds the commissioner side: discovery, pairing and an interaction
model client. `examples/chip-tool.cr` is a full CLI built on it — see
[examples/chip-tool/README.md](examples/chip-tool/README.md).

When commissioning a device whose Network Commissioning cluster advertises
Wi-Fi or Thread, provide the regulatory location and country code. The
commissioner detects this on any endpoint and sends `SetRegulatoryConfig`
before attestation:

```crystal
commissioner = Matter::Controller::Commissioning::Commissioner.new(
  state_store,
  attestation_verifier: verifier,
  regulatory_location: Matter::Cluster::GeneralCommissioning::RegulatoryLocationType::Indoor,
  regulatory_country_code: "AU"
)
```

Ethernet-only devices need no regulatory options. The IP commissioner does not
provision Wi-Fi or Thread credentials; those require a commissioning channel
and platform network backend for network handoff.

For wireless devices, ScanNetworks responses include the enabled interface's
result list as an empty array when no networks are discovered.

CASE pairing can reuse a persisted secret after the first certificate exchange.
The Crystal chip-tool enables this with its controller store. Library callers
can share a `ResumptionStore` with their controller state backend:

```crystal
resume_store = Matter::Session::Case::ResumptionStore.new(state_store.backend)
pairing = Matter::Controller::Pairing::CasePairing.new(resumption_store: resume_store)
session, peer = pairing.pair_discovered(client, state_store, node_id)
```

The first call performs full CASE and saves a record. Later calls, including
after restart, use Sigma2Resume when the peer recognizes that record; otherwise
the peer can answer with full Sigma2. Records are scoped to fabric root, fabric
ID, controller node ID, and peer node ID. `pair_discovered` matches the
compressed fabric ID and Node ID in operational mDNS, then falls back to a
saved address if discovery is unavailable. It saves a newly discovered address
only after CASE authenticates that peer.
Link-local IPv6 hints retain their interface scope across commissioning and
controller restart so the saved route remains usable when mDNS is unavailable.

Matter TCP is available as an opt-in transport for commissioned IP devices:
pass `tcp_enabled: true` to the device constructor to listen on its operational
port and advertise `T=4` (TCP server support). A controller opts in with
`Client.new(tcp_enabled: true)`, calls `client.connect_tcp(address)` with the
device's operational IP address, then passes the returned connection token as
the `peer` to `CasePairing#pair` and subsequent client methods. The token is
valid only while that TCP connection remains open; reconnecting requires a new
CASE session. UDP stays available on the same port. TCP packets are bounded at
63,000 bytes and can carry larger Read and Invoke responses or BDX blocks on
the connection-bound secure session. The library uses a conservative
60,000-byte Interaction Model payload budget. Oversized subscription updates
are logged without advancing their event cursor; chunked update delivery is
still pending.

### Bulk Data Exchange

`Controller::BdxClient` transfers named streams on a CASE session. The caller
owns the source or sink IO. Downloads have a 64 MiB default maximum and both
directions use 1024-byte blocks by default; choose lower limits if needed.

```crystal
bdx = Matter::Controller::BdxClient.new(client)
File.open("diagnostics.bin", "w") do |sink|
  bdx.download(session, peer, "diagnostics".to_slice, sink)
end
File.open("update.bin", "r") do |source|
  bdx.upload(session, peer, "update".to_slice, source,
    length: File.size("update.bin").to_u64)
end
```

A device exposes a designator only through a callback on its message handler.
The callback receives the authenticated peer session and negotiation request,
so an application can check the fabric, peer Node ID, and requested file before
opening a stream. Return `nil` to reject access. The handler closes a returned
stream at transfer completion, on error, after five idle minutes, or when the
secure session is removed. The device also limits each stream to 64 MiB by
default; set `device.message_handler.bdx.max_transfer_bytes` for a larger
application-specific limit.

The device handles callbacks and stream reads or writes on bounded per-session
BDX workers, outside its session registry lock. A waiting application stream
does not block another CASE session's BDX transfer. Messages within one CASE
session retain their order. The device admits at most four concurrent BDX
workers and four active or opening transfers; extra requests receive
ResponderBusy, so callbacks and stream IO should still be bounded.
Shutdown returns after a short grace period if application IO remains blocked;
the worker closes its stream when that IO returns.
The controller waits up to five minutes for each response by default; a caller
can set a different `BdxClient` timeout.

```crystal
device.message_handler.bdx.on_download = ->(session : Matter::Session::SecureContext,
                                            init : Matter::Protocol::Bdx::Wire::Init) do
  if session.fabric_index == 1_u8 && init.file_designator == "diagnostics".to_slice
    file = File.open("diagnostics.bin", "r")
    Matter::Protocol::Bdx::Responder::Source.new(file, File.size("diagnostics.bin").to_u64)
      .as(Matter::Protocol::Bdx::Responder::Source?)
  end
end
```

This BDX service accepts synchronous v0 transfers over CASE. It supports both
sender and receiver drive, choosing sender drive when both are proposed. A nonzero
start offset, asynchronous mode, PASE transfer, and a designator with no callback
are rejected. The device Diagnostic Logs cluster initiates a named BDX upload
for logs that exceed the inline command limit after answering RetrieveLogsRequest;
the authenticated CASE session and requester's file designator are retained for
that transfer. OTA file designators still require an application callback.

For one-way group commands, use a controller store backed by a durable file.
Provision the same epoch key and Group ID on each receiving device through
GroupKeyManagement, add endpoint membership through Groups, and grant a Group
ACL before sending. The controller retains only the derived operational key.
KeySetWrite requires the first 16-byte epoch key and start time; additional
epochs must be contiguous and have increasing start times. Group Key
Management advertises Matter 1.6 revision 3. By default its optional
provisional Groupcast (GCAST) feature is not advertised.

An always-on device can opt into the provisional Matter 1.6 Groupcast Listener
on root endpoint 0 with `groupcast_listener: true` in its `Matter::Device`
constructor. The switch example accepts `MATTER_GROUPCAST_LISTENER=1` for this
mode. It advertises Groupcast LN, Group Key Management GCAST, and Access
Control AUX together. A CASE controller with Administer privilege installs a
key set with Group Key Management KeySetWrite; Manage privilege then permits
joining an endpoint using Groupcast JoinGroup. Administer privilege is required
to supply key bytes or enable an auxiliary Group ACL. Groupcast membership,
key mappings, adopted fabric state, and auxiliary access survive a device
restart. A fabric that
writes GroupcastAdoption=true reads an empty legacy GroupKeyMap/GroupTable and
must manage membership through Groupcast commands.

Set `groupcast_sender: true` to advertise SD on the root node; it may be used
alone or together with Listener. The switch example accepts
`MATTER_GROUPCAST_SENDER=1`. A Sender-only node joins a group through
`JoinGroup` with `Endpoints=[]`; it does not join the receive multicast address
or add AuxiliaryACL entries. Device application code calls
`send_groupcast_invoke(fabric_index, group_id, cluster_id, command_id, fields)`
or `send_groupcast_write(fabric_index, group_id, cluster_id, attribute_id, value)`.
For a synchronous CASE command callback,
`send_groupcast_invoke_for_request(source_cluster, cluster_id, command_id, fields)`
forwards only to Sender memberships on the command's authenticated fabric.
These methods require a durable storage backend for node-global outbound
message counters, an installed fabric, Groupcast membership, and a current
epoch key. `groupcast_per_group: true` explicitly advertises provisional PGA
alongside Listener or Sender. Listener applications can set
`groupcast_max_mcast_addr_count:` to adjust the default ten policy
addresses with PGA (one without PGA). Matter 1.6 requires at least four with
PGA. JoinGroup's `McastAddrPolicy=PerGroup` uses a Fabric ID and Group ID
scoped IPv6 multicast address; the default policy uses the shared IANA address.
`UsedMcastAddrCount` counts the one IANA address when configured and each joined
PerGroup policy address, including Sender-only memberships. Sender-only
memberships do not subscribe a receive socket.
JoinGroup returns ResourceExhausted before changing keys or membership when
address capacity would be exceeded. Policy and listener subscriptions survive
restart and are released by LeaveGroup or fabric removal. The switch example
accepts `MATTER_GROUPCAST_PER_GROUP=1` and
`MATTER_GROUPCAST_MAX_MCAST_ADDR_COUNT`.
Pass `iana_address: true` to `GroupInvoker#invoke` or `#write` when sending to
an LN-only Groupcast Listener. Legacy Groups memberships retain the default
fabric-derived multicast address.

```crystal
group = Matter::Controller::GroupInvoker.new(client, store)
group.install_epoch_key(fabric.fabric_id, fabric.root_public_key,
  0x1234_u16, epoch_key)
group.invoke(fabric.fabric_id, 0x1234_u16,
  Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON,
  root_public_key: fabric.root_public_key, iana_address: true)
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

  session, peer = Matter::Controller::Pairing::CasePairing.new
    .pair_discovered(client, store, NODE_ID)
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
  persisted = store.load
  persisted.unsecured_message_counter = client.transport.message_counter.counter
  store.save(persisted)
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

Scenes Management keeps scene tables per fabric. Controllers on one shared
fabric see the same scenes; a controller on an independent fabric can reuse a
GroupID and SceneID without exposing or changing the first fabric's scene.
Removing a fabric also removes its scenes before its local index is reused.

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
Matter 1.6 AuxiliaryType entries belong to the separate provisional
AuxiliaryACL feature. Primary ACL writes containing AuxiliaryType are rejected;
the controller ACL JSON helper rejects the field too, instead of dropping it.
Crystal devices do not advertise the provisional AUX feature.
Access Control revision 3 emits fabric-sensitive ACL and Extension change
events for authenticated administrator writes. Reading those events requires
Administer privilege. The MNGD feature remains disabled by default. A device
with durable storage and host review callbacks can opt in to fabric-scoped
Access Restriction Lists and token-correlated review; see the
[managed device guide](docs/access-control-managed-device.md). ACL and
Extension writes require a fabric-associated CASE session; fabricless PASE
writes are rejected.

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

When the Anchor updates GroupKeySetID zero, refresh each controller's stored
IPK epochs over an authenticated Anchor CASE session before retiring its old
epoch. The controller then selects the second-newest epoch for new CASE and
can retry retained epochs while devices receive the update:

```crystal
Matter::Controller::SharedFabric.refresh_ipk_from_anchor(
  store, fabric, im, anchor_case_session, anchor_peer,
  datastore_endpoint, anchor_node_id)
```

## Intermittently connected devices

Always-on devices do not advertise ICD Management. An application that has a
sleep and wake policy enables the Matter 1.6 cluster explicitly:

```crystal
icd = Matter::Cluster::IcdManagement::Configuration.new(
  feature_map: Matter::Cluster::IcdManagement::Feature::CheckInProtocolSupport,
  idle_mode_duration: 60_u32,       # seconds
  active_mode_duration: 3_000_u32,   # milliseconds
  active_mode_threshold: 5_000_u16, # milliseconds
  slow_polling_interval_ms: 2_000_u32,
  fast_polling_interval_ms: 50_u32
)
device = MyDevice.new(icd_configuration: icd)
device.icd_peer_resolver = ->(fabric_index : UInt8, node_id : UInt64) do
  # Return the registered client's current operational Socket::IPAddress.
  resolve_check_in_peer(fabric_index, node_id)
end

# Call these from the platform's sleep/wake integration:
device.icd_enter_idle_mode
device.icd_request_active_mode
# A physical user trigger resets per-client Check-In backoff:
device.icd_trigger_user_active_mode
```

Set the slow and fast polling intervals to the platform's actual radio polling
cadence. MRP retries use 500 ms plus the slow poll interval when idle and 300 ms
plus the fast poll interval when active. `active_mode_duration` is how long the
ICD remains awake; it is not an MRP retry interval.

The cluster implements fabric-scoped RegisterClient/UnregisterClient,
StayActiveRequest, per-client Check-In backoff, and the feature-gated 1.6
attributes. Registration keys and the Check-In counter are stored immediately;
the counter advances on restart and is saved before each AES-CCM Check-In.
Check-Ins use an unsecured Secure Channel message to the resolver's current
address. A platform must provide physical sleep/wake scheduling and an address
resolver; this library does not control radio power or discover an offline
client's address. Devices without those hooks can still expose ICD metadata,
but cannot deliver Check-Ins to an unreachable client.

A controller can register its CASE identity as an ICD Check-In client and
receive authenticated Check-Ins on its existing UDP transport:

```crystal
peer_store = Matter::Controller::IcdPeerStore.new(controller_state_store.backend)
icd_client = Matter::Controller::IcdClient.new(controller_client, peer_store)
icd_client.on_check_in = ->(check_in : Matter::Controller::IcdClient::CheckIn) do
  # check_in carries authenticated fabric and device Node IDs, counter,
  # ActiveModeThreshold, sender address, and key-refresh signal.
  handle_waking_device(check_in)
end
icd_client.register_client(fabric, device_node_id, case_session, device_address)
```

`register_client` sends the typed ICD Management command over CASE and saves
the Check-In key before sending, so a lost response does not lose a registration
the device may have accepted. On key refresh, the controller retains the old
and pending keys until an authenticated Check-In proves which one the device
uses. Counters and key changes are saved before calling `on_check_in`; a replay
is never delivered. A restarted device may reset its unsecured UDP packet
counter; the controller accepts the packet only as a Check-In and uses its
authenticated, durable Check-In counter to reject replay. Other unsecured
messages retain UDP packet-counter replay protection. Removing a fabric
through `Controller::StateStore` deletes
its controller Check-In keys. Call `unregister_client` over CASE before removing
an individual peer. Controllers still need application policy for sleep-aware
subscriptions, key refresh scheduling, and routing replies to a waking device.

## Enhanced Setup Flow Terms and Conditions

Devices can enable the optional Matter 1.6 General Commissioning TC feature
when constructed:

```crystal
device = MyDevice.new(
  tc_min_required_version: 2_u16,
  tc_required_acknowledgements: 0b0110_u16
)
```

The device then advertises FeatureMap bit 0, exposes the TC attributes to
administrators, and accepts SetTCAcknowledgements (command `0x06`). The
acknowledged version must meet the configured minimum, and the response map
must include every required bit. Acceptance during an armed fail-safe remains
temporary until CommissioningComplete succeeds. Fail-safe expiry or a restart
discards that temporary acceptance. A successful completion persists it for
future commissioning sessions. Devices without these constructor options do
not advertise the TC feature.

When commissioning one of these devices, obtain the user's acceptance of the
terms first, then pass the accepted version and bitmask explicitly to
`Commissioner#pairing_code` as `tc_acknowledgements: {version, bitmask}`. The
controller sends this after device attestation and checks the command response;
it never accepts terms automatically.

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
through `Matter::Storage::Backend`. Three backends load by default:

* `Matter::Storage::YamlFile` - one human readable YAML file (recommended)
* `Matter::Storage::JsonFile` - the same layout as JSON
* `Matter::Storage::Memory` - nothing persisted; state is rebuilt on every start

SQLite is available as an opt-in durable backend. Add `sqlite3` to your
application's `shard.yml` (it is only a development dependency of this library),
then require the adapter explicitly:

```yaml
dependencies:
  matter:
    github: Crystal-Matter/matter
  sqlite3:
    github: crystal-lang/crystal-sqlite3
```

```crystal
require "matter"
require "matter/storage/sqlite"

storage = Matter::Storage::Sqlite.new("matter.db")
storage.open
# Pass `storage` to a device or controller constructor accepting Storage::Backend.
```

The optional adapter also registers `sqlite:<path>` with `Storage::Migrator`,
so applications that require it can copy existing stores into SQLite. SQLite
uses a versioned SQL schema and a collision-free tagged JSON document encoding.
SQL operations use transactions, including savepoints for nested transactions;
an exception rolls back its transaction. SQLite and PostgreSQL share the same
SQL storage layer. The SQLite adapter opens the file
with SQLite WAL mode, full sync, and a five-second busy timeout.
On Windows, the native SQLite import library and DLL must also be installed;
for example, `vcpkg install sqlite3:x64-windows`, with the installed `lib`
directory in `CRYSTAL_LIBRARY_PATH` and `bin` directory in `PATH`.

PostgreSQL is also opt-in. Add `pg` to your application's `shard.yml`,
require the adapter explicitly, and pass a PostgreSQL connection URL:

```yaml
dependencies:
  matter:
    github: Crystal-Matter/matter
  pg:
    github: will/crystal-pg
```

```crystal
require "matter"
require "matter/storage/postgres"

storage = Matter::Storage::Postgres.new(ENV.fetch("MATTER_POSTGRES_URL"))
storage.open
```

The PostgreSQL adapter uses the same versioned tables and tagged document
encoding as SQLite. The database user needs permission to create and drop
`matter_storage_schema` and `matter_storage_documents`; `destroy!` removes
only those two tables, not the PostgreSQL database. Require the adapter before
using a `postgres://` URL with `Storage::Migrator`.

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
MATTER_E2E_BUILD_JOBS=1 ./test --e2e-only  # limit Crystal image builds on memory-constrained hosts
```

For a local run of one or a few specs, select every Compose service those specs
use. `--focused` builds only the selected device binaries (plus the small
`device_validation` helper), starts only those services, and skips unit specs.
It uses a separate Compose project and compiles one binary at a time by default.
For example, the Aliro and verified Door Lock specs each need their own fixture:

```shell
./test --focused --service door-lock-aliro --service door-lock-verified -- \
  e2e/spec/door_lock_aliro_spec.cr e2e/spec/door_lock_verified_spec.cr
```

List secondary services explicitly for specs that use peers (for example,
`--service joint-fabric-anchor --service joint-fabric-joiner`). Service names
come from `docker-compose.yml`; shared services resolve to their actual binary.
The full `./test` invocation and CI still compile and start every device.

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
