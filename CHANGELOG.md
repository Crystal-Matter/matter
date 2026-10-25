# Changelog

All notable changes to this project are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Door Lock

- Map Crystal's Sunday ordinal to Matter's Sunday bit when enforcing persisted
  week-day access schedules.

### General Diagnostics test payload

- Add opt-in Matter 1.6 DataModelTest with a nonzero 16-byte enable key,
  Manage-protected PayloadTestRequest/Response, a 2,048-byte cap, and the
  shared TestEventTrigger key gate. An isolated chip-tool fixture exercises it;
  production devices keep the feature disabled by default.

### Commodity Tariff rotating calendars

- Support rotating day patterns in calendar period order, including a durable
  start day for immediately active calendars and reset at each new period.

### Push AV Stream Transport

- Add a Matter 1.6 revision 2 Push AV configuration server with typed TLV
  commands and events, durable per-fabric connections, TLS endpoint reference
  tracking, and host-controlled transport activation. A chip-tool fixture
  checks the advertised empty catalog; actual CMAF media upload requires a
  host implementation.
- Preserve absent, Null, and concrete revision 1 stream IDs and conditional
  Motion fields across TLV and durable storage. Host selectors can resolve
  automatic stream requests to existing camera stream IDs.

### Commodity Tariff

- Add the Matter 1.6 revision 1 Commodity Tariff server with a validated,
  durable Pricing calendar, active day and price projections, and both
  mandatory lookup commands. The synthetic Aggregator fixture is covered by
  official chip-tool E2E. Other tariff feature families remain disabled.
### Camera AV Settings User Level Management

- Add the Matter 1.6 revision 1 MechanicalPan server with typed pan position
  and commands, validated host limits, an actuator callback, movement reporting,
  durable measured position, a synthetic fixture, and official chip-tool E2E.
  Digital PTZ, tilt, zoom, and presets remain unavailable.
  The fixture is an Aggregator and does not implement a complete Camera device.

### Joint Fabric DCL signer trust

- Let the JFA example select an explicit production HTTPS DCL gateway for
  operational VID checks. The official SDK JCM and three-Administrator VVS
  fixtures exercise that setting with a test CA; simultaneous test and
  production gateway settings fail closed.
- Compose explicit root and DCL signer trust for Administrators. The live
  three-Administrator scenario keeps B's ICAC and signed VVS through Joint
  Commissioning, restart, and Anchor transfer, using a test HTTPS DCL mirror
  with removal and mismatch denial checks.

### Camera AV Stream Management audio

- Add the Matter 1.6 revision 2 Audio feature with typed stream allocation and
  deallocation, capability and bandwidth checks, reference counts, microphone
  controls, privacy hooks, and durable settings. A synthetic Aggregator endpoint
  and official chip-tool E2E exercise the wire behavior; media transport and
  Camera device topology remain application and follow-on work.

### Smoke and CO Alarm device type

- Add the Matter 1.6 Smoke CO Alarm device type (0x0076, revision 2) and its
  required Power Source device type topology. The example now advertises a
  detector endpoint with Identify and a separate Power Source endpoint, and
  chip-tool checks both Descriptor device type lists and power mapping.
### Zone Management

- Add the Matter 1.6 revision 1 Zone Management server for user-defined
  Cartesian zones, durable trigger configuration, managed geometry commands,
  and ZoneTriggered/ZoneStopped timing with blind intervals. The synthetic
  Aggregator fixture exercises the wire surface with chip-tool. Per-zone
  sensitivity and focus zones remain unsupported.

### Pump Configuration and Control

- Add the Matter 1.6 revision 5 ConstantSpeed pump server with feature-gated
  attributes, managed mode requests, durable settings, host telemetry, and a
  synthetic Pump device for official chip-tool interoperability. Other
  regulation features and optional fault events remain unsupported.

### Closure Control and Closure Dimension

- Add Matter 1.6 revision 1 Closure Control and Closure Dimension servers with
  typed state, feature-gated commands, timed access, host motion admission,
  target/step handling, and a synthetic two-endpoint chip-tool fixture. Add
  Closure and Closure Panel device-type declarations. Composite parent/TagList
  support remains a follow-up.

### Content Control

- Add the provisional Matter 1.6 revision 1 Content Control server. Enable,
  BlockUnrated, on-demand and scheduled rating thresholds, blocked channels,
  and blocked applications have typed commands and durable state. A media host
  uses `playback_allowed?` and `on_policy_changed` to enforce playback policy;
  the synthetic Basic Video Player exercises these with official chip-tool.
  ScreenTime, PINManagement, and BlockContentTimeWindow cannot be selected yet.
### Smoke and CO Alarm

- Add the Matter 1.6 revision 2 Smoke CO Alarm server with Smoke, CO, or
  combined feature selection; typed alarm states and events; persisted alarm
  conditions; host-driven self tests, expiry, and physical inoperative reports;
  and revision 2 Unmounted reporting. A synthetic combined detector and official
  chip-tool test exercise commissioning, state reads, self-test, and restart.
  Hosts remain responsible for sensor detection, manufacturer-certified
  expression priority, audible/visual output, and Power Source consistency.

### Device Energy Management constraint based forecasts

- Add a Matter 1.6 PFR+CON profile with typed future power/energy constraints,
  ordered non-overlapping interval validation, host-approved forecast
  recomputation, CancelRequest, and opt-out restoration. A synthetic heater
  exercises request, cancellation, and restart with official chip-tool.

### Device Energy Management forecast adjustment

- Add a Matter 1.6 PFR+FA profile with mandatory per-slot adjustment limits,
  typed ModifyForecastRequest, host-approved replacement forecasts,
  CancelRequest and opt-out restoration. A synthetic adjustable heater
  exercises bounds checks, update, cancel, and restart with official chip-tool.

### Device Energy Management pausable operation

- Add the Matter 1.6 PFR+PAU profile with per-slot pause bounds, host-approved
  PauseRequest/ResumeRequest, Paused/Resumed events, duration expiry, and
  opt-out/host-state cancellation. An official chip-tool scenario exercises a
  synthetic washer's pause, resume, expiry, and restart behavior.

### Device Energy Management start time adjustment

- Add the Matter 1.6 PFR+STA profile with nullable earliest start, bounded
  latest end, host-approved rescheduling, CancelRequest, opt-out
  cancellation, and immediate command-driven Forecast reports. The synthetic
  washer-dryer exercises shift, cancel, and restart with official chip-tool.

### Device Energy Management forecast reporting

- Add typed Matter 1.6 PFR and SFR reporting profiles for the Device Energy
  Management server. Hosts publish nullable, bounded forecasts; slot schemas
  match the selected feature, ForecastID advances on updates, progress fields
  remain live without subscription churn, and forecasts reset on restart.
  The synthetic washer reports a two-stage PFR forecast to official chip-tool.
  The reporting-only profiles advertise no adjustment feature bits.

### Device Energy Management Power Adjustment

- Add a Matter 1.6 revision 4 Device Energy Management server with the PA
  feature, typed nameplate and capability data, opt-out handling, host-approved
  power adjustment and cancellation, timed completion, events, and restart
  reset. The synthetic water heater exercises reads and commands with official
  chip-tool. The PA-only profile advertises no other feature bits.

### Energy EVSE

- Add the Matter 1.6 revision 4 Energy EVSE server with mandatory Charging
  Preferences, typed charge commands and session events, validated daily
  target schedules, retained charging permission, and physical relay callbacks.
  The synthetic appliance fixture exercises the cluster through chip-tool.
  Optional SoC, Plug and Charge, RFID, and V2X features remain unavailable.

### Application Launcher

- Add the Matter 1.6 revision 2 Application Launcher server with typed app
  identifiers, opaque launch data, all six response statuses, optional nullable
  CurrentApp, and ApplicationPlatform gated CatalogList and command fields.
  Host callbacks own launch, stop, hide, and foreground focus changes; a
  synthetic video player exercises both platform and endpoint app paths with
  official chip-tool.

### Content App Observer

- Add the Matter 1.6 revision 1 Content App Observer server for Casting Video
  Clients. Its typed ContentAppMessage response is supplied by a host callback
  with authenticated fabric and peer node identity. Enforce request and
  response string limits, and exercise success and unrecognized data with
  official chip-tool.

### Optional PostgreSQL storage

- Add an opt-in PostgreSQL backend using the existing versioned SQL schema,
  typed document codec, and transaction implementation. The `pg` shard is a
  development dependency only; applications include it and require the
  adapter explicitly. Add a dedicated PostgreSQL contract job to CI.

### Account Login revision 2

- Add host-backed GetSetupPIN, Login, and Logout with typed Matter payloads,
  timed CASE access, a persistent per-fabric unique-request limiter, and a
  fabric-sensitive LoggedOut event. Extend the Content App fixture and official
  chip-tool E2E to exercise the account flow.

### Door Lock PIN lockout recovery

- Persist partial wrong-PIN attempts and the temporary lockout deadline so a
  restart cannot clear the lock's credential retry policy. Previous stored
  Door Lock documents remain readable. The cluster still advertises revision 9
  pending the remaining Matter 1.6 revision 10 feature audit.

### Door Lock verified local credentials

- Require an application supplied, ready local verifier before advertising RFID,
  fingerprint/finger-vein, or face credentials. A verified reader transaction
  resolves to an existing credential and user, then follows enabled-user,
  schedule, expiry, and one-use policy; unverified transactions and direct
  caller-supplied RFID/biometric operation sources cannot unlock. Add a
  synthetic RFID reader fixture and official chip-tool coverage without
  bundling a physical reader implementation.
### Door Lock duplicate credential data

- Reject duplicate PIN or RFID data in a different slot of the same credential
  type for SetCredential Add and Modify. A rejected write leaves users and
  credentials unchanged. Reject saved databases containing duplicate PIN or
  RFID data before changing live lock state; affected hosts must remove the
  duplicate records before restoring that saved database.

### Messages

- Add the Matter 1.6 revision 3 Messages server with typed message payloads,
  fabric-scoped queued messages and host-triggered events, global active message
  IDs, durable queue state, and cleanup on fabric removal. The Content App exercises
  present, restart, and cancel through official chip-tool. Optional confirmation,
  response, reply, and protected-message features remain unavailable until a
  host can provide their required user interactions.
- Enforce StartTime before host presentation, persist the receipt time for
  messages that start now, and remove messages and emit MessageComplete when
  Duration elapses, including after a device restart.
- Present messages with no StartTime or Duration using one captured clock
  reading, so a millisecond tick cannot make an immediate message appear early.

### Commodity Metering

- Add the Matter 1.6 revision 1 read-only Commodity Metering server. Hosts
  publish complete, capacity-checked quantities and clear unavailable data
  atomically; official chip-tool reads the utility-meter fixture.

### Commodity Price

- Add the Matter 1.6 revision 4 Commodity Price server with typed currency,
  current price, forecast periods, detailed response commands, and PriceChange
  events. Extend the synthetic utility meter and official chip-tool coverage.

### Electrical Grid Conditions

- Add the Matter 1.6 revision 1 Electrical Grid Conditions server with typed
  nullable period data, ordered Forecasting periods, local-generation carbon
  checks, controller writes, and CurrentConditionsChanged events. Extend the
  synthetic utility meter and official chip-tool coverage.

### Device Energy Management Mode

- Add the Matter 1.6 revision 2 Mode Base derivation with standard energy
  optimization tags, fixed mode catalogue, persisted CurrentMode and host
  transition callback. Extend the synthetic appliance-mode chip-tool fixture.

### Energy EVSE Mode

- Add the Matter 1.6 revision 2 Energy EVSE Mode server with validated Manual
  mode, fixed catalogue, persisted CurrentMode, and host transition callback.
  Extend the synthetic appliance-mode chip-tool fixture.

### Energy Preference

- Add the Matter 1.6 revision 1 Energy Preference server with EnergyBalance
  and LowPowerModeSensitivity feature gating, validated fixed scales and
  priority pairs, writable persisted preference indices, and migration to
  the nearest configured step after a scale change or restart. Exercise both
  features through the thermostat UI fixture and official chip-tool.

### Service Area

- Add the Matter 1.6 revision 2 Service Area server with typed area and map
  catalogues, SelectAreas command validation and host route callback, opt-in
  MAPS/PROG/CurrentArea/SkipArea behavior, and persisted selection reconciled
  against the current host catalogue. Extend the synthetic RVC and official
  chip-tool coverage with area selection and restart.

### Door Lock credential rules and defaults

- Match the Matter 1.6 defaults for one-touch locking, inside status LED,
  privacy mode button, and local programming features. Reject Dual and Tri
  user credential rules while the server supports only single-credential
  authorization. A saved database with Dual or Tri users is not restored;
  the host must migrate those records explicitly. Reject reserved local
  programming bits, while migrating the former stored `0xFF` default to the
  defined all-features mask `0x0F` without losing credentials. Hosts that
  relied on the previous enabled defaults can pass the corresponding
  `DoorLock` constructor options explicitly.

### Door Lock user lifecycle

- Apply DisposableUser one-open policy and persisted ExpiringUser deadlines
  across PIN and authenticated Aliro access. Report ForcedUser PIN operations,
  automatic user-status changes, and credential failures with typed events.
  Set the SendPINOverTheAir default to false and bound ExpiringUserTimeout to
  the Matter 1.6 range. Extend the official chip-tool restart scenario.
### Audio Output

- Add the Matter 1.6 revision 1 Audio Output server with a typed output
  catalogue, selectable current output, and opt-in NameUpdates renaming.
  Selection and user-renamed names persist across restart; updated host default
  names are used for outputs the user has not renamed. The host callback
  confirms a physical output change and reapplies the saved route at startup; a synthetic
  Aggregator fixture exercises both commands with official chip-tool.
- Copy OutputList on host assignment and return isolated reader copies so callers
  cannot mutate the advertised catalogue without validation or a data-version update.

### Meter Identification

- Add the Matter 1.6 revision 1 Meter Identification server and Electrical
  Utility Meter device type. Hosts provide nullable meter identity and optional
  protocol metadata; the PowerThreshold feature exposes the standard TLV
  structure with optional power values and a nullable source. A synthetic
  utility meter is exercised by the official chip-tool across restart.

### Microwave Oven device type

- Define the Matter 1.6 Microwave Oven device type and validate its required
  Operational State CountdownTime attribute. Add a real Microwave Oven
  endpoint to the appliance chip-tool fixture.

### Microwave Oven Control

- Add the Matter 1.6 revision 1 Microwave Oven Control server with numeric
  power, optional min/max/step limits and AddMoreTime, and host-approved
  SetCookingParameters coupled to Microwave Oven Mode. Validate all settings
  before applying any cluster state. Extend the synthetic appliance chip-tool
  test with invalid commands, accepted settings, and restart persistence.

### Microwave Oven Mode

- Add the Matter 1.6 revision 2 Microwave Oven Mode server with validated,
  fixed Normal/Defrost mode catalogue and persisted host-selected mode.
  Omit the disallowed ChangeToMode command, OnOff feature, StartUpMode, and
  OnMode. Extend the synthetic appliance mode chip-tool scenario.

### Refrigerator mode

- Add Matter 1.6 Refrigerator and Temperature Controlled Cabinet Mode revision
  3 with RapidCool/RapidFreeze tags, fixed catalogue validation, host-controlled
  transitions and persisted mode reconciliation. Extend the refrigerator
  fixture and official chip-tool test to exercise the mode across restart.

### Robotic vacuum cleaner clusters

- Add Matter 1.6 RVC Run Mode revision 4, RVC Clean Mode revision 5, and RVC
  Operational State revision 3. Mode catalogues enforce the derived Idle,
  Cleaning, Vacuum/Mop, and exclusive-tag requirements. DirectModeChange is
  opt-in; the two mode clusters coordinate active-cycle restrictions.
  Operational State reports derived errors and states, supports paired
  Pause/Resume and optional GoHome, and delegates physical actions to host
  callbacks. Include a synthetic RVC and official chip-tool interoperability
  coverage.

### Channel

- Add the Matter 1.6 revision 2 Channel server with typed channel, lineup,
  program guide, and recording payloads. Numeric tuning and wraparound skip
  are available without optional features; text matching follows the canonical
  identifier, affiliate, call sign, name, number priority. CL, LI, EG, and RP
  gate their attributes and commands. Host callbacks supply program guide
  data and recording actions. Lineup metadata refresh retains the tuned channel
  by channel number. A synthetic TV fixture exercises the server with official
  chip-tool.
- Copy ChannelList on host assignment and return isolated reader copies, keeping
  advertised channels aligned with the validated tuning catalogue and data version.
  Direct host assignments also replace the tuning catalogue and reconcile the
  current channel by channel number.
- Reject host ProgramGuideResponse paging tokens beyond the Matter 1.6
  8192-byte limit before encoding a command response.

### Content Launcher

- Add the Matter 1.6 revision 2 Content Launcher server with independent
  ContentSearch and URLPlayback feature gates, typed search, branding, and
  playback preference payloads, plus host callbacks for launch decisions.
  Branding colors accept only the canonical hex forms with six or eight digits.
  A synthetic Aggregator fixture exercises metadata and typed URL responses
  with official chip-tool; the host application owns the actual media player.
- Copy AcceptHeader on host assignment and return isolated reader copies. On
  restart, reconcile persisted fixed URL capabilities with the host's current
  AcceptHeader and SupportedStreamingProtocols configuration. Validate host
  assignments against the Matter 1.6 URL feature and size constraints.

### Joint Fabric transfer recovery

- Extend the three-Administrator live scenario with a restart after
  TransferAnchorComplete and before participant follow-up. Verify that the
  persisted transfer journal resumes follow-up without another CAT rotation.
  Skip the candidate's promoted Node ID when selecting follow-up participants
  after restart.

### Chime

- Add the Matter 1.6 revision 2 Chime server with validated installed sound
  choices, persisted selection and enablement, playback callback, and
  ChimeStartedPlaying event. Include a synthetic doorbell and chip-tool test.

### Groupcast PerGroup

- Add opt-in Matter 1.6 Groupcast PerGroup multicast addressing. Listener
  subscriptions follow each membership's address policy; capacity checks count
  configured policy addresses before a JoinGroup changes keys or membership.
  Preserve policy across restart and release addresses on LeaveGroup and fabric
  removal. Add a two-device shared-fabric delivery test with official chip-tool.

### Door Lock Aliro reader delegate

- Add an opt-in trusted host reader delegate for authenticated Aliro access,
  issuer step-up, same-user evictable endpoint key rotation and Aliro lock/user
  events. Expose required Aliro provisioning attributes and timed administrator
  Set/Clear reader commands only when a delegate is supplied. Keep BLE/UWB
  support disabled until a radio adapter is available.

### Refrigerator Alarm

- Add the Matter 1.6 Refrigerator Alarm server with the DoorOpen alarm,
  inherited Alarm Base read attributes and Notify event, plus a synthetic
  chip-tool interoperability example. Reset and ModifyEnabledAlarms remain
  absent as required by the derived cluster.

### Door Lock Aliro management groundwork

- Add durable local reader configuration and P-256 public-key credential
  management with issuer and shared endpoint capacity checks. Keep Aliro
  feature bits disabled until reader transport and mandatory Matter attributes
  and commands are implemented.

### Door Lock schedule authorization

- Enforce weekday and year-day access windows for scheduled users, including
  combined restrictions, unknown local time, and persisted schedules after
  restart. Apply holiday operating modes to remote operations and wire reads,
  validate weekday windows, and keep schedule denial from consuming the wrong
  PIN lockout budget. Reject Aliro feature flags until mandatory reader
  configuration is implemented. Extend the official chip-tool lock fixture.

### Oven mode and cavity state

- Add the Matter 1.6 Oven Mode (0x0049) and Oven Cavity Operational State
  (0x0048) revision 2 servers. Mode Base transitions support all oven tags,
  while cavity operation exposes optional Start/Stop and inherited state,
  phase, countdown, and event payloads. Omit the disallowed OnOff, startup
  mode, Pause, and Resume surfaces. Include a paired synthetic device and
  official chip-tool interoperability coverage.

### Door Lock credential durability

- Persist Door Lock users, credentials, and schedules with cluster attributes
  across device restart. Restore fabric attribution and reject malformed
  tables without applying partial state. A disabled or non-access user's PIN
  no longer authorizes remote operation. The official chip-tool test provisions
  a user and PIN, restarts the device, and verifies continued operation.

### Thermostat LTNE

- Add the Thermostat LocalTemperatureNotExposed feature bit. Host sensor
  updates continue to drive Auto mode, while LocalTemperature always reports
  TLV null and direct host writes cannot expose the measurement. Include a
  synthetic thermostat and official chip-tool check. Thermostat remains at
  revision 9 pending its other Matter 1.6 revision 11 behaviors.

### Appliance modes

- Keep fixed mode catalogues isolated from caller and read-result mutations.
  When stored CurrentMode is absent from an updated catalogue, restore the
  host-configured mode instead.
- Add Matter 1.6 revision 3 Dishwasher Mode and Laundry Washer Mode servers
  with shared Mode Base request/response types and validation of unique mode
  values, labels, and tag sets. Supported
  transitions update CurrentMode; unsupported values return the required
  ChangeToModeResponse status, and host callbacks can refuse a transition
  with failure text. Include a synthetic fixture and chip-tool coverage.

### Optional SQLite storage

- Add `Matter::Storage::Sqlite` as an explicitly required durable backend.
  Applications add the `sqlite3` shard themselves; it is a development-only
  dependency of Matter. The driver-neutral SQL layer uses a tagged JSON document
  codec, supports nested atomic transactions, and versions its physical schema
  for future migrations and a PostgreSQL adapter.
- Cover Joint Fabric controller restart on SQLite: preserve the controller's
  fabric credentials and pending Datastore node journal, roll back a failed
  state change, then resume RefreshNode without replaying AddPendingNode.

### Protocol coverage audit

- Count the existing Matter 1.6 HEPA, activated-carbon, and water-tank Resource
  Monitoring clusters in both canonical coverage reports. The declaration
  scanners now expand simple local cluster macros with literal arguments, so
  the reports no longer mislabel these implemented clusters as absent.

### Water Heater Mode and Management

- Add Matter 1.6 Water Heater Mode (0x009E, revision 1) and Water Heater
  Management (0x0094, revision 2) servers. The mode server validates required
  Off/Manual tags and shared Mode Base constraints (unique labels and tag sets,
  standard tag values, and manufacturer tag range). It handles ChangeToMode
  responses and keeps supported CurrentMode values across restart, falling back
  to the host's configured mode if a saved value is no longer supported.
  Management gates energy and tank percentage fields by feature, validates
  BoostInfo, and emits BoostStarted/BoostEnded around host-approved
  Boost and CancelBoost transitions. A thermostat-backed example exercises
  both clusters with official chip-tool.
- End an accepted boost and emit BoostEnded at its duration even if the host's
  cancellation callback rejects or raises. Log host failures so the physical
  heater can be diagnosed without leaving the protocol state Active.
### Laundry Dryer and Washer Controls

- Add Matter 1.6 Laundry Dryer Controls (0x004A, revision 1) and Laundry Washer
  Controls (0x0053, revision 2). Mode-dependent supported options, nullable
  dryer and spin selections, Spin/Rinse feature gates, Operate-level writes,
  host acceptance, and restart reconciliation follow the appliance rules. A
  mode may expose an empty SpinSpeeds list with no selected speed.
  A synthetic washer-dryer combo exercises both clusters with official
  chip-tool.

### Joint Fabric VVS interoperability

- Add a pinned matter.js 0.18.0 live device test for Crystal VID verification.
  It commissions the independent device, installs and reads back VVS/VVSC on
  the correct fabric, then checks fresh CASE SignVID responses against an
  HTTPS test DCL Root/ICA chain. Wrong VID, root, and removed records deny;
  active records accept. The signer and DCL records are synthetic, and this
  device test does not exercise JFA consent or production ledger freshness.
### Dishwasher Alarm

- Add the Matter 1.6 revision 1 Dishwasher Alarm server with six configurable
  alarm bits, inherited Alarm Base attributes and Notify event, optional Reset
  latching, and optional ModifyEnabledAlarms. Host reports physical conditions
  and can veto controller commands. Enabling an alarm recomputes State from
  the latest physical report. A synthetic device exercises the wire behavior
  with official chip-tool.

### Media Playback

- Add Matter 1.6 revision 2 Media Playback with mandatory Play, Pause, Stop,
  typed PlaybackResponse, and host-authorized state changes. AdvancedSeek,
  VariableSpeed, AudioTracks, TextTracks, and AudioAdvance features gate their
  attributes and commands. A synthetic player fixture and official chip-tool
  E2E exercise commissioning, feature metadata, and playback transitions.

### Durable fail-safe credential recovery

- Write a durable undo journal before provisional AddNOC and UpdateNOC fabric
  changes. On restart, remove an uncommitted added fabric or restore the prior
  CASE identity before operational startup; retain acknowledged credentials.
  Persist ACL grants and removals synchronously, and prune orphan fabric ACLs
  before a recycled fabric index can be used. File-backed restart and injected
  storage failure specs cover these boundaries.

### Durable Terms and Conditions acceptance

- Persist SetTCAcknowledgements received outside a fail-safe before returning
  success. On CommissioningComplete, save provisional acceptance and clear the
  credential undo journal in one file-backed transaction. File-backed crash
  regressions cover both acknowledged paths, failed file flushes, and a failed
  journal clear.

### Media Input

- Add the Matter 1.6 revision 1 Media Input server with typed InputInfo,
  InputType and command payloads. SelectInput updates CurrentInput after
  host acceptance, ShowInputStatus and HideInputStatus delegate presentation
  to the host, and feature-gated RenameInput updates the catalog. A
  synthetic Aggregator fixture exercises the cluster through official
  chip-tool, without claiming a complete media device type.
- On restart, reconcile saved selection and user-renamed names against the
  host's current input catalogue. Removed inputs and changed input types no
  longer replace the host's physical inputs; a removed selection falls back
  to the host's configured input. Host default names follow the current
  catalogue; old saved records without rename provenance use those defaults.

### Keypad Input

- Translate accepted SendKey repeats into host Press, Hold, and Release
  callbacks using the Matter 1.6 200 ms window. Track keys independently by
  endpoint and fabric; release state is transient across restarts. An injectable
  monotonic clock and timer make the timing behavior deterministic to test.
- Add the Matter 1.6 revision 1 Keypad Input server with all canonical CEC
  key values, NavigationKeyCodes, LocationKeys, and NumberKeys feature bits,
  and a typed SendKeyResponse. Advertised features accept their promised key
  sets; the host may declare additional keys and decides
  whether each press is valid in its current state. A synthetic Aggregator
  fixture exercises the command with official chip-tool without claiming a
  complete media device type.

### Matter 1.6 Groupcast Sender

- Add an opt-in root Groupcast SD feature for send-only and combined listener
  nodes. Send-only JoinGroup membership carries no listener endpoints or
  AuxiliaryACL and survives restart. Device applications can send one-way
  authenticated group Invoke and Write requests using their commissioned
  fabric, active epoch key, IANA multicast address, and durable counters.
  SenderTesting now accepts its feature-gated operation and emits only outbound
  test results, while ListenerTesting emits only inbound results. An official chip-tool
  test commissions a Sender and Listener on one fabric and verifies multicast
  On delivery before and after the Sender restarts.

### Application Basic revision 1

- Add the Matter 1.6 Application Basic server for Content App endpoints, with
  fixed application identity and allowed vendor list, optional vendor and
  product identity, administrator-only access to the allowed vendor list, and
  a host-reported running status that starts stopped after a process restart.
  The Content App example is commissioned and read with official chip-tool.

### Thermostat User Interface Configuration

- Add the Matter 1.6 revision 2 Thermostat User Interface Configuration
  server with the required display and keypad enums and the optional schedule
  programming visibility attribute. Writes use the XML Operate and Manage
  privileges, reject values outside the declared enums, and persist across
  restarts. A thermostat example exercises reads and writes with chip-tool.
### Target Navigator revision 2

- Add the Matter 1.6 Target Navigator server (`0x0505`) with a validated
  TargetList, optional CurrentTarget, NavigateTarget response statuses, and
  TargetUpdated event. Applications handle navigation through an explicit
  callback. A synthetic endpoint and official chip-tool test exercise
  commissioning, reads, response paths, and restart.

### Low Power cluster

- Add the opt-in Matter 1.6 Low Power revision 1 server. Its mandatory Sleep
  command has Operate access and delegates acceptance and physical transition
  to separate host callbacks; without them, it reports InvalidInState. The
  transition runs only after a successful InvokeResponse send. A synthetic
  device and official chip-tool test verify command dispatch and restart.
### Color Control revision 9

- Report fixed primary count and coordinates, require the CT coupling minimum,
  and apply the nonvolatile startup color temperature on ordinary restarts.
  Encode ColorLoopActive as bounded uint8, enforce feature dependencies, and
  align Options and startup attribute write privileges with Matter 1.6.
  Official chip-tool checks revision, required attributes, and restart behavior.

### Operational Vendor ID validation

- Reject reserved Vendor IDs in AddNOC and SetVIDVerificationStatement. AddNOC
  returns InvalidCommand; SetVIDVerificationStatement returns ConstraintError,
  matching the Matter 1.6 operational range of 1 through 0xFFF4 and the
  official `TC_OPCREDS_3_8` boundary check.
- Return ConstraintError for a well-typed SignVIDVerificationRequest challenge
  whose length is not 32 bytes, as required by official `TC_OPCREDS_3_8` step 5.
- Notify Fabrics and NOCs subscribers when SetVIDVerificationStatement changes
  operational metadata or a pending NOC update rolls that metadata back.
- Roll back uncommitted AddNOC and UpdateNOC changes when ArmFailSafe receives
  zero expiry or the timer expires. Restore the persisted CASE identity and
  fabric-scoped attributes, refresh operational discovery, retire old sessions,
  and notify Fabrics and NOCs subscribers. Preserve committed credentials after
  CommissioningComplete. The official `TC_OPCREDS_3_8` previously failed at
  step 18 because the pending fabric remained visible after ArmFailSafe(0).
- Validate the official `TC_OPCREDS_3_8` result using its actual SDK 1.6 log
  format: the script path, all 29 steps, the test method PASS, and both test
  summaries with zero skips. A captured successful SDK run guards the parser.

### Wake On LAN

- Add the Matter 1.6 Wake On LAN server (`0x0503`, revision 1). A host can
  advertise a validated upper-case 48-bit MAC address and a 16-byte IPv6
  link-local address; either optional attribute is omitted when unset. Both
  values are fixed and read-only. A synthetic Aggregator example and official
  chip-tool test exercise reads and restart without claiming a complete media
  device type or supplying physical sleep/wake behavior.

### Ambient Context Sensing HumanActivity slice

- Add an opt-in provisional Matter 1.6 Ambient Context Sensing revision 1 server
  with the HumanActivity feature, canonical SemanticTag payloads, bounded
  HoldTime and one active detection. Host observations emit typed start and end
  events; official chip-tool exercises the deterministic example hook. The
  other feature bits remain unavailable.

### Soil Measurement revision 1

- Add the Matter 1.6 Soil Measurement server and Soil Sensor device type. The
  fixed accuracy structure reports a single full-span SoilMoisture range with
  at most 10.00% maximum error; nullable percentage readings are range checked
  before publication. A Soil Sensor example is read through official chip-tool.

### Matter 1.6 Groupcast Listener

- Add an opt-in root Groupcast Listener with persistent, fabric-scoped
  membership and IANA multicast reception. Enable GKM GroupcastAdoption and
  Access Control AuxiliaryACL together, hide legacy group maps after adoption,
  and derive group access only for member endpoints. Datastore propagation
  uses Groupcast JoinGroup/LeaveGroup on adopting targets and records failed
  adoption against the pending group entry.

### Level Control revision 7 color temperature coupling

- Link Level Control and Color Control on the same endpoint. The Lighting
  feature now applies `Options.CoupleColorTempToLevel` to ordinary and WithOnOff
  commands, including per-command masks and transition ticks. Coupling follows
  the Color Control temperature mode and its physical and coupling limits.
  The official chip-tool example covers the Options write and command overrides.
  Level Control now advertises Matter 1.6 revision 7.

### Level Control revision 7 conformance slice

- Apply Operate and Manage write privileges from the Matter 1.6 XML, retain
  only CurrentLevel and StartUpCurrentLevel across restarts, expose all eight
  mandatory commands even without the OnOff feature, and mark CurrentFrequency
  as a scene attribute. Reject host CurrentLevel updates outside configured
  bounds before changing state. Color-temperature coupling is described above.

### Relative Humidity Measurement revision 5

- Advertise Matter 1.6 revision 5 with nullable fixed sensor limits and a
  fixed, nonnullable optional tolerance. Keep fixed attributes immutable after
  construction and validate host-assigned readings before changing the
  attribute or DataVersion. The humidity sensor example now checks the revision
  through official chip-tool.
### Occupancy Sensing revision 7

- Advertise revision 7 with a required sensing modality and optional
  OccupancyEvent feature. Emit a typed OccupancyChanged event only for actual
  state changes when that feature is selected. Occupancy remains volatile.
- Expose fixed HoldTimeLimits with optional, bounded HoldTime; gate PIR,
  ultrasonic, and physical-contact timing settings by HoldTime and sensing
  modality, and derive legacy sensor type fields from the selected modalities.
  Synchronize HoldTime with the equivalent legacy
  occupied-to-unoccupied delays, keep timing settings nonvolatile, reject
  changes to fixed sensor metadata and limits, and reject invalid threshold and
  HoldTime writes. The motion sensor example now applies
  HoldTime to its simulated detector samples; physical sensing and entry
  threshold filtering remain device-owned.

### Illuminance Measurement revision 5

- Advertise revision 5, mark the four sensor configuration attributes fixed,
  require MaxMeasuredValue to exceed a non-null MinMeasuredValue, and reject the
  nullable sentinel as a concrete reading. Reject later host changes to fixed
  configuration without changing DataVersion. The ambient-light chip-tool test
  reads ClusterRevision and the configured bounds, tolerance, and sensor type.

### Pressure Measurement

- Support Matter 1.6 Pressure Measurement revision 5, including the optional Extended feature with scaled pressure, range, tolerance, and scale attributes. Nullable capabilities and readings, fixed metadata, strict known bounds, and optional nonnullable tolerances now match the data model. Host updates validate ranges before notification and cannot change fixed configuration after construction; readings are volatile across restart. A Pressure Sensor example exercises the complete Extended set with official chip-tool.

### Joint Fabric SDK DCL and consent interoperability

- Add an opt-in HTTPS test DCL mirror that publishes the official SDK JFC's
  public operational root. The live JCM fixture tests wrong-VID and removed
  root rejection, active-root acceptance, explicit consent denial, and a
  successful consented commission. The JFA example can select this loopback
  mirror without a static trust fallback.

### Resource Monitoring

- Add opt-in Matter 1.6 HEPA Filter Monitoring, Activated Carbon Filter
  Monitoring, and Water Tank Level Monitoring servers (0x0071, 0x0072,
  0x0079; revision 1). Condition, Warning, and ReplacementProductList are
  optional features. The optional ResetCondition command requires host
  acceptance before resetting Condition and ChangeIndication; optional
  LastChangedTime has Operate write access and persists across restart. Fixed
  direction and replacement products reject later host changes.
  A three-endpoint example is exercised with official chip-tool.
### Temperature Measurement revision 6

- Align Temperature Measurement with Matter 1.6 revision 6. MinMeasuredValue
  and MaxMeasuredValue now default to null when capability limits are unknown;
  Min, Max, and optional nonnullable Tolerance report fixed quality. Validate
  readings against each known bound and reject invalid direct host updates
  before changing state. Fixed capabilities reject later host changes.
  MeasuredValue remains volatile. The temperature
  sensor example and chip-tool E2E cover nullable bounds and restart.

### Cross-ecosystem Joint Fabric control

- Let a joining Administrator issue a group-CAT controller identity under
  its cross-signed ICAC on the Anchor fabric. Validate the controller chain,
  keep the ICAC signing key with the issuer, and propagate an Administer ACL
  through the Anchor Datastore. The two-JFA E2E scenario now exercises a
  B-issued controller against a migrated A device before and after that grant
  and after the device restarts.

### Secure session ID allocation

- Allocate nonzero, unused responder session IDs across PASE, full CASE, and
  CASE resumption, including pending handshakes. This prevents rare CASE
  failures when a random responder ID is zero and avoids a handshake claiming
  an established or pending session ID. Deterministic protocol specs force
  each rejected candidate.

### Window Covering revision 8

- Advertise Window Covering revision 8, reject undefined Mode bits, synchronize
  ConfigStatus with Mode, and block movement in maintenance and calibration
  modes. Persist exposed current-position percentages and restore combined
  ConfigStatus flag values correctly after restart.

### Temperature Alarm

- Add the opt-in Matter 1.6 Temperature Alarm server (`0x0064`, revision 1),
  including Alarm Base Mask, Latch, State, Supported, Reset,
  ModifyEnabledAlarms and Notify. Over/under critical, major and minor
  thresholds follow the selected feature set. Physical readings publish alarm
  transitions; adjustable thresholds validate as one set and commit only after
  host acceptance. A synthetic device is exercised with official chip-tool.

### Temperature Control

- Add an opt-in Matter 1.6 Temperature Control server (`0x0056`, revision 1)
  for numeric centi-degree setpoints or ordered named levels. Numeric endpoints
  can advertise a discrete Step. The read-only attributes and SetTemperature
  command are feature-gated; range, step alignment, level labels and indexes
  are validated. A host callback accepts or refuses commands before state
  changes; accepted settings persist across restart. A synthetic two-endpoint
  fixture exercises both feature choices with official chip-tool.

### Time Synchronization time zone feature

- Add an opt-in Matter 1.6 TimeZone server on root endpoint 0, with validated
  SetTimeZone and SetDSTOffset commands, a computed LocalTime attribute,
  status/empty-table events, and nonvolatile offset lists. The default mode has
  no time-zone database, so a commissioner supplies DST offsets. UTC time is
  intentionally unsynchronized after restart. A synthetic root device checks
  the wire behavior with official chip-tool.

### Reverse commissioning handoff

- Add an opt-in official SDK v1.6 FabricAdmin/FabricBridge reverse-commissioning
  interoperability fixture with real Commissioner Control approval and
  response, deferred Crystal commissioning of the SDK bridge, attested test
  VID/PID, two-fabric counts, and CASE verification.
- Prepare Commissioner Control's enhanced-window response before starting the
  reverse commissioner. Run host commissioning only after the matching CASE
  InvokeResponse is sent, outside the protocol lock; discard the task if its
  response send fails. Match pending work to the secure session object and
  exchange, preserve approvals across failed preparation, and compare the
  attested target VID/PID with the approved request before AddNOC. Host consent
  and actual target commissioning remain application responsibilities.

### Controller mDNS discovery

- Resolve compressed DNS SRV targets from the decoded packet when discovering
  Matter devices. This allows a controller to find an SDK bridge whose
  operational and commissionable advertisements share a hostname.
- Give each controller client a random operational source Node ID for unsecured
  packets by default, so SDK peers accept its PASE and CASE handshakes. Preserve
  the caller's explicit unsecured source Node ID when provided.

### TLS Client Management

- Add opt-in Matter 1.6 TLS Client Management (0x0802, revision 1) with
  per-fabric TLS endpoint provisioning, lookup, reference counts, persistence,
  and fabric removal cleanup. Endpoint references now prevent removing a root
  or client certificate from the paired TLS Certificate Management cluster.
  An official chip-tool fixture covers the endpoint lifecycle across restart
  and two fabrics.

### TLS Certificate Management

- Add the opt-in Matter 1.6 TLS Certificate Management cluster (0x0801,
  revision 1) with per-fabric root and client certificates, device-generated
  P-256 CSRs, nonce signatures, certificate lookup and removal, and immediate
  persistence of private keys. Removing a fabric erases its certificate and key
  records. An official chip-tool fixture exercises the command surface.

### Scenes Management fabric isolation

- Scope all Scenes Management commands and FabricSceneInfo reads to the
  authenticated fabric. A second fabric can now use the same GroupID and
  SceneID without reading, replacing, recalling, or deleting the first
  fabric's scene. RemoveFabric erases only that fabric's persisted scenes and
  scene info before its local index is reused.
- Close the enhanced AdministratorCommissioning window when a commissioner
  completes or rolls back commissioning, releasing its PAKE state and allowing
  another administrator to open a fresh window immediately.

### Opt-in Matter TCP transport

- Add a bounded, incremental Matter TCP frame codec. It writes and reads the
  four-byte little-endian packet length, accepts fragmented or coalesced stream
  reads, and rejects zero-length or over-limit packets before body allocation.
- Add an opt-in TCP listener and controller connection path sharing the existing
  CASE/PASE and Interaction Model handler with UDP. Connections use one-time
  local route tokens; secure sessions stay bound to their authenticated TCP
  connection, and closed tokens cannot fall back to UDP.
- Permit a bounded 63,000-byte TCP packet, 60,000-byte Interaction Model
  payload, and negotiated BDX block for a live connection-bound secure session.
  The pinned Matter 1.6 SDK selects its large-payload budget from the TCP peer
  transport, without a separate CASE maximum-payload exchange. Keep the UDP
  packet cap at 1280 bytes and reject oversized subscription updates without
  advancing their event cursor; chunked subscription updates remain pending.
- Advertise operational `T=4` for TCP server support. The former `T=1` sets a
  reserved bit and prevented the official SDK from opening TCP CASE. A dedicated
  chip-tool end-to-end test now commissions the device over UDP, then reads 96
  FixedLabel entries over TCP CASE and verifies an encrypted ReportData packet
  exceeds the 1280-byte UDP limit.
- Exercise ephemeral TCP bind fallback with an injected first-bind collision
  instead of racing Windows TCP and UDP ephemeral-port allocation in the spec.

### Controller session ID allocation

- Choose nonzero, unused local session IDs before PASE and CASE advertise them.
  Retry random candidates against both the controller registry and shared
  transport reservations, then fail before sending when no candidate is usable.
### Joint Fabric Administrator removal recovery

- Extend the three-administrator Docker test through a second restart after
  RemoveAdmin commits but its acknowledgement is lost. The Anchor checks its
  restored Datastore AdminList before advancing the removal journal, blocks
  an uncertain automatic retry, and resumes Administrator CAT/NOC rotation
  without replaying RemoveAdmin. The final AdminList and CAT version are read
  over CASE. The same scenario checks that a removal without the outgoing
  Administrator's local consent leaves the fabric, AdminList, and CAT version
  unchanged. Legacy command-channel YAML files default the new test-only
  interruption flag to false. Remaining live interruption points are tracked
  in the Joint Fabric guide.
### Thread Border Router Management

- Add an opt-in Matter 1.6 Thread Border Router Management server (`0x0452`,
  revision 1) with the six mandatory attributes and CASE/Manage dataset
  commands. SetActive requires a timed invoke and an armed fail-safe; the host
  performs bounded activation and rollback. PANChange gates timed SetPending.
  Thread credentials remain in the host backend and are not saved in cluster
  persistence. Physical Thread routing still requires a compatible host stack.

### Operational State server

- Add the Matter 1.6 Operational State (0x0060) revision 3 server. It reports
  phase, state and error data, emits typed error and completion events, and
  optionally exposes Start, Stop, Pause and Resume. The default instance is
  monitor-only. Appliance hosts opt into commands and decide whether each
  transition is safe through an explicit callback; denied commands leave the
  state unchanged.
### Door Lock operating-mode conformance

- Correct `SoundVolume` wire values (`High = 2`, `Medium = 3`) and use a valid
  inverse `SupportedOperatingModes` default. Reject unsupported mode writes and
  feature maps that omit the required User feature for credentials. Door Lock
  continues to advertise revision 9 pending persistent credential storage and
  Aliro feature support; see [Door Lock conformance](docs/door-lock-conformance.md).


### Thread Network Directory

- Add the Matter 1.6 opt-in Thread Network Directory server with persistent cross-fabric datasets, strict Thread TLV validation, preferred-network constraints, and CASE-only credential retrieval.

### Thermostat setpoint adjustment

- Make `SetpointRaiseLower` reject Heat or Cool when the feature is absent.
  When Both reaches a limit, move both occupied setpoints by the same bounded
  amount. In Auto mode, adjust the opposite setpoint to keep the configured
  deadband or return `InvalidCommand` without changing either setpoint when
  that is impossible. The cluster still advertises revision 9 while the
  remaining revision 11 behavior is audited.

### Color Control mode selection

- Set ColorMode and EnhancedColorMode when an accepted timed or continuous
  color movement starts, including a zero-duration command whose target already
  matches the stored color. Official chip-tool E2E covers mode reads at the
  command boundary. Color Control remains at revision 7 pending a full Matter
  1.6 revision 9 audit.

### Window Covering position and feature composition

- Remove the AbsolutePosition feature and commands retired by Matter 1.6, and
  reject unsupported or dependent-only feature maps. Start nullable lift and
  tilt positions as unknown rather than assuming fully open. Apply UpOrOpen
  and DownOrClose to both supported axes with direction-aware
  OperationalStatus fields, and make StopMotion set each target to its last
  reported current position. The cluster still advertises revision 6 while
  further revision 8 behavior is implemented.

### Fan Control feature conformance

- Complete the Matter 1.6 Fan Control revision 6 audit: advertise revision 6,
  require Operate privilege for all writable attributes, and persist only
  FanMode as required by the revised quality flags. The air-conditioner
  chip-tool fixture checks Step, revision metadata, and restart behavior.
- Preserve the existing MultiSpeed default while allowing explicit feature maps
  without MultiSpeed to omit SpeedMax, SpeedSetting, and SpeedCurrent from the
  wire. Require Auto-compatible mode sequences when the Auto feature is enabled
  and require nonempty RockSupport and WindSupport maps for the corresponding
  features. Bound SpeedMax to 1–100. The air-conditioner example now explicitly
  selects MultiSpeed with Step.

### Commissioner Control host approval interface

- Add the Matter 1.6 Commissioner Control wire model and a fail-closed
  per-fabric, per-node approval state machine. An explicit host callback handles
  approval and target commissioning-window creation; a missing host cannot
  approve requests. A separate synthetic Aggregator verifies approval events
  and one-use reverse responses with official chip-tool. No ordinary device
  advertises this cluster.

### Wi-Fi Network Management

- Add an opt-in Matter 1.6 Wi-Fi Network Management server. A network
  infrastructure host supplies its current SSID and WPA-Personal passphrase;
  authorized CASE managers can request the passphrase. The cluster reports a
  changed surrogate when the passphrase changes and clears both nullable
  attributes when credentials are removed. The host retains durable credential
  storage and surrogate, then reprovisions the cluster after restart. A
  synthetic Aggregator fixture checks the wire behavior with official
  chip-tool without advertising the incomplete Network Infrastructure Manager
  device type.

### Level Control startup state

- Apply Lighting StartUpCurrentLevel after restoring persisted cluster state on
  ordinary device startup: zero selects MinLevel, null retains CurrentLevel,
  and another value selects that level. `Device#start(ota_restart: true)`
  retains the pre-update level after an OTA restart. The cluster continues to
  advertise revision 6 while the remaining revision 7 behavior is audited.

### Actions cluster

- Add the Matter 1.6 Actions server cluster (revision 1): bounded ActionList and
  EndpointLists, optional HTTPS SetupURL, all 12 command request forms, and
  StateChanged/ActionFailed events. Applications register an explicit callback
  to execute actions; the cluster reports state and handles duration expiry.
  It does not alter other endpoints itself.

### General Commissioning regulatory defaults

- Let wireless devices configure their fixed LocationCapability at construction.
  Initialize RegulatoryConfig to that same value, as required by Matter 1.6,
  including after a restart. Keep Ethernet-only devices at IndoorOutdoor.

### Access Control revision 3

- Encode mandatory nullable ACL Subjects, Targets, and target fields, and emit fabric-sensitive
  AccessControlEntryChanged and AccessControlExtensionChanged events for
  authenticated administrator writes. Event reads require Administer privilege;
  rejected writes do not emit change events. Scope ACL writes to the
  authenticated fabric and validate the advertised ACL and Extension limits.
  Reject fabricless PASE ACL and Extension writes before they can replace entries
  belonging to other fabrics.
  The provisional AUX and MNGD features remain disabled.

### Ecosystem Information for bridged nodes

- Add the Matter 1.6 Ecosystem Information cluster with read-only, persistent,
  fabric-scoped device and location directories. A bridge can publish
  application-consented metadata per fabric; removing a fabric erases its
  entries. Empty directories represent unavailable metadata. A separate
  synthetic bridge fixture verifies two-fabric isolation and restart reads
  through official chip-tool.

### Network commissioning scan responses

- Include the feature-required Wi-Fi or Thread scan result list on the wire
  even when a scan finds no networks or reports a networking error. An empty
  list remains an empty TLV array instead of disappearing from the response.
### Operational Credentials fabric-scoped commands

- Encode UpdateNOC with only NOCValue and optional ICACValue, and
  UpdateFabricLabel with only Label. Derive the fabric exclusively from the
  authenticated CASE session, including when a legacy request supplies an
  extra FabricIndex field. Reject fabricless PASE invokes before they can
  update another fabric.

### Timed Interaction Model enforcement

- Enforce timed command and writable attribute metadata on encrypted unicast
  InvokeRequest and WriteRequest paths. Untimed requests for timed operations
  return `NeedsTimedInteraction` (0xC6) without invoking the command or changing
  the attribute. A timed flag must match a TimedRequest on the same exchange;
  otherwise the request returns `TimedRequestMismatch` (0xC9). Expired timed
  windows return `Timeout`, and ACL checks retain precedence.
- Send timed invocations from the Crystal controller's enhanced window opener
  and from its basic-open and revoke CLI commands.

### Level Control unknown current level

- Report nullable CurrentLevel as TLV null, preserve unknown state across
  restarts, and resolve an absolute MoveToLevel immediately from that state.
  Relative Move and Step return Failure until a level is known. Becoming
  unknown cancels a pending transition and clears RemainingTime. Cluster
  revision remains 6 while the remaining revision 7 requirements are audited.
- Keep fixed MinLevel and MaxLevel from the configured server rather than
  restoring stale runtime values; clamp a restored known CurrentLevel to the
  configured range. Mark CurrentLevel as a scene attribute and reject zero
  writes to nullable DefaultMoveRate, whose defined range starts at 1.

### Group Key Management revision 3

- Advertise the Matter 1.6 revision 3 ClusterRevision while retaining the
  existing key-management behavior with optional provisional Groupcast
  disabled. Omit deprecated multicast policy tag 8 from new key sets and
  KeySetRead responses while accepting legacy input. Verify the revision
  through official chip-tool groupcast E2E.
### Joint Fabric legacy IPK recovery

- Repair a legacy Anchor Datastore whose GroupKeySetID zero lacks the fabric
  IPK, and write the repaired key to storage before serving the Datastore.
  Startup fails closed if that repair cannot be saved.
### Joint Fabric scoped IPv6 handoff

- Preserve the interface scope of a discovered link-local IPv6 peer when the
  joining Administrator is passed to the Anchor for its ICAC exchange. The
  Anchor can reconstruct the same scoped CASE route after the local handoff.

### Bridged configuration versions

- Advance optional Bridged Device Basic Information ConfigurationVersion for explicit bridge
  configuration changes, wrapping to one after UInt32 max. Standalone and grouped changes also
  advance the bridge root version once; both versions persist across restarts.

### General Diagnostics device load

- Advertise General Diagnostics revision 3 and its mandatory DeviceLoadStatus
  structure. Report active subscriptions for all fabrics and the accessing
  fabric, successful subscription establishments, and actual Interaction Model
  messages sent and received. Secure Channel traffic and MRP retransmissions
  do not inflate the IM counters.

### Level Control lighting bounds

- Default Lighting MinLevel and CurrentLevel to 1 and enforce its fixed
  MinLevel=1/MaxLevel=254 range. Non-Lighting configurations may use a custom
  range starting at zero, with MaxLevel no greater than 254. The advertised
  cluster revision remains 6 pending the remaining revision 7 behavior audit.

### Basic Information configuration version

- Add an explicit operation to advance ConfigurationVersion once after a
  successful logical configuration change, including uint32 wrap to one.
  Reject zero and direct regressions, and preserve the advanced value across
  restart. Runtime endpoint additions and removals advance it automatically;
  startup endpoint reconstruction does not. Repair an invalid saved zero
  before advertising the attribute.
- Encode the four additional mandatory Matter 1.6 revision 6 fields in
  CapabilityMinimaStruct, with spec-bounded defaults and provisioned values.

### General Diagnostics snapshot and boot event

- Implement revision 2 TimeSnapshot command and nullable POSIX response field.
  Record the mandatory critical BootReason event on device startup, defaulting
  to Unspecified when the platform cannot identify the cause.

### Boolean State Configuration

- Add the Matter 1.6 revision 2 Boolean State Configuration server with typed
  alarm and sensor-fault bitmaps, feature-gated attributes and commands,
  sensitivity bounds, alarm suppression, and typed alarm/fault events.
- Clear active and suppressed bits when an alarm mode is disabled; report
  InvalidInState when suppressing an inactive mode, as in the Matter 1.6 SDK.
- Persist sensitivity and enabled-alarm settings and include the cluster in
  the generated declaration coverage reports.

### Concentration measurement sensors

- Implement all ten Matter 1.6 Concentration Measurement derived clusters at
  revision 5 through one shared server definition. CO₂ retains its existing
  constructor and update API, now reports MED/CRI features with level support,
  accepts nullable numeric readings, and validates fixed bounds and windows.
- Add an Air Quality Sensor example endpoint with CO₂ and CO clusters and
  chip-tool reads for the device type, revision, medium, level, and reading.

### Protocol command and event coverage

- Add a reproducible Matter 1.6 canonical XML report for server command and
  event IDs declared by implemented Crystal clusters. It identifies direct
  mandatory ID gaps and shows conditional feature expressions for review,
  without claiming handler or event behavior conformance.

### Boolean State events

- Advertise Boolean State revision 3 with the ChangeEvent feature by default.
  Emit a typed StateChange event when StateValue changes, including direct
  setter changes, and omit the event when ChangeEvent is disabled. Application
  state-change callbacks continue to run independently.

### Bridged device revision 6

- Advertise Bridged Device Basic Information revision 6 and optionally expose
  its read-only, nonvolatile ConfigurationVersion. A supplied value must be
  positive and survives cluster state restoration.

### Bridged device identity

- Require a stable 1–32-byte UniqueID for Bridged Device Basic Information,
  advertise it as a mandatory fixed attribute at revision 5, and retain each
  dynamic endpoint's provisioned ID across bridge restarts.

### Color Control timed transitions

- Apply MoveTo and Step TransitionTime in deciseconds for hue, saturation, XY,
  color temperature, combined hue/saturation, and enhanced hue commands.
  RemainingTime counts down while a transition runs, and StopMoveStep freezes
  its interpolated value while leaving an active ColorLoop running. Hue honors
  the requested cyclic direction, and XY and color temperature stop at their
  Matter 1.6 bounds. Out-of-range MoveTo target fields return ConstraintError
  without interrupting an active transition. The advertised cluster revision
  remains 7.


### Group key validation

- Reject KeySetWrite requests without the first epoch or with a gap before a
  later epoch, and return ConstraintError for a malformed epoch key length.
  Rejected writes leave the fabric's existing key set unchanged. The provisional
  Matter 1.6 GCAST feature remains disabled and the advertised revision stays 2.

### Access control interoperability

- Decode Matter 1.6 AccessControlEntry AuxiliaryType (context tag 5), and
  reject entries carrying it in primary ACL writes without changing existing
  fabric ACLs. The controller ACL JSON helper also rejects this field instead
  of silently discarding it. The provisional AUX feature remains disabled.

### Protocol coverage report

- Add a reproducible Matter 1.6 cluster declaration report from the official
  XML data model. It compares IDs, revisions, and directly declared mandatory
  server attributes (including revision-only conditions) with Crystal DSL
  declarations and flags attributes declared optional in Crystal. Its stated
  limits distinguish declaration coverage from protocol conformance.

### Power Source endpoint mapping

- Expose the Matter 1.6 mandatory `EndpointList` (0x001F) on every Power
  Source instance, and let applications update the powered endpoint mapping.

### Standard application clusters

- Add Matter 1.6 Switch, Mode Select, and Valve Configuration and Control
  servers with feature-gated attributes and events, typed command payloads,
  bounded mode/position/level inputs, and a valve open-duration timer.
- Return InvalidCommand for a Mode Select ChangeToMode request naming an
  unadvertised mode, as required by the Matter 1.6 command definition.

### OnOff command level effect

- Apply LevelControl OnLevel when a sibling OnOff `On` command turns the device
  on. Use OnTransitionTime or OnOffTransitionTime for the level movement, while
  preserving the explicit target of LevelControl WithOnOff commands.

### Electrical measurement and topology

- Add Matter 1.6 Electrical Power Measurement (revision 3), Electrical Energy
  Measurement (revision 2), and Power Topology (revision 1) servers. Their
  fixed accuracy data and feature combinations are validated when configured.
- Encode measurement accuracy and range structs as Matter TLV. Publish the
  required range and cumulative/periodic energy events with feature-gated
  fields, and persist dynamic active endpoint sets.

### Level and OnOff coordination

- Wire sibling OnOff and LevelControl servers on an endpoint. Ordinary level
  commands obey ExecuteIfOff and command option overrides; WithOnOff commands
  turn on before raising a level and turn off after a transition reaches its
  minimum. Stopping a downward transition leaves OnOff unchanged.

### Level Control bounds

- Declare MinLevel and MaxLevel as always-present fixed attributes. They remain
  configurable when constructing the cluster; the advertised cluster revision
  stays at 6 until the remaining revision 7 semantics are implemented.

### Color Control continuous movement

- Run MoveHue, MoveSaturation, MoveColor and MoveColorTemperature over time at
  the requested rates instead of accepting them as no-ops. StopMoveStep and
  MoveMode Stop freeze the current value; zero rates for up/down moves return
  InvalidCommand. A monotonic clock drives movement and bounds are enforced.
- Run EnhancedMoveHue at its 16-bit rate with cyclic wrap, synchronized current
  hue and enhanced color mode. ColorLoopSet applies its update flags, moves
  through the enhanced hue circle in the configured direction and period, and
  restores the stored hue on deactivation. StopMoveStep leaves an active color
  loop running.

### Color Control and OnOff coordination

- Link sibling ColorControl and OnOff clusters. All Color Control commands
  apply OptionsMask and OptionsOverride to the Options attribute and leave
  color state unchanged while off unless ExecuteIfOff is set.

### Joint Fabric end-to-end coverage

- Verify a group-CAT controller can change an ordinary device's OnOff state
  after Datastore ACL propagation, retain access across a device restart, and
  observe changes made by the Anchor controller on the same fabric.

### Level control transitions

- Apply MoveToLevel and Step transition times in deciseconds and Move rates in
  levels per second. CurrentLevel and RemainingTime advance on autonomous
  monotonic ticks, and Stop holds the current level. RemainingTime resets after
  restart instead of restoring a stale countdown.

### Time synchronization

- Add the Matter 1.6 Time Synchronization base server: nullable UTC before sync,
  administrator SetUtcTime, monotonic time advancement, Granularity and
  TimeSource reporting, and a rate-limited TimeFailure event. Time state is
  discarded after restart until a trusted source updates it again.
- Reject SetUTCTime with NoTime granularity and preserve accepted source
  granularity, matching the Matter 1.6 SDK command behavior.

### On/Off timed lighting

- Implement the Lighting OnWithTimedOff command's decisecond OnTime countdown
  and guarded OffWaitTime period. Timer ticks update attributes and turn the
  device off without an application scheduler; timer counters reset on restart.

### BDX responder

- Serve up to four independent CASE BDX sessions concurrently with ordered,
  bounded work per session. Keep transfer reservations and stream state safe
  across callbacks, aborts, idle expiry, and session removal.
- Run authenticated BDX application callbacks and stream IO outside the global
  session registry lock on a bounded worker queue. Other CASE exchanges can
  proceed while a BDX stream waits; excess queued requests receive encrypted
  ResponderBusy status, and session cleanup closes streams off the registry lock.
  Handler shutdown stays bounded when an application callback remains blocked.

### Thread diagnostics

- Add the Matter 1.6 Thread Network Diagnostics revision 3 server with typed
  neighbor, route, policy, dataset and event payloads. Thread devices expose
  the cluster at endpoint 0; applications provide observed Thread state and
  counters through the cluster API.

### Scoped IPv6 peer hints

- Preserve link-local interface scope in commissioner handoffs, Joint Fabric
  pending registrations, Datastore recovery, and migrated node records.
- Select an IPv6 address when commissioning or subscribing to an Anchor
  Datastore discovered on a dual-stack network.

### Intermittently connected devices

- Add controller-side CASE RegisterClient/UnregisterClient, durable fabric-bound
  Check-In keys and counters, pending-key rotation, replay protection, and an
  unsolicited UDP Secure Channel Check-In observer. Fabric removal clears the
  associated controller keys; applications receive authenticated wake events.
  Accept a restarted ICD's fresh unsecured packet counter only for Check-In;
  the authenticated Check-In counter still rejects replay.
- Accept a restarted peer's CASE Sigma2/Sigma2Resume and final StatusReport
  after an outer packet counter reset only on an active, locally initiated CASE
  exchange for that peer. Keep exact-duplicate ACK handling and CASE
  certificate or resume-MIC verification.
- Implement Matter 1.6 ICD Management for explicitly configured ICD devices:
  feature-gated attributes and commands, fabric-scoped durable registrations,
  per-client Check-In backoff, StayActive responses, and registration cleanup
  after fabric removal. Encode Check-In using the official SDK's HMAC nonce and
  AES-CCM vector, persist the counter before sending, and expose application
  sleep/wake and operational-address hooks. Always-on devices remain absent.

### BLE transport framing

- Fall back from optional BlueZ `AcquireNotify` to `StartNotify` plus
  `PropertiesChanged(Value)` on C2, retaining duplicate indications and bounded
  delivery order while closing signal subscriptions on shutdown or failure.
- Add a Linux BlueZ central adapter with Matter service-data discovery,
  GATT connection and characteristic lookup, C1 writes, C2 `AcquireNotify`
  indications, and BTP v4 handshake. The D-Bus boundary supports mock-bus
  testing; physical BLE commissioning remains to be verified on hardware.
- Negotiate a central BTP v4 session over a GATT handshake channel. The
  controller writes C1, subscribes to C2, validates the response before its
  timeout, and bounds fragment/window sizes before opening the packet transport.
- Add a packet transport boundary shared by UDP and a GATT fragment channel.
  The BTP adapter now carries controller PASE and encrypted Interaction Model
  exchanges over an established BLE connection. Platform GATT discovery,
  connection setup, and BTP handshake negotiation still need an adapter.
- Add a GATT-independent BTP v4 session engine with ordered segmentation,
  reassembly, bounded peer/local windows, cumulative ACKs, and ACK/idle timeouts.
  A platform BLE adapter and PASE rendezvous remain follow-up work.
- Add the Matter 1.6 BTP handshake and data-packet codec with low-nibble-first
  version negotiation, little-endian lengths, ACK and segment flags, and strict
  malformed-frame checks. BLE GATT discovery, BTP flow control, and PASE over
  BLE are separate follow-up work.

### Foundation clusters

- Add Matter 1.6 Localization Configuration, Unit Localization, Power Source
  Configuration, Flow Measurement, and Air Quality cluster implementations.
  Locale and temperature unit writes validate supported values; applications
  can publish bounded sensor readings and power source endpoint lists.
### Enhanced Setup Flow Terms and Conditions

- Support the optional Matter 1.6 General Commissioning TC feature: advertise
  its admin-readable attributes and handle SetTCAcknowledgements with the
  specified command/response IDs and error codes. Acceptance made while the
  fail-safe is armed commits only after CommissioningComplete; expiry or a
  restart restores the previous committed acceptance.

### Node diagnostics

- Add Matter 1.6 Software Diagnostics and Wi-Fi Network Diagnostics cluster
  servers with feature-gated counters, watermarks, and diagnostic events. Wi-Fi
  devices now expose the Wi-Fi diagnostics cluster on their root endpoint;
  applications supply observed link values and counters.

### ICD advertisement

- Default always-on devices no longer advertise ICD Management. Matter 1.6
  treats that cluster's presence as an intermittently connected device; the
  cluster class remains available to devices that explicitly implement ICD
  behavior.

### Network commissioning

- Apply Network Commissioning command Breadcrumb values to General Commissioning
  only after successful scan, provisioning, removal, connection, or reordering.
  Failed commands and omitted Breadcrumb fields leave the attribute unchanged.
- Pass a platform network backend through the device constructor to the root
  Network Commissioning cluster. Wi-Fi and Thread scans, provisioning, removal,
  and connection now fail when no backend is configured, rather than reporting
  success for changes that were never applied.

### OTA Software Update Provider

- Add the Matter 1.6 Provider cluster's QueryImage, ApplyUpdateRequest, and
  NotifyUpdateApplied commands with typed TLV payloads and authenticated
  fabric/peer callbacks. Reject malformed update offers and tokens. QueryImage
  returns NotAvailable until an application supplies an image selector.

### OTA Software Update Requestor

- Support opt-in HTTPS image offers with bounded streaming and verified TLS,
  advertise user-consent capability only when an application callback is
  wired, and obtain consent before downloading when the provider requires it.
- Add typed AnnounceOTAProvider command and Requestor lifecycle events, plus a
  CASE QueryImage and BDX download client that stages a bounded image in
  caller-owned storage and validates its Matter header and payload digest.
  Expose ApplyUpdateRequest and NotifyUpdateApplied so applications can finish
  the provider handshake around their installer and reboot; an optional
  `apply_staged` callback runs only on immediate Proceed. Honor provider
  QueryImage delays before another query or BDX download.
- Persist DefaultOTAProviders per fabric, enforce the Matter 1.6 limit of one
  provider per fabric, and remove a provider when its fabric is removed.
  Accept writes that omit FabricIndex and bind them to the authenticated fabric.
- Report UpdatePossible as false until an application supplies an update engine.

### Controller commissioning

- Discover Network Commissioning feature maps on every endpoint during IP
  commissioning. Send SetRegulatoryConfig before device attestation when any
  instance advertises Wi-Fi or Thread; Ethernet-only nodes keep the previous
  flow. Wireless commissioning now requires an explicit regulatory location
  and two-letter country code.
- Refresh the fail-safe between long commissioning steps when its primary
  timeout falls below half the requested duration. Preserve the device's
  current Breadcrumb, reject command-level ArmFailSafe errors, and carry the
  refreshed deadline into durable Datastore registration and deferred JFA
  handoff records without exceeding the device's cumulative limit. Bound local
  deadlines from the ArmFailSafe send time, including delayed responses.

### Controller operational discovery

- Resolve CASE peers by compressed fabric ID and Node ID before using saved IP
  hints. Share this resolver with Joint Fabric datastore delivery and expose
  `CasePairing#pair_discovered`, which updates a node's stored address only
  after CASE authenticates it. The example chip-tool commands now use the same
  discovery order and defer address persistence until authentication succeeds.

### Commissioning interoperability

- Accept zero-valued RCAC and ICAC identifiers, which Matter 1.6 permits and
  Matter.js uses for its commissioning root. Return the specified Interaction
  Model errors from AddTrustedRootCertificate instead of reporting success for
  rejected certificates. Reusing an installed root now succeeds without a
  duplicate entry and selects that root for the next AddNOC.

### Operational certificates

- Derive Matter operational certificate SKID and AKID as SHA-1 of the complete
  uncompressed P-256 public key, matching connectedhomeip v1.6 certificate
  vectors. Root, intermediate, and node certificate signatures continue to
  use ECDSA with SHA-256.
- When issuing under a stored root or intermediate certificate, use that
  certificate's SKID as the new certificate's AKID. This keeps existing Crystal
  fabrics with legacy SHA-256-derived key identifiers internally consistent;
  their existing CA certificates still need reprovisioning for SDK conformance.

### Joint Fabric operational VID trust

- Reject NOC entries that supply both ICAC and VVSC, as required by Matter 1.6
  for the fabric-scoped NOC structure.
- Validate an optional Matter-TLV VVSC as a signed, current Vendor Verification
  Signer certificate through an approved DCL Root/ICA path, without requiring
  a duplicate DCL signer leaf. Check its VVS identity, key usage, CA flag,
  SKID/AKID, signing key, and issuer, and reject altered signatures or
  mismatched profiles.
- Bind a DCL OperationalPKI root to the candidate Matter RCAC by VID, RCAC ID,
  public key, and SKID. Require a VIDSignerPKI leaf with the Matter VID signer
  subject and a signed OperationalPKI Root/ICA CA path before accepting a VID
  Verification Statement signature. Reject unsupported critical signer-chain
  extensions and CA path length violations.
- Fetch operational DCL records from an explicit HTTPS origin with the existing
  1 MiB streaming limit, timeouts, and no redirects. Injected DCL sources remain
  available for separately authenticated mirrors.

### Bulk Data Exchange

- Bind Diagnostic Logs RetrieveLogsRequest to device-initiated BDX uploads for
  large logs. Send the InvokeResponse before the named transfer, enforce the
  authenticated CASE peer and fabric, and clear transfers with their session.
  Short BDX-requested logs use Exhausted with complete inline content.
- Preserve command data InvokeResponses when SuppressResponse is set, as
  required by Matter 1.6, while suppressing status-only InvokeResponses.
- Piggyback BDX BlockQuery acknowledgements on ReceiverDrive data blocks so
  Matter.js accepts the flow and duplicate queries replay the cached block.
- Add Matter 1.6 BDX v0 binary message codecs for transfer negotiation, block
  data, acknowledgements, and skip queries, plus a synchronous stream transfer
  engine with block ordering and definite-length checks.
- Route BDX over authenticated CASE exchanges with MRP response replay,
  StatusReport errors, file-designator authorization callbacks, bounded
  concurrent streams, idle cleanup, and session-removal cleanup. Add controller
  upload and download streaming APIs. The application supplies the source or
  sink for each authorized designator; no files are exposed by default.

### CASE session resumption

- Resume controller and device CASE sessions using the Matter 1.6 Sigma1 and
  Sigma2Resume MICs, derive matching session keys, and rotate the resumption ID
  after the Success exchange. Invalid or stale IDs fall back to full CASE.
- Persist peer-scoped resumption records across restarts, clear device and
  controller records when their fabric is removed, and bound retained records
  and pending handshakes.
- Enable persisted resumption for the Crystal chip-tool commands.

### Attestation revocation

- Validate Matter 1.6 partitioned and delegated DCL CRLs. Every partition
  requires a unique DCL label and URL, a matching critical IDP URL, a current
  signature, and issuer-scoped serial handling. Delegated PAA and PAI signers
  are checked against the candidate attestation authority before use.
- Add an opt-in DCL adapter for complete, directly signed PAA and PAI CRLs.
  It uses an explicit HTTPS DCL gateway and CRL host allowlist, permits
  explicitly approved HTTP hosts for signed CRLs, bounds downloads, rejects
  redirects, and fails closed when coverage or signer validation is incomplete.

### Interaction Model data version filters

- Decode and encode typed DataVersionFilterIB cluster paths for Read and
  Subscribe requests. Matching cluster versions suppress unchanged attribute
  reports; stale versions continue to return data, including on wildcard reads.
- Let controller reads and subscriptions supply data version filters, with a
  convenient version argument for a single attribute read.

### Conditional Interaction Model writes

- Enforce AttributeDataIB DataVersion on device writes. A stale version returns
  DataVersionMismatch without calling the cluster writer.
- Let controller single and batch writes carry cluster data versions for
  compare-and-write requests.
- Preserve a successful list replacement's original data version precondition
  for its subsequent append chunks on the same exchange.

### Interaction Model list writes

- Preserve the wire distinction between omitted and null `AttributePath.ListIndex`.
  Apply whole-list replacements and ordered list-item appends across chunked
  WriteRequests on one exchange, with a WriteResponse per chunk. Reject numeric
  list indices, orphan appends, and chunked timed writes with protocol statuses.
  Unicast writes now return WriteResponse even when SuppressResponse is set, as
  in the official SDK.
- Split large controller list writes into bounded replacement and append
  chunks, wait for each WriteResponse on the same exchange, and collect their
  statuses. Reject oversized individual items and multi-chunk timed writes
  before sending.

### Interaction Model subscriptions

- Honor `SubscribeRequest.KeepSubscriptions`: when false, terminate active and
  pending subscriptions from the same CASE node on the same fabric, including
  subscriptions carried by older secure sessions and persisted records. A true
  value retains those subscriptions.
- Expose the SubscribeRequest KeepSubscriptions option on the controller's
  mixed, event, and attribute subscription APIs. Existing calls continue to
  send `false` by default.

### Joint Fabric recovery verification

- Exercise persisted restart and interrupted network-command recovery at every
  Anchor transfer and Administrator removal journal boundary. Verify both
  observed completion without replay and explicit no-effect retry, and
  resume from each stable stage. The existing B-to-A device migration matrix
  covers its five command boundaries and rollback stages.

### Large Interaction Model reads

- Split oversized list attributes into an initial array report followed by
  append item reports that fit the IPv6 message budget. Return
  ResourceExhausted for an indivisible attribute or event payload that cannot
  fit, instead of sending an oversized datagram.

### Interaction Model invoke responses

- Split large InvokeResponse arrays into IPv6-sized messages. The device waits
  for Status.Success after each intermediate chunk, and the controller collects
  the chunks on one exchange with a deadline and size limit.
- Return ResourceExhausted for a single command result larger than the message
  budget. Correlate pending read, subscription, and invoke chunks by session and
  exchange ID so another controller cannot advance the exchange.

### Joint Fabric SDK interoperability

- Pass the unmodified official Matter 1.6 `TC_JFADMIN_2_1` and
  `TC_JFADMIN_2_2` multi-ecosystem JFA cases with isolated SDK issuer stores
  and a Crystal JFA. Keep the SDK issuer private material out of
  uploaded CI artifacts and convert its X.509 DER certificates to Matter TLV
  with subject and public-key checks.
- Verify an authenticated SDK Anchor from the Crystal JFA's operational UDP
  listener. A shared controller client keeps outbound CASE and VID verification
  on the device's advertised port while an ordered device worker handles other
  requests, preventing a peer from routing later JCM commands to a temporary
  verifier socket. Retain a verified CASE session for subsequent JCM commands;
  bind VID approval and CSR ownership to the authenticated Anchor node and
  fabric across CASE refreshes.

### Controller discovery

- Receive and query mDNS over IPv6 as well as IPv4, joining IPv6 multicast
  per interface on Unix. Scope link-local AAAA results to the announcing
  interface and omit them when that interface is unknown. Encode `::1` and
  scoped IPv6 literals correctly in device AAAA advertisements.
- Resolve operational and commissioning service addresses from the SRV target's
  A/AAAA records, including split mDNS replies and host address goodbyes. Persist
  updates to already discovered devices instead of changing a struct copy.
- Ignore DNS query known answers and non-Internet records, and accept
  case-insensitive DNS names while validating the complete operational
  instance identifier.

### Reliable messaging

- Keep in-progress PASE and CASE handshakes separate by peer endpoint and
  exchange ID. Concurrent commissioners may reuse an exchange ID without
  replacing each other's state, and unsecured follow-ups from another peer
  cannot advance the handshake. A shared 64-entry oldest-first limit bounds
  unauthenticated pending state while admitting new handshakes.
- Replay the original unsecured PASE or CASE response when a byte-identical
  request is retransmitted after response loss. Duplicate requests receive a
  fresh MRP ACK where required, while the handshake state and response packet
  counter remain unchanged. A bounded cache rejects altered and stale packets.
- Retransmit outbound unicast messages that request an MRP acknowledgement,
  retaining the exact encoded datagram and message counter. Device responses,
  subscription reports, controller requests, and unsecured commissioning
  requests share a bounded retry table. Authenticated secure ACKs and decoded
  unsecured ACKs clear the matching entry; session removal and shutdown clear
  pending packets.

### Exchange isolation

- Key active exchanges by session, peer address, and initiator role as well as
  exchange ID. Reusing an ID on another peer or direction no longer replaces
  an active conversation; local allocation skips IDs still in use in its scope.
  IPv4 addresses and their dual-stack IPv6-mapped form identify the same peer.

### Joint Fabric three-Administrator transfer

- Exercise two live Joint Commissioning joins, Anchor transfer, and removal
  across three Crystal Administrators, including restart during an uncertain
  removal journal transition. The targeted Docker scenario passes in 2:31.
- Bind a promoted Anchor's copied Datastore to its new fabric, retire the
  bootstrap Datastore, and discover the active Datastore endpoint over a
  verified CASE session. Restore the promoted role after restart with a
  rotated nonzero Anchor CAT version.
- Bind a joined Administrator's committed cross-signed ICAC to its fabric and
  issuer root. Locally signed ICACs require the expected ICAC ID and private-key
  proof; SDK-owned signers may use a distinct ICAC ID when the cross-signed key
  matches the commissioned ICAC and CSR signing remains remote.

### Controller groupcast

- Add `Controller::GroupInvoker` to install fabric-scoped operational group
  keys and send authenticated one-way group InvokeRequests and WriteRequests with durable message
  counters. The controller store removes a fabric's group keys when its last
  identity is removed.

### Groupcast runtime

- Accept authenticated, untimed group WriteRequests for writable attributes on
  member endpoints authorized by Group ACL, without a response. Add a private
  one-way group WriteRequest sender with durable counters and multicast routing.
- Receive private AES-CCM group messages on fabric-derived IPv6 multicast
  addresses, authenticate mapped epoch keys, retain replay windows, and invoke
  commands only on member endpoints authorized by a Group ACL. Group commands
  are one-way and produce no response.
- Add a durable-counter group InvokeRequest sender for applications with a
  group key and fabric identity.
- Keep Groups membership and names fabric-scoped, synchronize membership with
  GroupKeyManagement's GroupTable, and dispatch group command paths with an
  omitted endpoint to every authorized member endpoint. Parse authenticated
  message extensions without treating their opaque contents as commands.
- Remove group keys, mappings, names, and multicast memberships when a fabric
  is removed, before its local FabricIndex can be reused.

### PASE interoperability

- Include the required PasscodeID and HasPBKDFParameters fields in commissioner
  PBKDFParamRequest messages. Strict connectedhomeip responders previously
  rejected the incomplete request before PASE could begin.
- Reject malformed or incomplete PBKDFParamRequest messages at the responder
  with an InvalidParam secure-channel status report. When an initiator already
  has PBKDF parameters, omit them from PBKDFParamResponse as required.

The 0.2 refactor. Every layer of the library was reworked: storage, the device API, all 35
clusters, the interaction model and the protocol objects. It is a breaking release, and
**device storage written by 0.1 will not load** — see [Migrating from 0.1](#migrating-from-01).

### Shared fabric and certificate validation

- Discover active local IPv6 and IPv4 interfaces for Matter mDNS advertisements,
  including IPv6 unique-local addresses on networks without a public IPv6 route.
  Use loopback only if no usable interface is present.
- Encode generated operational certificate serial numbers as positive, minimal
  DER INTEGER content in their TLV field. This fixes intermittent rejection of
  Crystal-issued roots by the official Matter SDK during commissioning.
- Request and validate a device CSR before installing its new trusted root in
  ordinary commissioning and Anchor Administrator rotation. The official SDK
  rejects CSR allocation after a root has created pending fabric data.
- Activate a provisioned JFA Anchor from a valid ICAC and Anchor CAT even when
  the issuer omits Crystal's optional ICAC organizational unit, as the official
  Matter 1.6 controller does.
- Accept the official SDK's CSR ResponseStream for an outstanding ICAC request
  even when its optional transaction type is unset or inconsistent; verify the
  returned CSR against the pinned ICAC key before using it.
- Exercise five unmodified Matter 1.6 SDK JFA and Datastore certification
  scripts and one AdminList case with a DER-to-Matter-TLV certificate input
  adapter against a Crystal Anchor provisioned by SDK JFC. The separate CI
  job retains sanitized logs for every case and reports individual failures.
- Recover interrupted device migration commands after authenticated proof of
  completion or no effect. Verify both fabrics' Datastore ownership before
  declaring migration complete, and resume partially completed rollback.
  Persist CommissioningComplete acknowledgement before the local node record
  and the device's reported maximum cumulative fail-safe duration, so a restart
  can restore it only after verified A/B ownership and a fresh monotonic wait
  when the acknowledgement was lost. A restart
  then continues after read-only proof without replaying commissioning. Resume a pending
  Anchor NodeList registration with RefreshNode without replaying AddPendingNode.
- Add local command-sequence parity specs drawn from seven Matter 1.6 JFA/JFD
  certification scenarios. Return `ConstraintError` for an unknown Joint Fabric key
  security policy on the command wire, as `TC_JFDS_2_2` requires.
- Run the Matter 1.6 `TC_JFADMIN_1_2` Python certification steps against the
  Crystal JFA in an opt-in Linux SDK workflow, preserving device and test logs
  for interoperability failures.
- Serve defined JFA fail-safe and ICAC validation statuses on a freshly
  commissioned Administrator before it has joined a Joint Fabric.
- Accept SDK-issued ICACs that identify their intermediate authority without
  repeating the Fabric ID in the subject, while checking the issuer root and
  any Fabric ID that is present.
- Enforce signed Certification Declaration DAC origin VID/PID and authorized
  PAA identifiers during device attestation, including legitimate OEM chains.
- Accept length-delimited Matter Message Extensions and Secured Extensions as
  opaque bytes, preserving packet extension bytes in authenticated headers;
  round-trip vendor-qualified protocol IDs. Privacy enhancements still require
  the separate group-header deobfuscation path.
- Verify operational Vendor IDs using explicit DCL trust records: bind Matter
  RCACs to VID-scoped OperationalPKI roots and validate VVS signatures through
  active VIDSignerPKI certificate chains.
- Keep separate JFA services on the bootstrap B and joined A fabrics after
  JCM. Endpoint 2 now serves B's administrator commands and Datastore while
  endpoint 1 follows the cross-signed A ICAC, with fabric-scoped state across
  restart and removal.
- Issue locally signed Joint Fabric controller CAT NOCs and grant device access
  through Anchor Datastore groups, with idempotent retries and RefreshNode
  recovery. A live device test verifies CASE access before and after propagation.
- Persist each Administrator credential rotation during Anchor transfer so a
  restarted three-Administrator transfer can reconcile an uncertain rotation
  and skip credentials already updated under the new Anchor root.
- Verify Certification Declarations with CMS signed attributes, including their
  signed content type, encapsulated-content digest, and signature.
- Validate Joint Fabric Node IDs against the Matter 1.6 range before
  commissioning and Datastore registration; regenerate random candidates
  that collide with the Datastore NodeList.
- Add optional controller registration of commissioned devices with the Anchor
  Datastore, including durable AddPendingNode, RefreshNode, and RemoveNode
  recovery across restarts, and a chip-tool-backed Docker lifecycle test.
- Add delegated controller identities on an existing fabric, a separate
  certificate issuer for commissioning, and an ACL grant helper for shared
  controller access.
- Validate controller CASE peer certificates and device NOC updates against
  the fabric trust root, signed validity period, and intermediate fabric ID;
  bind commissioned NOCs to the device CSR key.
- Preserve a trusted root certificate's complete subject DN when issuing an
  intermediate, including cross signed Joint Fabric ICACs from external roots.
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
- Expose controller event reads and event-only or mixed subscriptions, with
  event-number filters, chunked reports, and event status validation.

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
