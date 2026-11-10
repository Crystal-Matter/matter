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
queued by a peer callback that rejects its command is also dropped; a new
Invoke on the same exchange abandons the preceding chunk ladder before it
runs the new command.

The Provider releases its request lock before notifying subscribers or calling
the host `end_session` callback after outbound signaling failure. An outbound
task that resolves to a different CASE fabric or peer fails closed and ends only its
matching Provider session. A media Peer must release its host resources when
Provider invokes `end_session`.

The Matter SDK's Linux Camera example uses libdatachannel plus GStreamer for
the actual media layer. The optional
[`matter_camera_media_interop_device.cr`](../examples/matter_camera_media_interop_device.cr)
test fixture instead connects the host `Peer` to an external aiortc process.
It sends synthetic H.264 video and Opus audio tracks for a combined VDO+ADO
LiveView session. A separate Matter.js Camera
Controller commissions the Crystal Camera over CASE, receives its Offer on the
Requestor endpoint, and passes the SDP to Chrome. The dedicated GitHub Actions
job checks that Chrome decodes at least two 320×180 frames and nonzero Opus
audio energy after receiving audio RTP, then that Matter
End closes the host peer and media delivery stops. A second VDO-only LiveView session
also decodes frames before the fixture enables software livestream privacy;
the test checks that the Matter.js Requestor receives a PrivacyMode End, the
host peer closes, and frame delivery stops. This proves the protocol signaling
can carry a real ICE/DTLS/SRTP media session to an independent peer and end it
when software privacy disables LiveView.

The Python media engine is a test dependency, not a dependency of the Crystal
library. The fixture does not exercise a physical sensor, production encoder,
microphone, Push AV upload, privacy hardware, or the official SDK Camera
Controller. Applications remain responsible for their media engine and for
admitting each stream against actual host resources.
