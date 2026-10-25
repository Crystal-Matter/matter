# Push AV Stream Transport (Matter 1.6)

`Matter::Cluster::PushAvStreamTransport` implements the revision 2 configuration
surface on cluster `0x0555`: `SupportedFormats`, fabric-sensitive
`CurrentConnections`, the six incoming commands, and the Begin/End events.
Connection records use `Storage::Record` and the device persistence backend.
The runtime wires fabric ownership and TLS endpoint references, and erases a
fabric's records when it leaves.

Install the cluster beside TLS Certificate Management and TLS Client Management.
The latter is node-scoped on endpoint 0, while Push AV may be on a camera
endpoint. See
`examples/matter_push_av_stream_transport_device.cr` for a configuration-only
fixture.

To accept allocations, the host must supply `video_stream_exists` and/or
`audio_stream_exists` callbacks for real stream IDs. If using Motion triggers,
also supply `zone_exists`. To activate a connection, set `on_status_change`
to start or stop the media transport and return success only after it is ready.
Set `on_manual_trigger` to schedule a manual upload; then call
`report_transport_begin` and `report_transport_end` when the upload actually
starts and ends, passing the real CMAF session number. The cluster does not
open TLS sockets, capture video/audio, generate CMAF segments, or upload data.
Only one reported CMAF session can be active per connection. Repeated Begin,
an End without Begin, and an End with a different session number are rejected.
The Begin reporter accepts the actual `TriggerType` so a Motion transport
started by a manual command emits `Command` with its required ActivationReason;
the existing reporter overload infers this from the supplied reason.
An accepted Inactive or deallocation closes a still-reported session and emits
End with its saved number after the host stop callback succeeds. The host may
report End from that callback; the server will not emit it twice. Session state
is transient and is cleared on restart or fabric removal. Removing a fabric
also calls the host stop callback for active connections before erasing them.
For `Command` triggers, a manual request must include `TimeControl`; `Motion`
triggers use their configured MotionTimeControl when a manual request omits it.
Set `transport_busy` to report a connection already sending; a busy request
returns the Matter `Busy` status without calling the trigger hook. The device
runtime links `privacy_allows` to Camera AV Stream Management when that cluster
is installed, including hard, livestream, and recording privacy controls.
Hosts without that cluster should set `privacy_allows` to their own policy
before enabling manual capture. A denied request returns `InvalidInState`.
The optional Metadata and PerZoneSensitivity feature bits are not enabled by
the example.

Allocation starts `Inactive`. `CurrentConnections` omits TransportOptions so
it is safe on transports without Large Message support; `FindTransport`
returns complete options and returns `NotFound` when no connection matches.
All commands require a CASE session and expose only
connections on the caller's fabric. Active status and manual triggering require
host callbacks, so the configuration-only example cannot claim successful
media transmission. Revision 1 explicit stream ID fields are accepted
alongside revision 2 multi-stream lists, and responses populate the deprecated
IDs from the first list entry. Revision 1 stream ID fields preserve absent,
explicit Null, and concrete values separately. An explicit Null asks the host
to choose an existing stream through `select_video_stream` or
`select_audio_stream`. The callback receives the fabric index and stream usage;
its selected ID is checked by the corresponding `*_stream_exists` callback,
added to the revision 2 list under the legacy name `video` or `audio`, and
returned as a concrete ID. A missing selector returns InvalidStream without
creating a connection. The cluster does not create or release camera streams
on behalf of the host. Nullable MotionZones and MotionSensitivity are also
preserved on wire and in storage. MotionZones is required for Motion triggers;
MotionSensitivity is required without PerZoneSensitivity, and explicit Null is
valid for both. An optional
`ExpiryTime` is treated as a relative TTL in seconds; the host must attest to
clock validity with `time_valid` before accepting it. The deadline is saved and
expired connections are removed after restart. Nonzero pre-roll needs a
`pre_roll_valid` host callback tied to the actual stream keyframe interval.
Restored `Active` connections become `Inactive` until the host establishes a
fresh transport.

Official chip-tool E2E currently covers commissioning, metadata, attributes,
unknown manual trigger and FindTransport commands, and restart of the empty
connection catalog.
The focused Crystal specs cover
TLV tags, command lifecycle, fabric isolation, persistence, validation, and
host event gating. A camera backend, actual media transport, nonempty
chip-tool allocation, and certification suite are still needed before claiming
full Push AV transport interoperability.
