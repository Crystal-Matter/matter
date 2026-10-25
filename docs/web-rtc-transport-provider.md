# WebRTC Provider signaling

`Cluster::WebRtcTransportProvider` is an opt-in Matter 1.6 revision 2 signaling
server for an endpoint that also has `CameraAvStreamManagement`. It declares the
mandatory `CurrentSessions` attribute and five server commands
(`SolicitOffer`, `ProvideOffer`, `ProvideAnswer`, `ProvideICECandidates`, and
`EndSession`). Session IDs advance through 0–65534 and remain unique among
active sessions. Sessions are keyed by authenticated CASE fabric and peer node;
reads are fabric filtered, and another peer receives `NotFound` for a session
it does not own. Incomplete offer/answer exchanges expire after 30 seconds.
`ProvideOffer.WebRTCSessionID` and both nullable ICE candidate fields are
mandatory on the wire: callers send TLV Null when unknown, not an absent tag.
When a legacy `VideoStreamID` or `AudioStreamID` field is present in
`SolicitOffer` or `ProvideOffer`, the matching response includes that field.
The provider preserves an explicit TLV Null separately from an omitted field;
the multi-stream lists remain the preferred revision 2 form.

The constructor requires the same-endpoint camera stream cluster and a `Peer`
implementation. A host supplies RFC 9429 SDP negotiation, ICE gathering,
candidate exchange, media delivery, and outbound commands to a Requestor. The
host must send its generated Offer or Answer to the session's
`peer_endpoint_id`, `peer_node_id`, and `fabric_index`. The `Peer` callback
methods run synchronously while the incoming command is handled; return a
non-success Interaction Model status if a media action fails. The cluster will
not invent an SDP answer or candidates. `SolicitOffer` reports a deferred
offer; the host must send the actual Offer within 30 seconds.

This slice accepts already allocated audio streams and checks stream usage,
same-endpoint allocation, hard/soft privacy, and microphone mute before
admitting or advancing a session. Privacy or final audio release ends affected
sessions immediately, and fabric removal ends its sessions. All active
sessions are volatile across restart. The camera's original host privacy and
microphone callbacks remain exclusive; the provider uses independent delivery
observers so it does not replace them.

The [signaling fixture](../examples/matter_webrtc_signaling_device.cr) and its
chip-tool E2E exercise only Matter command and TLV exchange. Its `RecordingPeer`
does **not** establish a WebRTC connection, validate SDP, gather ICE candidates,
or carry audio. Applications must bind a real WebRTC engine before advertising
this cluster as a media capability. This Provider slice does not yet implement
automatic stream assignment, metadata, or secure STUN/TURN CA lookup. The
Requestor and Push AV clusters are separate components. TCP can carry
large SDP through the opt-in `TcpEnabledTransport`; UDP retains its small
Interaction Model payload budget.
