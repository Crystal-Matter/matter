# Matter 1.6 cluster declaration coverage

This is **declaration coverage**. It compares standard cluster IDs, declared
revisions, and only unconditional mandatory server attribute IDs in Matter
1.6 canonical or generated ZAP XML with Crystal cluster DSL declarations.
It does not verify types, feature-dependent requirements, commands, events,
behavior, interoperability,
or certification. A matching row is not a completeness claim.
The qualitative review notes are maintained in
[`protocol-coverage-notes.json`](protocol-coverage-notes.json); they are not
verified by this declaration scan.

See [server command and event declaration audit](protocol-command-event-coverage.md)
for a separate comparison of literal command and event IDs.

XML input: 127 files; XML tree SHA-256 `050dd40cab8d621fe1c97a4b8010095a41d927db4beb5059761567073bf89cba`.

- Standard XML clusters: 135
- Crystal declarations for those IDs: 135
- Matching known revisions: 133
- Clusters with mandatory attributes absent or optional in Crystal: 0
- XML clusters with unknown revision: 0
- Crystal IDs absent from the XML input: 0

| Cluster ID | XML name | XML rev | Crystal rev | Mandatory attrs absent / Crystal-optional | Review notes |
| --- | --- | ---: | ---: | --- | --- |
| 0x0003 | Identify Cluster | 6 | 6 | — | — |
| 0x0004 | Groups Cluster | 4 | 4 | — | — |
| 0x0006 | On/Off Cluster | 6 | 6 | — | — |
| 0x0008 | Level Control Cluster | 7 | 7 | — | — |
| 0x001D | Descriptor Cluster | 3 | 3 | — | — |
| 0x001E | Binding Cluster | 1 | 1 | — | — |
| 0x001F | Access Control Cluster | 3 | 3 | — | — |
| 0x0025 | Actions Cluster | 1 | 1 | — | — |
| 0x0028 | Basic Information Cluster | 6 | 6 | — | — |
| 0x0029 | OTA Software Update Provider Cluster | 1 | 1 | — | — |
| 0x002A | OTA Software Update Requestor Cluster | 1 | 1 | — | — |
| 0x002B | Localization Configuration Cluster | 1 | 1 | — | — |
| 0x002C | Time Format Localization Cluster | 1 | 1 | — | — |
| 0x002D | Unit Localization Cluster | 2 | 2 | — | — |
| 0x002E | Power Source Configuration Cluster | 1 | 1 | — | — |
| 0x002F | Power Source Cluster | 3 | 3 | — | — |
| 0x0030 | General Commissioning Cluster | 2 | 2 | — | — |
| 0x0031 | Network Commissioning Cluster | 2 | 2 | — | — |
| 0x0032 | Diagnostic Logs Cluster | 1 | 1 | — | — |
| 0x0033 | General Diagnostics Cluster | 3 | 3 | — | — |
| 0x0034 | Software Diagnostics Cluster | 1 | 1 | — | — |
| 0x0035 | Thread Network Diagnostics Cluster | 3 | 3 | — | — |
| 0x0036 | Wi-Fi Network Diagnostics Cluster | 1 | 1 | — | — |
| 0x0037 | Ethernet Network Diagnostics Cluster | 1 | 1 | — | — |
| 0x0038 | Time Synchronization Cluster | 2 | 2 | — | Opt-in TimeZone, NTPC, NTPS, and TSC features; the base server advertises no optional features by default |
| 0x0039 | Bridged Device Basic Information Cluster | 6 | 6 | — | Opt-in BIS KeepActive and ActiveChanged via a host adapter for external ICD check-ins; physical ICD transport remains host-owned |
| 0x003B | Switch Cluster | 2 | 2 | — | — |
| 0x003C | Administrator Commissioning Cluster | 1 | 1 | — | — |
| 0x003E | Operational Credentials Cluster | 2 | 2 | — | — |
| 0x003F | Group Key Management Cluster | 3 | 3 | — | — |
| 0x0040 | Fixed Label Cluster | 1 | 1 | — | — |
| 0x0041 | User Label Cluster | 1 | 1 | — | — |
| 0x0045 | Boolean State Cluster | 3 | 3 | — | — |
| 0x0046 | ICD Management Cluster | 3 | 3 | — | — |
| 0x0048 | Oven Cavity Operational State Cluster | 2 | 2 | — | — |
| 0x0049 | Oven Mode Cluster | 2 | 2 | — | — |
| 0x004A | Laundry Dryer Controls Cluster | 1 | 1 | — | — |
| 0x0050 | Mode Select Cluster | 2 | 2 | — | — |
| 0x0051 | Laundry Washer Mode Cluster | 3 | 3 | — | — |
| 0x0052 | Refrigerator And Temperature Controlled Cabinet Mode Cluster | 3 | 3 | — | — |
| 0x0053 | Laundry Washer Controls Cluster | 2 | 2 | — | — |
| 0x0054 | RVC Run Mode Cluster | 4 | 4 | — | Mode Base behavior; host-owned cleaning transitions and optional DirectModeChange |
| 0x0055 | RVC Clean Mode Cluster | 5 | 5 | — | Mode Base behavior; Vacuum/Mop options and run-mode guard |
| 0x0056 | Temperature Control Cluster | 1 | 1 | — | — |
| 0x0057 | Refrigerator Alarm Cluster | 1 | 1 | — | — |
| 0x0059 | Dishwasher Mode Cluster | 3 | 3 | — | — |
| 0x005B | Air Quality Cluster | 1 | 1 | — | — |
| 0x005C | Smoke CO Alarm Cluster | 2 | 2 | — | Host reports sensing, expression priority, audible output, Power Source consistency, and expiry clock |
| 0x005D | Dishwasher Alarm Cluster | 1 | 1 | — | — |
| 0x005E | Microwave Oven Mode Cluster | 2 | 2 | — | — |
| 0x005F | Microwave Oven Control Cluster | 1 | 1 | — | — |
| 0x0060 | Operational State Cluster | 3 | 3 | — | — |
| 0x0061 | RVC Operational State Cluster | 3 | 3 | — | typed derived states/errors, optional Pause/Resume and GoHome; host owns movement |
| 0x0062 | Scenes Management Cluster | 1 | 1 | — | — |
| 0x0064 | Temperature Alarm Cluster | 1 | 1 | — | — |
| 0x0065 | Groupcast Cluster | 1 | 1 | — | opt-in Listener, Sender, and PerGroup; provisional |
| 0x0071 | HEPA Filter Monitoring | 1 | 1 | — | — |
| 0x0072 | Activated Carbon Filter Monitoring | 1 | 1 | — | — |
| 0x0079 | Water Tank Level Monitoring | 1 | 1 | — | — |
| 0x0080 | Boolean State Configuration Cluster | 2 | 2 | — | — |
| 0x0081 | Valve Configuration and Control Cluster | 1 | 1 | — | — |
| 0x0090 | Electrical Power Measurement Cluster | 3 | 3 | — | — |
| 0x0091 | Electrical Energy Measurement Cluster | 2 | 2 | — | — |
| 0x0094 | Water Heater Management Cluster | 2 | 2 | — | Host controls thermostat, heat source, and boost acceptance |
| 0x0095 | Commodity Price Cluster | 4 | 4 | — | FORE forecast, detailed response commands and PriceChange event |
| 0x0097 | Messages Cluster | 3 | 3 | — | Fabric-scoped queue, StartTime/Duration lifecycle, and host-triggered presentation; optional user-interaction features remain absent |
| 0x0098 | Device Energy Management Cluster | 4 | 4 | — | PA, PFR, SFR, PFR+STA, PFR+PAU, PFR+FA, or PFR+CON profiles; each adjustment uses a host decision |
| 0x0099 | Energy EVSE Cluster | 4 | 4 | — | — |
| 0x009B | Energy Preference Cluster | 1 | 1 | — | BALA/LPMS feature choice; validated scales, persisted selections and restart migration |
| 0x009C | Power Topology Cluster | 1 | 1 | — | — |
| 0x009D | Energy EVSE Mode Cluster | 2 | 2 | — | Mode Base transitions, fixed options with a Manual mode and persisted selection |
| 0x009E | Water Heater Mode Cluster | 1 | 1 | — | Mode Base response and required Off/Manual tags; host controls transitions |
| 0x009F | Device Energy Management Mode Cluster | 2 | 2 | — | Mode Base transitions, fixed options and persisted selection; disallowed OnOff attributes absent |
| 0x00A0 | Electrical Grid Conditions Cluster | 1 | 1 | — | FORE periods, nullable current conditions and typed change event |
| 0x0101 | Door Lock Cluster | 10 | 9 | — | Durable users, schedules, Aliro delegate, and disposable/expiring user policies; UBOLT requires a host actuator; BLE/UWB radio and remaining revision 10 audit remain |
| 0x0102 | Window Covering Cluster | 8 | 8 | — | Actuator position reporting remains application-owned |
| 0x0104 | Closure Control Cluster | 1 | 1 | — | — |
| 0x0105 | Closure Dimension Cluster | 1 | 1 | — | — |
| 0x0150 | Service Area Cluster | 2 | 2 | — | SelectAreas and selected-state persistence; MAPS/PROG/CurrentArea/SkipArea opt-in, physical route host-owned |
| 0x0200 | Pump Configuration and Control Cluster | 5 | 5 | — | ConstantSpeed profile only; host owns physical mode change and telemetry |
| 0x0201 | Thermostat Cluster | 11 | 9 | — | SetpointRaiseLower limits and Auto deadband; opt-in TEVT base/AUTO events; Preset and MSCH host foundations behind production gates; OCC, MSCH, PRES and TSUGGEST remain unavailable on the wire |
| 0x0202 | Fan Control Cluster | 6 | 6 | — | feature-gated attributes and Step; only FanMode nonvolatile |
| 0x0204 | Thermostat User Interface Configuration Cluster | 2 | 2 | — | — |
| 0x0300 | Color Control Cluster | 9 | 9 | — | — |
| 0x0400 | Illuminance Measurement Cluster | 5 | 5 | — | Fixed sensor configuration, nullable bounds and reading, optional Tolerance/LightSensorType; host owns sampling |
| 0x0402 | Temperature Measurement Cluster | 6 | 6 | — | — |
| 0x0403 | Pressure Measurement Cluster | 5 | 5 | — | Extended feature, optional tolerances, fixed sensor bounds and scale |
| 0x0404 | Flow Measurement Cluster | 5 | 5 | — | — |
| 0x0405 | Relative Humidity Measurement | 5 | 5 | — | Nullable immutable limits, fixed optional tolerance, and host reading validation |
| 0x0406 | Occupancy Sensing Cluster | 7 | 7 | — | HoldTime limits and synchronized legacy delay, modality-gated timing, optional OccupancyEvent; entry threshold filtering remains device-owned |
| 0x040C | Carbon Monoxide Concentration Measurement | 5 | 5 | — | — |
| 0x040D | Carbon Dioxide Concentration Measurement | 5 | 5 | — | — |
| 0x0413 | Nitrogen Dioxide Concentration Measurement | 5 | 5 | — | — |
| 0x0415 | Ozone Concentration Measurement | 5 | 5 | — | — |
| 0x042A | PM2.5 Concentration Measurement | 5 | 5 | — | — |
| 0x042B | Formaldehyde Concentration Measurement | 5 | 5 | — | — |
| 0x042C | PM1 Concentration Measurement | 5 | 5 | — | — |
| 0x042D | PM10 Concentration Measurement | 5 | 5 | — | — |
| 0x042E | Total Volatile Organic Compounds Concentration Measurement | 5 | 5 | — | — |
| 0x042F | Radon Concentration Measurement | 5 | 5 | — | — |
| 0x0430 | Soil Measurement Cluster | 1 | 1 | — | Fixed accuracy limits and nullable validated percentage reading; Soil Sensor chip-tool E2E |
| 0x0431 | Ambient Context Sensing Cluster | 1 | 1 | — | HA-only provisional slice; OC, OI, AUD and PRED remain unavailable |
| 0x0451 | Wi-Fi Network Management Cluster | 1 | 1 | — | — |
| 0x0452 | Thread Border Router Management Cluster | 1 | 1 | — | — |
| 0x0453 | Thread Network Directory Cluster | 1 | 1 | — | — |
| 0x0503 | Wake On LAN Cluster | 1 | 1 | — | — |
| 0x0504 | Channel Cluster | 2 | 2 | — | — |
| 0x0505 | Target Navigator Cluster | 2 | 2 | — | — |
| 0x0506 | Media Playback Cluster | 2 | 2 | — | — |
| 0x0507 | Media Input Cluster | 1 | 1 | — | host-owned source switching and status display |
| 0x0508 | Low Power Cluster | 1 | 1 | — | host-owned physical sleep after InvokeResponse |
| 0x0509 | Keypad Input Cluster | 1 | 1 | — | — |
| 0x050A | Content Launcher Cluster | 2 | 2 | — | — |
| 0x050B | Audio Output Cluster | 1 | 1 | — | — |
| 0x050C | Application Launcher Cluster | 2 | 2 | — | host callbacks own app lifecycle and foreground focus; platform and endpoint app chip-tool E2E |
| 0x050D | Application Basic Cluster | 1 | 1 | — | Fixed identity, administrator-only AllowedVendorList, volatile host status; Content App chip-tool E2E |
| 0x050E | Account Login Cluster | 2 | 2 | — | Host-owned account credentials; timed, fabric-scoped commands and LoggedOut event; Content App chip-tool E2E |
| 0x050F | Content Control Cluster | 1 | 1 | — | Core and PM/BU/OCR/SCR/BC/BA policy; ST/BTW unavailable |
| 0x0510 | Content App Observer Cluster | 1 | 1 | — | Casting Video Client host interprets app-specific messages from authenticated fabric and node; chip-tool E2E |
| 0x0550 | Zone Management Cluster | 1 | 1 | — | TWODCART/USERDEFINED; per-zone sensitivity and focus zones absent |
| 0x0551 | Camera AV Stream Management Cluster | 2 | 2 | — | ADO/VDO/SNP allocation slices and host JPEG capture; synthetic chip-tool SNP E2E, media delivery and Camera topology remain |
| 0x0552 | Camera AV Settings User Level Management Cluster | 1 | 1 | — | MPAN only |
| 0x0553 | WebRTC Transport Provider Cluster | 2 | 2 | — | ADO and VDO-only signaling, host Peer interface, and synthetic chip-tool E2E; no decoded video or independently verified SDP/ICE media transport |
| 0x0554 | WebRTC Transport Requestor Cluster | 2 | 2 | — | — |
| 0x0555 | Push AV Stream Transport Cluster | 2 | 2 | — | — |
| 0x0556 | Chime Cluster | 2 | 2 | — | — |
| 0x0700 | Commodity Tariff Cluster | 1 | 1 | — | Pricing calendar; other feature families unavailable |
| 0x0750 | Ecosystem Information Cluster | 1 | 1 | — | — |
| 0x0751 | Commissioner Control Cluster | 1 | 1 | — | — |
| 0x0752 | Joint Fabric Datastore Cluster | 1 | 1 | — | — |
| 0x0753 | Joint Fabric Administrator Cluster | 1 | 1 | — | — |
| 0x0801 | TLS Certificate Management Cluster | 1 | 1 | — | opt-in; host backend holds client private keys |
| 0x0802 | TLS Client Management Cluster | 1 | 1 | — | opt-in; certificate-backed endpoint registry, host owns TLS connections |
| 0x0B06 | Meter Identification Cluster | 1 | 1 | — | — |
| 0x0B07 | Commodity Metering Cluster | 1 | 1 | — | — |

Regenerate from the official connectedhomeip `v1.6.0.0` tag:

```sh
git clone --depth 1 --branch v1.6.0.0 https://github.com/project-chip/connectedhomeip.git /tmp/connectedhomeip-1.6
python3 scripts/protocol_coverage.py \
  --xml-root /tmp/connectedhomeip-1.6/data_model/1.6/clusters \
  --crystal-root src/matter/cluster --output docs/protocol-coverage.md
python3 -m unittest discover -s scripts -p 'test_protocol_coverage.py'
```

The committed report uses the canonical Matter 1.6 data model XML. The
script also accepts the generated ZAP XML tree with its separate schema;
the counts can differ because the generated tree expands templates.
This report intentionally excludes vendor/test IDs above 0x7FFF and abstract
templates without a cluster ID. It counts only attributes directly declared
in each canonical XML file with unconditional mandatory conformance; it
does not resolve inherited attributes. XML attributes marked optional or whose
mandatory conformance has a feature condition are excluded. Simple current
revision thresholds are evaluated against the XML cluster revision. Crystal declarations
with `optional: true` count as a gap for unconditional mandatory XML
attributes even when the attribute ID is present.
Crystal parsing recognizes literal DSL declarations and simple same-file cluster
macros instantiated with literal arguments in `src/matter/cluster/*.cr`.
Other generated declarations, dynamically computed attributes, and runtime
feature gating require separate review.
Edit `docs/protocol-coverage-notes.json` to maintain the separate qualitative
notes; regeneration preserves them.
