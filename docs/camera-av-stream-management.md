# Camera AV Stream Management audio and video support

`Cluster::CameraAvStreamManagement` implements the Matter 1.6 revision 2
Audio (ADO) and Video (VDO) slices of cluster `0x0551`. A host advertises its actual microphone
codec, channel, sample rate, bit depth, bandwidth, and buffer capabilities.
`AudioStreamAllocate` validates those capabilities and the bandwidth budget,
asks the host to admit the stream, and returns a monotonically advancing
`AudioStreamID`. An identical allocation reuses its ID and increments its
reference count; deallocation releases host media only when the count reaches
zero. `SetStreamPriorities` rejects changes while any stream is allocated.

For VDO, the host advertises sensor size and frame rate, viewport minimum,
codec/rate distortion points, encoder count and encoded pixel rate. The
mandatory `Viewport` attribute is writable with Manage privilege, bounded by
the sensor and minimum viewport resolution, and persists across restart. The
host reports its current video frame rate through `current_frame_rate=`.
`VideoStreamAllocate` checks these limits and the shared network bandwidth
budget, then invokes `on_video_allocate`. Exact duplicate allocations share
an ID and a reference count. `VideoStreamDeallocate` invokes
`on_video_deallocate` when the last reference is released. A VDO-only endpoint
does not need microphone capabilities. VDO does not enable watermark, OSD,
snapshot, or image-control commands.

The host must register `on_audio_allocate` and `on_audio_deallocate` when ADO
is enabled, and the corresponding `on_video_allocate` and
`on_video_deallocate` callbacks when VDO is enabled. If no
allocation callback is installed, allocation returns `InvalidInState`. A host
may also register `on_microphone_settings_changed` to apply mute and volume,
and `on_privacy_changed` to pause or resume media delivery. Check `stream_delivery_allowed?` before delivering audio and
`video_delivery_allowed?` before delivering video. Video privacy does not
depend on microphone mute. Soft privacy settings
are exposed only when the Privacy feature is enabled. Hard privacy is a
read-only physical state set by the host. Microphone settings, privacy modes,
stream priorities, and the next audio/video IDs survive restart; active ADO/VDO
streams are released at restart because host media resources must be reopened
explicitly. SNP allocations are retained and require host callback rebinding.

The [synthetic audio example](../examples/matter_camera_audio_device.cr) and
[synthetic video example](../examples/matter_camera_video_device.cr) use
Aggregator endpoints for official chip-tool wire checks. Their callbacks accept
logical streams without producing media. Production devices need actual sensors,
encoders, transports, and hardware privacy integration before advertising ADO
or VDO. Camera device type topology, WebRTC and Push AV media delivery, snapshot
negotiation, transport teardown on privacy changes, and resource preemption
across stream usages remain separate gaps requiring independent peer tests.

SQLite and PostgreSQL storage remain optional. Applications include and
explicitly require an adapter as described in [README storage](../README.md#storage).

## Snapshot slice

SNP exposes fixed snapshot codec/resolution/frame-rate capabilities, an allocated
stream list, and typed allocation, deallocation and explicit-ID capture commands.
The host admits and releases snapshot streams and supplies image bytes through
`on_snapshot_capture`; Crystal does not manufacture camera images. Identical
allocations share an ID and reference count. Snapshot streams share the encoded
pixel-rate and hardware-encoder budgets with video. The response is bounded by
`MaxContentBufferSize` and 65,000 bytes, and capture is denied while hard or
soft livestream privacy is active. Allocations and the next ID persist; hosts
must rebind callbacks after restart before capture or release can proceed.

The synthetic [snapshot example](../examples/matter_camera_snapshot_device.cr)
uses an Aggregator endpoint and a checked-in, decodable 320x240 JPEG for Matter
wire checks. Its fixed payload is not a live camera source or a claim of media delivery. The
mandatory nullable `CaptureSnapshot.SnapshotStreamID` field accepts explicit IDs
and TLV Null auto-selection through TLV FieldState; an omitted field is rejected.
The optional WMARK/OSD modify command and Camera device type topology remain
unimplemented. Applications should not present this slice as complete Camera
conformance.

Applications with a decoded RGB24 camera source can explicitly require
`matter/media/ffmpeg_jpeg_encoder` and use `Media::DecodedRgbFrame` with
`Media::FfmpegJpegEncoder` in `on_snapshot_capture`. This optional adapter runs
an installed FFmpeg executable to encode an actual JPEG from the supplied
pixels. Frames must be tightly packed RGB24 with exactly three bytes per pixel,
nonzero dimensions, and at most 8,294,400 pixels. Quality is 1 through 100.
The focused media test decodes the JPEG and checks its dimensions and
pixel regions, then passes it through `CaptureSnapshot`. Applications still
own sensor capture, privacy enforcement at the source, and host resource
admission. Neither this adapter nor the synthetic fixture advertises Camera
device type `0x0142` or proves a WebRTC media track.
