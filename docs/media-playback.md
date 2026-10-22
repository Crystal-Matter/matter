# Media Playback server

`Matter::Cluster::MediaPlayback` implements the Matter 1.6 revision 2 server
for cluster `0x0506`. The mandatory core exposes `CurrentState`, Play, Pause,
Stop, and typed `PlaybackResponse` status. Playback commands call `on_command`
first. Without a host callback, they return `NotAllowed` and leave state
unchanged.

Use feature flags when the host can support their corresponding operations:

| Feature | Attributes and commands |
| --- | --- |
| `AdvancedSeek` | StartTime, Duration, SampledPosition, PlaybackSpeed, SeekRangeStart/End, Seek |
| `VariableSpeed` | Rewind and FastForward |
| `TextTracks` | active and available text tracks, ActivateTextTrack, DeactivateTextTrack |
| `AudioTracks` | active and available audio tracks, ActivateAudioTrack |
| `AudioAdvance` | accepts unmuted audio while rewinding or advancing; requires VariableSpeed |

Pass `optional_commands:` for StartOver, Previous, Next, SkipForward, and
SkipBackward only when the host handles them. `Operation` carries typed
position, delta, track ID, output index, and audio-advance fields to the host.
The callback returns a `PlaybackStatus`; the cluster changes Play, Pause, and
Stop state only after `Success`. The host uses `report_state`,
`update_seek_range`, `update_audio_tracks`, and `update_text_tracks` to publish
its actual player state. Changes to any supported attribute emit the optional
`StateChanged` event; grouped host updates emit one event with the final values.

The [synthetic player](../examples/matter_media_playback_device.cr) is a wire
fixture: it advertises all five features, a 120-second media item, an English
audio track and caption track, and permits commands through its host callback.
Its Aggregator device type avoids claiming the full Basic Video Player
requirements. The [official chip-tool test](../e2e/spec/media_playback_spec.cr)
commissions it and checks the cluster through the Matter wire protocol.
