# Matter 1.6 Camera composition and device-to-device E2E plan

This branch integrates the separate AV Audio, Video, Snapshot, WebRTC Provider,
and WebRTC Requestor client slices. `CameraComposition.validate` is a structural
inventory only. Do not advertise Camera device type `0x0142` until the conditions
below are implemented and the E2E scenario passes with an independent peer.

## Required composition

- Camera endpoint: Descriptor server; Camera AV Stream Management `0x0551`
  server with ADO, VDO, and SNP features; WebRTC Transport Provider `0x0553`
  server; WebRTC Transport Requestor `0x0554` client in Descriptor.ClientList.
- Root endpoint: Power Source device type and `0x002F` server; Time
  Synchronization `0x0038` server with TimeZone, NTPClient, and TimeSyncClient
  features plus `0x0038` client; TLS Certificate Management `0x0801` server;
  TLS Client Management `0x0802` server. These are mandatory Root Node
  conditions in Matter 1.6 Camera.xml. The existing Time Synchronization
  implementation supports TimeZone only; NTPClient/TimeSyncClient behavior must
  be implemented before this gate can pass.
- Host media callbacks must allocate real audio, video, and snapshot resources;
  the Provider peer must exchange actual SDP and ICE with an independent
  Requestor server. The current synthetic Aggregator fixtures and stub media
  peers establish wire shape, not a functioning Camera media path.

## E2E scenario

1. Commission a Camera candidate and an independent Requestor peer onto one
   fabric with official `chip-tool`; repeat with a second fabric for isolation.
   Assert Camera endpoint DeviceTypeList revision 1, ServerList `0x0551` and
   `0x0553`, ClientList `0x0554`, all three AV feature bits, and the Root Node
   composition above. Fail before advertising `0x0142` if any check fails.
2. Exercise SolicitOffer/ProvideOffer on the Camera Provider. Have the host
   route the resulting session through the outbound Requestor client to the
   peer Requestor server over authenticated CASE. Exchange Answer and ICE
   candidates both ways, and confirm an actual media track/decoded frame (and
   microphone path where configured). Use Matter TCP for SDP/ICE payloads too
   large for UDP.
3. End the session from each side. Verify Provider and Requestor
   CurrentSessions return to empty on the accessing fabric and that AV stream
   reference counts and host encoder/microphone resources are released.
4. Repeat the flow on a second fabric. Attempt to reuse a session ID or peer
   binding from the first fabric; require rejection without altering either
   fabric's session state. Test privacy switch and resource exhaustion while a
   session is live and check both peers receive teardown.
5. Restart the Camera during negotiation and during an active session. Assert
   no orphaned stream allocations or stale CurrentSessions, and that the
   independent peer receives/observes termination. Re-read Descriptor and
   mandatory root attributes after restart.

The E2E fixture requires a real Requestor server, a Camera host adapter that
connects Provider callbacks to Requestor client signaling, and working
NTPClient/TimeSyncClient behavior. None is supplied by this integration branch.
