# Camera WebRTC host signaling

`require "matter/camera"` loads the optional `Matter::Camera::RequestorSignalingSink`.
It sends the Camera Provider session's Offer, Answer, ICE candidates, and End
commands to the peer's WebRTC Requestor server (`0x0554`) through
`Controller::WebrtcRequestorClient`. The host supplies a resolver returning an
authenticated CASE `SecureContext` and network address for the session's
fabric and peer Node ID. The sink verifies that identity again before Invoke.

Construct the sink with the Provider cluster, a Requestor client, and a
resolver. A failed resolver or outbound command raises to the host and calls
`Provider#end_host_session` for only that fabric, peer, and session ID. The
host should release the corresponding media resources in its Provider `Peer`
`end_session` callback. ICE send failure uses `IceFailed`; other signaling
failures use `UnknownReason`. The Provider API is idempotent for a session that
has already ended, such as after privacy or fabric removal.

The media host still creates SDP and ICE, owns audio/video tracks, and decides
when the Requestor peer has installed its session. The sink does not dispatch
automatically from Provider command handlers: doing so before the Provider
response reaches the peer can race Requestor session registration. A production
adapter needs a response-sent hook and a real WebRTC backend. The Matter SDK's
Linux Camera example uses libdatachannel plus GStreamer for this layer. This
repository does not yet include that backend or decoded-frame interoperability
proof, so no example advertises Camera device type `0x0142`.
