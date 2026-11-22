# WebRTC Requestor server integration

`Cluster::WebRtcTransportRequestor` implements the Matter 1.6 revision 2
signaling endpoint. Add it to a controller endpoint with a `Peer` implementation
that passes Offer, Answer, ICECandidates, and End to a real WebRTC engine.
The cluster does not negotiate SDP or create media streams.

The controller must first issue SolicitOffer or ProvideOffer to a WebRTC
Transport Provider. When that Provider returns its session ID and stream IDs,
the host calls `upsert_session` with the Provider's Node ID, endpoint, fabric
index, and returned session ID. Register before the Provider can invoke Offer
or Answer on the Requestor. The server rejects commands whose authenticated
CASE fabric, peer Node ID, and session ID do not match a registered tuple.
The host should call `remove_session` on local cancellation or establishment
timeout. Fabric removal also clears its sessions. The application must grant
the Provider suitable ACL access to the Requestor endpoint.

An `ICECandidates` command may contain a `Candidate` value of `""` to signal
the end of candidates for an ICE generation. Matter 1.6 requires the candidate
field but does not give it a minimum length; only a non-null `SDPMid` must have
at least one character. The host should forward this marker to its WebRTC
engine, as described by the [W3C WebRTC end-of-candidates
indication](https://www.w3.org/TR/webrtc/#dom-peerconnection-addicecandidate).

On End, the cluster passes the reason to the host, removes the tracked session,
and returns the host's status. This matches the official SDK's
`WebRTCTransportRequestorCluster::HandleEnd` and matter.js's Requestor server:
the Provider has ended the protocol session even if local media cleanup fails.
The host is responsible for retrying any media cleanup that failed.

`DeviceType.camera_controller` declares Matter 1.6 Camera Controller `0x0147`
revision 1: this endpoint must serve WebRTC Transport Requestor and list
WebRTC Transport Provider as a client in Descriptor.ClientList. The synthetic
Camera Controller fixture registers a logical test session on commissioning
so official chip-tool can verify that topology and exercise the wire commands.
Its Peer returns `InvalidInState` and supplies no SDP or media. It does not
exercise Provider solicitation, Provider-issued session IDs, or WebRTC
negotiation; a production controller needs a host WebRTC engine and session
lifecycle integration.
