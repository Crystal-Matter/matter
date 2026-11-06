# Commodity Tariff (Matter 1.6)

`Cluster::CommodityTariff` implements revision 1 of cluster `0x0700` with the
Pricing feature and opt-in FriendlyCredit, PeakPeriod, and AuxiliaryLoad profiles. A host publishes
a validated calendar with `publish`, then
calls `refresh_at` with Matter epoch seconds as its clock advances. The server
exposes all mandatory base attributes, including current and next day/entry
projections, and answers `GetTariffComponent` and `GetDayEntry` at Operate
privilege. A published calendar persists across restart; active projections
are rebuilt from the current clock.

The calendar accepts day entries, weekday patterns, dated calendar periods,
individual day overlays, price components, and tariff periods. Publication
checks size limits, unique IDs, references, weekday coverage, sorted dates,
entry order, price values, and label lengths before changing visible state.
Rotating day patterns are selected in `DayPatternIDs` order, starting at each
calendar period's first UTC day. When the first period starts immediately,
the publication day anchors its rotation and persists across restart. An absent
tariff exposes null metadata and empty component and period lists. Call
`clear_tariff` when the provider withdraws a publication.

The schedule projection uses UTC dates. Providers whose tariff follows a local
time zone must convert their timetable before publishing or supply a host
scheduler that refreshes at the appropriate transitions. Randomized day
entries are not supported. The FriendlyCredit profile carries an optional
boolean in each tariff component: `true` marks entry to a friendly credit
period and `false` marks exit. Current and next component projections, lookup
responses, and restored publications preserve that value. Pricing-only servers
reject components with a FriendlyCredit value. The host publishes the schedule;
a meter or application owns credit accounting and supply control.
The PeakPeriod profile carries an optional `PeakPeriod` structure in each
component, with `severity` (`Unused`, `Low`, `Medium`, `High`) and a positive
`period` number. Current and next projections, lookup responses, and restored
publications preserve it. Components reporting only a peak period may omit
Price. The profile is available with or without FriendlyCredit, alongside
Pricing; unadvertised fields are rejected. A component with a Price field must
carry a price or price level. The AuxiliaryLoad profile carries one optional
`AuxiliaryLoadSwitchSettings` value per component: an unsigned switch `number`
and a `required_state` of `Off`, `On`, or `None`. A switch-only component may
omit Price. Current and next projections, lookup responses, and restored
publications preserve the setting. The tariff host publishes the desired state;
physical switch control belongs to the host or another application. Power
Threshold and Randomization feature bits are not advertised.
The lookup commands retain only the current published tariff, so historical
IDs from superseded tariffs are not available.

`examples/matter_commodity_tariff_device.cr` publishes a synthetic daily
Pricing tariff and separate FriendlyCredit, PeakPeriod, and AuxiliaryLoad profiles on Aggregator
endpoints. The official chip-tool E2E exercises all profiles and host-driven
transitions.
