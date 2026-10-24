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
The optional Metadata and PerZoneSensitivity feature bits are not enabled by
the example.

Allocation starts `Inactive`. `CurrentConnections` omits TransportOptions so
it is safe on transports without Large Message support; `FindTransport`
returns complete options. All commands require a CASE session and expose only
connections on the caller's fabric. Active status and manual triggering require
host callbacks, so the configuration-only example cannot claim successful
media transmission. Revision 1 explicit stream ID fields are accepted
alongside revision 2 multi-stream lists, and responses populate the deprecated
IDs from the first list entry. Revision 1 null stream IDs that request automatic
assignment still need a real camera stream allocator. An optional
`ExpiryTime` is treated as a relative TTL in seconds; the host must attest to
clock validity with `time_valid` before accepting it. The deadline is saved and
expired connections are removed after restart. Nonzero pre-roll needs a
`pre_roll_valid` host callback tied to the actual stream keyframe interval.
Restored `Active` connections become `Inactive` until the host establishes a
fresh transport.

Official chip-tool E2E currently covers commissioning, metadata, attributes,
and restart of the empty connection catalog. The focused Crystal specs cover
TLV tags, command lifecycle, fabric isolation, persistence, validation, and
host event gating. A camera backend, actual media transport, nonempty
chip-tool allocation, and certification suite are still needed before claiming
full Push AV transport interoperability.
Motion trigger encoding with an explicit nullable `MotionZones` or
`MotionSensitivity` value also needs conditional TLV presence support; the
current serializer omits nil option fields. Motion deployments should use
concrete values and verify their controller's expectations.
