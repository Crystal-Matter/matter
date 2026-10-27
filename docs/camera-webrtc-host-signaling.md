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
when the Requestor peer has installed its session. A Provider `Peer` callback
may call `provider.defer_signaling(session) { sink.offer(session, sdp) }` (or
`answer` / `ice_candidates`) while handling a CASE command. Check the returned
Boolean and fail the command if it is false. The protocol dispatches the task
after the final encrypted InvokeResponse chunk is transmitted; send failure,
chunk rejection, timeout, session removal, and fabric removal drop it. A task
that resolves to a different CASE fabric or peer fails closed and ends only its
matching Provider session. A media Peer must release its host resources when
Provider invokes `end_session`.

The Matter SDK's Linux Camera example uses libdatachannel plus GStreamer for
the actual media layer. This repository does not yet include that backend or
decoded-frame interoperability proof, so no example advertises Camera device
type `0x0142`.
