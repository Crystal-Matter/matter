# Matter 1.6 server command and event declaration audit

This compares canonical Matter XML IDs with Crystal cluster DSL declarations
for implemented standard clusters. A declared ID does not prove a working handler,
correct payload, event emission, feature gating, or interoperability. This is not a completeness claim.
Feature and complex conditions are displayed for manual review, not evaluated.

XML input: 127 files; XML tree SHA-256 `050dd40cab8d621fe1c97a4b8010095a41d927db4beb5059761567073bf89cba`.

- Implemented standard cluster IDs compared: 135
- Direct or revision-active mandatory server command IDs absent: 0
- Direct or revision-active mandatory event IDs absent: 0
- Conditional command/event declarations for review: 192
- Feature or complex conditional IDs absent from Crystal: 24
- Feature or complex conditional IDs declared without literal `requires:`: 15
  (Neither count alone establishes a conformance failure.)

| Cluster ID | XML name | XML rev | Crystal rev | Mandatory server commands absent | Mandatory events absent |
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
| 0x0038 | Time Synchronization Cluster | 2 | 2 | — | — |
| 0x0039 | Bridged Device Basic Information Cluster | 6 | 6 | — | — |
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
| 0x0054 | RVC Run Mode Cluster | 4 | 4 | — | — |
| 0x0055 | RVC Clean Mode Cluster | 5 | 5 | — | — |
| 0x0056 | Temperature Control Cluster | 1 | 1 | — | — |
| 0x0057 | Refrigerator Alarm Cluster | 1 | 1 | — | — |
| 0x0059 | Dishwasher Mode Cluster | 3 | 3 | — | — |
| 0x005B | Air Quality Cluster | 1 | 1 | — | — |
| 0x005C | Smoke CO Alarm Cluster | 2 | 2 | — | — |
| 0x005D | Dishwasher Alarm Cluster | 1 | 1 | — | — |
| 0x005E | Microwave Oven Mode Cluster | 2 | 2 | — | — |
| 0x005F | Microwave Oven Control Cluster | 1 | 1 | — | — |
| 0x0060 | Operational State Cluster | 3 | 3 | — | — |
| 0x0061 | RVC Operational State Cluster | 3 | 3 | — | — |
| 0x0062 | Scenes Management Cluster | 1 | 1 | — | — |
| 0x0064 | Temperature Alarm Cluster | 1 | 1 | — | — |
| 0x0065 | Groupcast Cluster | 1 | 1 | — | — |
| 0x0071 | HEPA Filter Monitoring | 1 | 1 | — | — |
| 0x0072 | Activated Carbon Filter Monitoring | 1 | 1 | — | — |
| 0x0079 | Water Tank Level Monitoring | 1 | 1 | — | — |
| 0x0080 | Boolean State Configuration Cluster | 2 | 2 | — | — |
| 0x0081 | Valve Configuration and Control Cluster | 1 | 1 | — | — |
| 0x0090 | Electrical Power Measurement Cluster | 3 | 3 | — | — |
| 0x0091 | Electrical Energy Measurement Cluster | 2 | 2 | — | — |
| 0x0094 | Water Heater Management Cluster | 2 | 2 | — | — |
| 0x0095 | Commodity Price Cluster | 4 | 4 | — | — |
| 0x0097 | Messages Cluster | 3 | 3 | — | — |
| 0x0098 | Device Energy Management Cluster | 4 | 4 | — | — |
| 0x0099 | Energy EVSE Cluster | 4 | 4 | — | — |
| 0x009B | Energy Preference Cluster | 1 | 1 | — | — |
| 0x009C | Power Topology Cluster | 1 | 1 | — | — |
| 0x009D | Energy EVSE Mode Cluster | 2 | 2 | — | — |
| 0x009E | Water Heater Mode Cluster | 1 | 1 | — | — |
| 0x009F | Device Energy Management Mode Cluster | 2 | 2 | — | — |
| 0x00A0 | Electrical Grid Conditions Cluster | 1 | 1 | — | — |
| 0x0101 | Door Lock Cluster | 10 | 10 | — | — |
| 0x0102 | Window Covering Cluster | 8 | 8 | — | — |
| 0x0104 | Closure Control Cluster | 1 | 1 | — | — |
| 0x0105 | Closure Dimension Cluster | 1 | 1 | — | — |
| 0x0150 | Service Area Cluster | 2 | 2 | — | — |
| 0x0200 | Pump Configuration and Control Cluster | 5 | 5 | — | — |
| 0x0201 | Thermostat Cluster | 11 | 9 | — | — |
| 0x0202 | Fan Control Cluster | 6 | 6 | — | — |
| 0x0204 | Thermostat User Interface Configuration Cluster | 2 | 2 | — | — |
| 0x0300 | Color Control Cluster | 9 | 9 | — | — |
| 0x0400 | Illuminance Measurement Cluster | 5 | 5 | — | — |
| 0x0402 | Temperature Measurement Cluster | 6 | 6 | — | — |
| 0x0403 | Pressure Measurement Cluster | 5 | 5 | — | — |
| 0x0404 | Flow Measurement Cluster | 5 | 5 | — | — |
| 0x0405 | Relative Humidity Measurement | 5 | 5 | — | — |
| 0x0406 | Occupancy Sensing Cluster | 7 | 7 | — | — |
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
| 0x0430 | Soil Measurement Cluster | 1 | 1 | — | — |
| 0x0431 | Ambient Context Sensing Cluster | 1 | 1 | — | — |
| 0x0451 | Wi-Fi Network Management Cluster | 1 | 1 | — | — |
| 0x0452 | Thread Border Router Management Cluster | 1 | 1 | — | — |
| 0x0453 | Thread Network Directory Cluster | 1 | 1 | — | — |
| 0x0503 | Wake On LAN Cluster | 1 | 1 | — | — |
| 0x0504 | Channel Cluster | 2 | 2 | — | — |
| 0x0505 | Target Navigator Cluster | 2 | 2 | — | — |
| 0x0506 | Media Playback Cluster | 2 | 2 | — | — |
| 0x0507 | Media Input Cluster | 1 | 1 | — | — |
| 0x0508 | Low Power Cluster | 1 | 1 | — | — |
| 0x0509 | Keypad Input Cluster | 1 | 1 | — | — |
| 0x050A | Content Launcher Cluster | 2 | 2 | — | — |
| 0x050B | Audio Output Cluster | 1 | 1 | — | — |
| 0x050C | Application Launcher Cluster | 2 | 2 | — | — |
| 0x050D | Application Basic Cluster | 1 | 1 | — | — |
| 0x050E | Account Login Cluster | 2 | 2 | — | — |
| 0x050F | Content Control Cluster | 1 | 1 | — | — |
| 0x0510 | Content App Observer Cluster | 1 | 1 | — | — |
| 0x0550 | Zone Management Cluster | 1 | 1 | — | — |
| 0x0551 | Camera AV Stream Management Cluster | 2 | 2 | — | — |
| 0x0552 | Camera AV Settings User Level Management Cluster | 1 | 1 | — | — |
| 0x0553 | WebRTC Transport Provider Cluster | 2 | 2 | — | — |
| 0x0554 | WebRTC Transport Requestor Cluster | 2 | 2 | — | — |
| 0x0555 | Push AV Stream Transport Cluster | 2 | 2 | — | — |
| 0x0556 | Chime Cluster | 2 | 2 | — | — |
| 0x0700 | Commodity Tariff Cluster | 1 | 1 | — | — |
| 0x0750 | Ecosystem Information Cluster | 1 | 1 | — | — |
| 0x0751 | Commissioner Control Cluster | 1 | 1 | — | — |
| 0x0752 | Joint Fabric Datastore Cluster | 1 | 1 | — | — |
| 0x0753 | Joint Fabric Administrator Cluster | 1 | 1 | — | — |
| 0x0801 | TLS Certificate Management Cluster | 1 | 1 | — | — |
| 0x0802 | TLS Client Management Cluster | 1 | 1 | — | — |
| 0x0B06 | Meter Identification Cluster | 1 | 1 | — | — |
| 0x0B07 | Commodity Metering Cluster | 1 | 1 | — | — |

## Conditional requirements requiring review

A revision-only threshold counts as mandatory above its threshold at the
advertised Crystal revision. Feature and mixed conditions are left unresolved.
Crystal `requires:` is shown verbatim where a literal DSL declaration provides it.

| Cluster ID | Kind | ID | XML condition | Crystal declaration |
| --- | --- | ---: | --- | --- |
| 0x0006 | command | 0x0001 | not(feature(OFFONLY)) | declared; requires `{off_only: false}` |
| 0x0006 | command | 0x0002 | not(feature(OFFONLY)) | declared; requires `{off_only: false}` |
| 0x0006 | command | 0x0040 | feature(LT) | declared; requires `:lighting` |
| 0x0006 | command | 0x0041 | feature(LT) | declared; requires `:lighting` |
| 0x0006 | command | 0x0042 | feature(LT) | declared; requires `:lighting` |
| 0x0008 | command | 0x0008 | feature(FQ) | declared; requires `:frequency` |
| 0x001F | command | 0x0000 | feature(MNGD) | absent |
| 0x001F | event | 0x0001 | feature(EXTS) | declared; requires `:extension` |
| 0x001F | event | 0x0002 | feature(MNGD) | absent |
| 0x001F | event | 0x0003 | feature(AUX) | declared; requires `:auxiliary` |
| 0x0028 | event | 0x0003 | attribute() | declared; requires `—` |
| 0x0030 | command | 0x0006 | feature(TC) | declared; requires `:terms_and_conditions` |
| 0x0031 | command | 0x0000 | (feature(WI) or feature(TH)) | declared; requires `—` |
| 0x0031 | command | 0x0002 | feature(WI) | declared; requires `:wi_fi_network_interface` |
| 0x0031 | command | 0x0003 | feature(TH) | declared; requires `:thread_network_interface` |
| 0x0031 | command | 0x0004 | (feature(WI) or feature(TH)) | declared; requires `—` |
| 0x0031 | command | 0x0006 | (feature(WI) or feature(TH)) | declared; requires `—` |
| 0x0031 | command | 0x0008 | (feature(WI) or feature(TH)) | declared; requires `—` |
| 0x0033 | command | 0x0003 | feature(DMTEST) | declared; requires `:data_model_test` |
| 0x0034 | command | 0x0000 | feature(WTRMRK) | declared; requires `:watermarks` |
| 0x0035 | command | 0x0000 | feature(ERRCNT) | declared; requires `:error_counts` |
| 0x0036 | command | 0x0000 | feature(ERRCNT) | declared; requires `:error_counts` |
| 0x0037 | command | 0x0000 | (feature(PKTCNT) or feature(ERRCNT)) | declared; requires `[:packet_counts, :error_counts]` |
| 0x0038 | command | 0x0001 | feature(TSC) | declared; requires `:trusted_time_client` |
| 0x0038 | command | 0x0002 | feature(TZ) | declared; requires `:time_zone` |
| 0x0038 | command | 0x0004 | feature(TZ) | declared; requires `:time_zone` |
| 0x0038 | command | 0x0005 | feature(NTPC) | declared; requires `:ntp_client` |
| 0x0038 | event | 0x0000 | feature(TZ) | declared; requires `:time_zone` |
| 0x0038 | event | 0x0001 | feature(TZ) | declared; requires `:time_zone` |
| 0x0038 | event | 0x0002 | feature(TZ) | declared; requires `:time_zone` |
| 0x0038 | event | 0x0004 | feature(TSC) | declared; requires `:trusted_time_client` |
| 0x0039 | command | 0x0080 | feature(BIS) | declared; requires `:bridged_icd_support` |
| 0x0039 | event | 0x0080 | feature(BIS) | declared; requires `:bridged_icd_support` |
| 0x003B | event | 0x0000 | feature(LS) | declared; requires `:latching_switch` |
| 0x003B | event | 0x0001 | feature(MS) | declared; requires `:momentary_switch` |
| 0x003B | event | 0x0002 | feature(MSL) | declared; requires `:momentary_switch_long_press` |
| 0x003B | event | 0x0003 | feature(MSR) | declared; requires `:momentary_switch_release` |
| 0x003B | event | 0x0004 | feature(MSL) | declared; requires `:momentary_switch_long_press` |
| 0x003B | event | 0x0005 | (feature(MSM) and not(feature(AS))) | declared; requires `{momentary_switch_multi_press: true, action_switch: false}` |
| 0x003B | event | 0x0006 | feature(MSM) | declared; requires `:momentary_switch_multi_press` |
| 0x003C | command | 0x0001 | feature(BC) | declared; requires `:basic` |
| 0x0045 | event | 0x0000 | feature(CHGEVENT) | declared; requires `:change_event` |
| 0x0046 | command | 0x0000 | feature(CIP) | declared; requires `:check_in_protocol_support` |
| 0x0046 | command | 0x0002 | feature(CIP) | declared; requires `:check_in_protocol_support` |
| 0x0046 | command | 0x0003 | feature(LITS) | declared; requires `—` |
| 0x005C | event | 0x0000 | feature(SMOKE) | declared; requires `:smoke_alarm` |
| 0x005C | event | 0x0001 | feature(CO) | declared; requires `:co_alarm` |
| 0x0060 | command | 0x0000 | command() | declared; requires `—` |
| 0x0060 | command | 0x0001 | command() | declared; requires `—` |
| 0x0060 | command | 0x0003 | command() | declared; requires `—` |
| 0x0064 | command | 0x0080 | (feature(OCRIADJ) or feature(OMAJADJ) or feature(OMINADJ) or feature(UMINADJ) or feature(UMAJADJ) or feature(UCRIADJ)) | declared; requires `[:over_critical_adjustable, :over_major_adjustable, :over_minor_adjustable, :under_minor_adjustable, :under_major_adjustable, :under_critical_adjustable]` |
| 0x0065 | command | 0x0000 | otherwiseConform | declared; requires `—` |
| 0x0065 | command | 0x0001 | otherwiseConform | declared; requires `—` |
| 0x0065 | command | 0x0003 | otherwiseConform | declared; requires `—` |
| 0x0065 | command | 0x0004 | feature(LN) | declared; requires `:listener` |
| 0x0065 | command | 0x0005 | otherwiseConform | declared; requires `—` |
| 0x0065 | event | 0x0000 | otherwiseConform | declared; requires `—` |
| 0x0080 | command | 0x0000 | feature(SPRS) | declared; requires `:alarm_suppress` |
| 0x0080 | command | 0x0001 | (feature(VIS) or feature(AUD)) | declared; requires `[:visual, :audible]` |
| 0x0080 | event | 0x0000 | (feature(VIS) or feature(AUD)) | declared; requires `[:visual, :audible]` |
| 0x0080 | event | 0x0001 | feature(FAULTEV) | declared; requires `:fault_events` |
| 0x0090 | event | 0x0000 | attribute() | declared; requires `—` |
| 0x0091 | event | 0x0000 | feature(CUME) | declared; requires `:cumulative_energy` |
| 0x0091 | event | 0x0001 | feature(PERE) | declared; requires `:periodic_energy` |
| 0x0098 | command | 0x0000 | feature(PA) | declared; requires `:power_adjustment` |
| 0x0098 | command | 0x0001 | feature(PA) | declared; requires `:power_adjustment` |
| 0x0098 | command | 0x0002 | feature(STA) | declared; requires `:start_time_adjustment` |
| 0x0098 | command | 0x0003 | feature(PAU) | declared; requires `:pausable` |
| 0x0098 | command | 0x0004 | feature(PAU) | declared; requires `:pausable` |
| 0x0098 | command | 0x0005 | feature(FA) | declared; requires `:forecast_adjustment` |
| 0x0098 | command | 0x0006 | feature(CON) | declared; requires `:constraint_based_adjustment` |
| 0x0098 | command | 0x0007 | (feature(STA) or feature(FA) or feature(CON)) | declared; requires `[:start_time_adjustment, :forecast_adjustment, :constraint_based_adjustment]` |
| 0x0098 | event | 0x0000 | feature(PA) | declared; requires `:power_adjustment` |
| 0x0098 | event | 0x0001 | feature(PA) | declared; requires `:power_adjustment` |
| 0x0098 | event | 0x0002 | feature(PAU) | declared; requires `:pausable` |
| 0x0098 | event | 0x0003 | feature(PAU) | declared; requires `:pausable` |
| 0x0099 | command | 0x0003 | feature(V2X) | absent |
| 0x0099 | command | 0x0005 | feature(PREF) | declared; requires `:charging_preferences` |
| 0x0099 | command | 0x0006 | feature(PREF) | declared; requires `:charging_preferences` |
| 0x0099 | command | 0x0007 | feature(PREF) | declared; requires `:charging_preferences` |
| 0x0101 | command | 0x000B | feature(WDSCH) | declared; requires `:week_day_access_schedules` |
| 0x0101 | command | 0x000C | feature(WDSCH) | declared; requires `:week_day_access_schedules` |
| 0x0101 | command | 0x000D | feature(WDSCH) | declared; requires `:week_day_access_schedules` |
| 0x0101 | command | 0x000E | feature(YDSCH) | declared; requires `:year_day_access_schedules` |
| 0x0101 | command | 0x000F | feature(YDSCH) | declared; requires `:year_day_access_schedules` |
| 0x0101 | command | 0x0010 | feature(YDSCH) | declared; requires `:year_day_access_schedules` |
| 0x0101 | command | 0x0011 | feature(HDSCH) | declared; requires `:holiday_schedules` |
| 0x0101 | command | 0x0012 | feature(HDSCH) | declared; requires `:holiday_schedules` |
| 0x0101 | command | 0x0013 | feature(HDSCH) | declared; requires `:holiday_schedules` |
| 0x0101 | command | 0x001A | feature(USR) | declared; requires `:user` |
| 0x0101 | command | 0x001B | feature(USR) | declared; requires `:user` |
| 0x0101 | command | 0x001D | feature(USR) | declared; requires `:user` |
| 0x0101 | command | 0x0022 | feature(USR) | declared; requires `:user` |
| 0x0101 | command | 0x0024 | feature(USR) | declared; requires `:user` |
| 0x0101 | command | 0x0026 | feature(USR) | declared; requires `:user` |
| 0x0101 | command | 0x0027 | feature(UBOLT) | declared; requires `:unbolting` |
| 0x0101 | command | 0x0028 | feature(ALIRO) | declared; requires `:aliro_provisioning` |
| 0x0101 | command | 0x0029 | feature(ALIRO) | declared; requires `:aliro_provisioning` |
| 0x0101 | event | 0x0001 | feature(DPS) | declared; requires `:door_position_sensor` |
| 0x0101 | event | 0x0004 | feature(USR) | declared; requires `:user` |
| 0x0102 | command | 0x0005 | (feature(LF) and feature(PA_LF)) | declared; requires `{lift: true, position_aware_lift: true}` |
| 0x0102 | command | 0x0008 | (feature(TL) and feature(PA_TL)) | declared; requires `{tilt: true, position_aware_tilt: true}` |
| 0x0104 | command | 0x0000 | not(feature(IS)) | declared; requires `{instantaneous: false}` |
| 0x0104 | command | 0x0002 | feature(CL) | declared; requires `:calibration` |
| 0x0104 | event | 0x0001 | not(feature(IS)) | declared; requires `{instantaneous: false}` |
| 0x0104 | event | 0x0002 | feature(MO) | declared; requires `:manually_operable` |
| 0x0105 | command | 0x0001 | feature(PS) | declared; requires `:positioning` |
| 0x0201 | command | 0x0005 | feature(MSCH) | absent |
| 0x0201 | command | 0x0006 | feature(PRES) | declared; requires `:presets` |
| 0x0201 | command | 0x0007 | feature(TSUGGEST) | absent |
| 0x0201 | command | 0x0008 | feature(TSUGGEST) | absent |
| 0x0201 | event | 0x0000 | feature(TEVT) | declared; requires `:events` |
| 0x0201 | event | 0x0001 | (feature(TEVT) and not(feature(LTNE))) | declared; requires `{events: true, local_temperature_not_exposed: false}` |
| 0x0201 | event | 0x0002 | (feature(TEVT) and feature(OCC)) | declared; requires `{events: true, occupancy: true}` |
| 0x0201 | event | 0x0003 | feature(TEVT) | declared; requires `:events` |
| 0x0201 | event | 0x0004 | feature(TEVT) | declared; requires `:events` |
| 0x0201 | event | 0x0005 | (feature(TEVT) and feature(AUTO)) | declared; requires `{events: true, automode: true}` |
| 0x0201 | event | 0x0006 | (feature(TEVT) and feature(MSCH)) | absent |
| 0x0201 | event | 0x0007 | (feature(TEVT) and feature(PRES)) | declared; requires `{events: true, presets: true}` |
| 0x0202 | command | 0x0000 | feature(STEP) | declared; requires `:step` |
| 0x0300 | command | 0x0000 | feature(HS) | declared; requires `:hue_saturation` |
| 0x0300 | command | 0x0001 | feature(HS) | declared; requires `:hue_saturation` |
| 0x0300 | command | 0x0002 | feature(HS) | declared; requires `:hue_saturation` |
| 0x0300 | command | 0x0003 | feature(HS) | declared; requires `:hue_saturation` |
| 0x0300 | command | 0x0004 | feature(HS) | declared; requires `:hue_saturation` |
| 0x0300 | command | 0x0005 | feature(HS) | declared; requires `:hue_saturation` |
| 0x0300 | command | 0x0006 | feature(HS) | declared; requires `:hue_saturation` |
| 0x0300 | command | 0x0007 | feature(XY) | declared; requires `:xy` |
| 0x0300 | command | 0x0008 | feature(XY) | declared; requires `:xy` |
| 0x0300 | command | 0x0009 | feature(XY) | declared; requires `:xy` |
| 0x0300 | command | 0x000A | feature(CT) | declared; requires `:color_temperature` |
| 0x0300 | command | 0x0040 | feature(EHUE) | declared; requires `:enhanced_hue` |
| 0x0300 | command | 0x0041 | feature(EHUE) | declared; requires `:enhanced_hue` |
| 0x0300 | command | 0x0042 | feature(EHUE) | declared; requires `:enhanced_hue` |
| 0x0300 | command | 0x0043 | feature(EHUE) | declared; requires `:enhanced_hue` |
| 0x0300 | command | 0x0044 | feature(CL) | declared; requires `:color_loop` |
| 0x0300 | command | 0x0047 | (feature(HS) or feature(XY) or feature(CT)) | declared; requires `[:hue_saturation, :xy, :color_temperature]` |
| 0x0300 | command | 0x004B | feature(CT) | declared; requires `:color_temperature` |
| 0x0300 | command | 0x004C | feature(CT) | declared; requires `:color_temperature` |
| 0x0406 | event | 0x0000 | feature(OCCEVENT) | declared; requires `:occupancy_event` |
| 0x0431 | event | 0x0000 | feature(HA) | declared; requires `:human_activity` |
| 0x0431 | event | 0x0001 | feature(HA) | declared; requires `:human_activity` |
| 0x0452 | command | 0x0004 | feature(PC) | declared; requires `:pan_change` |
| 0x0504 | command | 0x0000 | (feature(CL) or feature(LI)) | declared; requires `[:channel_list, :lineup_info]` |
| 0x0504 | command | 0x0004 | feature(EG) | declared; requires `:electronic_guide` |
| 0x0504 | command | 0x0006 | (feature(RP) and feature(EG)) | declared; requires `{record_program: true, electronic_guide: true}` |
| 0x0504 | command | 0x0007 | (feature(RP) and feature(EG)) | declared; requires `{record_program: true, electronic_guide: true}` |
| 0x0506 | command | 0x0006 | feature(VS) | declared; requires `:variable_speed` |
| 0x0506 | command | 0x0007 | feature(VS) | declared; requires `:variable_speed` |
| 0x0506 | command | 0x000B | feature(AS) | declared; requires `:advanced_seek` |
| 0x0506 | command | 0x000C | feature(AT) | declared; requires `:audio_tracks` |
| 0x0506 | command | 0x000D | feature(TT) | declared; requires `:text_tracks` |
| 0x0506 | command | 0x000E | feature(TT) | declared; requires `:text_tracks` |
| 0x0507 | command | 0x0003 | feature(NU) | declared; requires `:name_updates` |
| 0x050A | command | 0x0000 | feature(CS) | declared; requires `:content_search` |
| 0x050A | command | 0x0001 | feature(UP) | declared; requires `:url_playback` |
| 0x050B | command | 0x0001 | feature(NU) | declared; requires `:name_updates` |
| 0x050F | command | 0x0000 | feature(PM) | declared; requires `:pin_management` |
| 0x050F | command | 0x0001 | feature(PM) | declared; requires `:pin_management` |
| 0x050F | command | 0x0005 | feature(ST) | absent |
| 0x050F | command | 0x0006 | feature(ST) | absent |
| 0x050F | command | 0x0007 | feature(BU) | declared; requires `:block_unrated` |
| 0x050F | command | 0x0008 | feature(BU) | declared; requires `:block_unrated` |
| 0x050F | command | 0x0009 | feature(OCR) | declared; requires `:on_demand_content_rating` |
| 0x050F | command | 0x000A | feature(SCR) | declared; requires `:scheduled_content_rating` |
| 0x050F | command | 0x000B | feature(BC) | declared; requires `:block_channels` |
| 0x050F | command | 0x000C | feature(BC) | declared; requires `:block_channels` |
| 0x050F | command | 0x000D | feature(BA) | declared; requires `:block_applications` |
| 0x050F | command | 0x000E | feature(BA) | declared; requires `:block_applications` |
| 0x050F | command | 0x000F | feature(BTW) | declared; requires `:block_content_time_window` |
| 0x050F | command | 0x0010 | feature(BTW) | declared; requires `:block_content_time_window` |
| 0x050F | event | 0x0000 | feature(ST) | absent |
| 0x050F | event | 0x0001 | feature(BTW) | declared; requires `:block_content_time_window` |
| 0x0550 | command | 0x0000 | (feature(TWODCART) and feature(USERDEFINED)) | declared; requires `{two_d_cartesian_zone: true, user_defined: true}` |
| 0x0550 | command | 0x0002 | (feature(TWODCART) and feature(USERDEFINED)) | declared; requires `{two_d_cartesian_zone: true, user_defined: true}` |
| 0x0550 | command | 0x0003 | feature(USERDEFINED) | declared; requires `:user_defined` |
| 0x0551 | command | 0x0000 | feature(ADO) | declared; requires `:audio` |
| 0x0551 | command | 0x0002 | feature(ADO) | declared; requires `:audio` |
| 0x0551 | command | 0x0003 | feature(VDO) | declared; requires `:video` |
| 0x0551 | command | 0x0005 | (feature(VDO) and (feature(WMARK) or feature(OSD))) | absent |
| 0x0551 | command | 0x0006 | feature(VDO) | declared; requires `:video` |
| 0x0551 | command | 0x0007 | feature(SNP) | declared; requires `:snapshot` |
| 0x0551 | command | 0x0009 | (feature(SNP) and (feature(WMARK) or feature(OSD))) | absent |
| 0x0551 | command | 0x000A | feature(SNP) | declared; requires `:snapshot` |
| 0x0551 | command | 0x000C | feature(SNP) | declared; requires `:snapshot` |
| 0x0552 | command | 0x0000 | (feature(MPAN) or feature(MTILT) or feature(MZOOM)) | declared; requires `:mechanical_pan` |
| 0x0552 | command | 0x0001 | (feature(MPAN) or feature(MTILT) or feature(MZOOM)) | declared; requires `:mechanical_pan` |
| 0x0552 | command | 0x0002 | feature(MPRESETS) | absent |
| 0x0552 | command | 0x0003 | feature(MPRESETS) | absent |
| 0x0552 | command | 0x0004 | feature(MPRESETS) | absent |
| 0x0552 | command | 0x0005 | feature(DPTZ) | absent |
| 0x0556 | event | 0x0000 | revision(current) >= revision(2) | declared; requires `—` |

Regenerate from official connectedhomeip `v1.6.0.0` canonical XML:

```sh
python3 scripts/protocol_command_event_coverage.py \
  --xml-root /tmp/connectedhomeip-1.6/data_model/1.6/clusters \
  --crystal-root src/matter/cluster --output docs/protocol-command-event-coverage.md
python3 -m unittest discover -s scripts -p 'test_protocol_command_event_coverage.py'
```

Only `commandToServer` commands and server events declared directly in the XML
file are compared. Response commands, inherited members, unknown XML roots,
commands without an explicit XML direction, generated Crystal declarations
outside simple same-file macros with literal arguments, and runtime feature combinations
are outside this report. Revision-only conditions use the Crystal cluster's
advertised revision; all other conditional rows require a separate conformance review.
