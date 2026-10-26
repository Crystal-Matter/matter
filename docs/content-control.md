# Content Control (Matter 1.6)

`Cluster::ContentControl` implements the provisional revision 1 server at
`0x050F`. It can be added to a Basic Video Player endpoint. The mandatory
`Enabled` attribute and timed `Enable` / `Disable` commands are always present.

The current server accepts these optional feature bits:

| Feature | Bit | State and commands |
| --- | ---: | --- |
| ScreenTime | 0 | Daily and remaining seconds, AddBonusTime, SetScreenDailyTime, RemainingScreenTimeExpired event |
| PINManagement | 1 | Timed UpdatePIN and ResetPIN; reset returns a fresh six-digit PIN |
| BlockUnrated | 2 | BlockUnrated, BlockUnratedContent, UnblockUnratedContent |
| OnDemandContentRating | 3 | Ordered ratings and threshold, SetOnDemandRatingThreshold |
| ScheduledContentRating | 4 | Ordered ratings and threshold, SetScheduledContentRatingThreshold |
| BlockChannels | 5 | Indexed channels, AddBlockChannels, RemoveBlockChannels |
| BlockApplications | 6 | App identities, AddBlockApplications, RemoveBlockApplications |
| BlockContentTimeWindow | 7 | Indexed weekly windows, SetBlockContentTimeWindow, RemoveBlockContentTimeWindow, EnteringBlockContentTimeWindow event |

PIN management has no associated event. PIN changes persist as a salted one-way
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

For `ScreenTime`, set `screen_daily_time` in seconds (0 to 86400) or use
`SetScreenDailyTime`. The remaining balance starts at the daily limit, then
decreases while Content Control is enabled and the host reports active
playback through `tick_screen_time(playing)`. The host calls this at least once
per second and installs `on_policy_changed` to stop playback when the balance
reaches zero. The tick uses a monotonic clock for elapsed viewing time and a
local calendar date for daily rollover. It apportions a tick across midnight,
persists the balance and date, and keeps the current day's balance when
`SetScreenDailyTime` changes the limit; the new limit takes effect on the next
day. A backward local date does not refill spent time. `AddBonusTime` adds at
most the remaining seconds of the current calendar day and never raises the
balance above 86400. A missing local clock rejects bonus requests. The exact
midnight cutoff follows the host's local timezone, including its daylight
saving rules.

An Operate caller of `AddBonusTime` supplies the current PIN; a Manage or
Administer caller may omit it and any supplied PIN is ignored. Without
PINManagement, Operate calls fail with `InvalidPINCode` because this server has
no separate out-of-band PIN facility. The Interaction Model resolves each
caller's ACL privilege for that invocation only. Host code invoking the
cluster directly does not get Manage bypass unless it explicitly supplies
request privilege context.

For `BlockContentTimeWindow`, each indexed entry covers one or more days and
one or more same-day periods. Day masks cannot overlap across entries. The host
calls `tick_block_content_time_window` periodically to emit the entry event and
stop active playback through `on_policy_changed`; `playback_allowed?` checks
the local time on every call. A missing local time blocks playback while windows
are configured. The example polls once per second.

The cluster declares the Matter Manage privilege for configuration commands.
`Enable` and `Disable` additionally require a timed interaction. `UpdatePIN`
requires timed Manage privilege and `ResetPIN` requires timed Administer
privilege. These access checks are performed by the normal Interaction Model
dispatch path.
