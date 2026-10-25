# Content Control (Matter 1.6)

`Cluster::ContentControl` implements the provisional revision 1 server at
`0x050F`. It can be added to a Basic Video Player endpoint. The mandatory
`Enabled` attribute and timed `Enable` / `Disable` commands are always present.

The current server accepts these optional feature bits:

| Feature | Bit | State and commands |
| --- | ---: | --- |
| PINManagement | 1 | Timed UpdatePIN and ResetPIN; reset returns a fresh six-digit PIN |
| BlockUnrated | 2 | BlockUnrated, BlockUnratedContent, UnblockUnratedContent |
| OnDemandContentRating | 3 | Ordered ratings and threshold, SetOnDemandRatingThreshold |
| ScheduledContentRating | 4 | Ordered ratings and threshold, SetScheduledContentRatingThreshold |
| BlockChannels | 5 | Indexed channels, AddBlockChannels, RemoveBlockChannels |
| BlockApplications | 6 | App identities, AddBlockApplications, RemoveBlockApplications |

`ScreenTime` and `BlockContentTimeWindow` are rejected at construction. Their
clock-driven policy, attribute, and event behavior remains unsupported. PIN
management has no associated event. PIN changes persist as a salted one-way
verifier with cluster state; only an administrator can reset and retrieve a new
PIN. Old cluster documents without PIN state start with a fresh unknown PIN,
which an administrator can replace with `ResetPIN`.

The host must supply ordered, unique rating names and a threshold from that
list when it selects a rating feature. The server validates thresholds against
those names and keeps channel
indexes unique. A BlockChannels host supplies `on_validate_channel` to decide
whether a requested channel exists. A BlockApplications host may supply
`on_identify_application` to reject unknown applications.

Content Control does not play media itself. Before starting playback, the media
host calls `playback_allowed?` with its rating, scheduled/on-demand kind,
channel, and application identity. It installs `on_policy_changed` to check
playing content again after a policy change and stop any newly blocked item.
`examples/matter_content_control_device.cr` demonstrates this contract with
an unrated synthetic program and the Media Playback cluster. Configuration
persists through the device's selected `Storage::Document` backend.

The cluster declares the Matter Manage privilege for configuration commands.
`Enable` and `Disable` additionally require a timed interaction. `UpdatePIN`
requires timed Manage privilege and `ResetPIN` requires timed Administer
privilege. These access checks are performed by the normal Interaction Model
dispatch path.
