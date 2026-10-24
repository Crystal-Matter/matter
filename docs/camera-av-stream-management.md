# Camera AV Stream Management audio support

`Cluster::CameraAvStreamManagement` implements the Matter 1.6 revision 2
Audio (ADO) slice of cluster `0x0551`. A host advertises its actual microphone
codec, channel, sample rate, bit depth, bandwidth, and buffer capabilities.
`AudioStreamAllocate` validates those capabilities and the bandwidth budget,
asks the host to admit the stream, and returns a monotonically advancing
`AudioStreamID`. An identical allocation reuses its ID and increments its
reference count; deallocation releases host media only when the count reaches
zero. `SetStreamPriorities` rejects changes while any stream is allocated.

The host must register `on_audio_allocate` and `on_audio_deallocate`. If no
allocation callback is installed, allocation returns `InvalidInState`. A host
may also register `on_microphone_settings_changed` to apply mute and volume,
and `on_privacy_changed` to pause or resume media delivery. Check
`stream_delivery_allowed?` before delivering samples. Soft privacy settings
are exposed only when the Privacy feature is enabled. Hard privacy is a
read-only physical state set by the host. Microphone settings, privacy modes,
stream priorities, and the next audio ID survive restart; active streams are
released at restart because host media resources must be reopened explicitly.

The [synthetic audio example](../examples/matter_camera_audio_device.cr) uses an
Aggregator endpoint to exercise the wire protocol with official chip-tool. Its
callbacks accept logical streams without producing audio. Production devices
need a microphone, encoder, transport, and hardware privacy integration before
advertising ADO. This cluster does not advertise Video (VDO), Snapshot (SNP),
speaker, image control, or storage features. Camera device type topology,
WebRTC and Push AV transports, video/snapshot negotiation, transport teardown
on privacy changes, and resource preemption across stream usages remain to be
implemented and verified with independent peers.

SQLite and PostgreSQL storage remain optional. Applications include and
explicitly require an adapter as described in [README storage](../README.md#storage).
