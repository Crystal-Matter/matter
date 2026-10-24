# Commodity Tariff (Matter 1.6)

`Cluster::CommodityTariff` implements revision 1 of cluster `0x0700` with the
Pricing feature. A host publishes a validated calendar with `publish`, then
calls `refresh_at` with Matter epoch seconds as its clock advances. The server
exposes all mandatory base attributes, including current and next day/entry
projections, and answers `GetTariffComponent` and `GetDayEntry` at Operate
privilege. A published calendar persists across restart; active projections
are rebuilt from the current clock.

The calendar accepts day entries, weekday patterns, dated calendar periods,
individual day overlays, price components, and tariff periods. Publication
checks size limits, unique IDs, references, weekday coverage, sorted dates,
entry order, price values, and label lengths before changing visible state.
An absent tariff exposes null metadata and empty component and period lists. Call
`clear_tariff` when the provider withdraws a publication.

The schedule projection uses UTC dates. Providers whose tariff follows a local
time zone must convert their timetable before publishing or supply a host
scheduler that refreshes at the appropriate transitions. Rotating day
patterns and randomized day entries are not supported. Friendly Credit,
Auxiliary Load, Peak Period, Power Threshold, and Randomization feature bits
are not advertised. Price components must carry a price or price level.
The lookup commands retain only the current published tariff, so historical
IDs from superseded tariffs are not available.

`examples/matter_commodity_tariff_device.cr` publishes a synthetic daily
tariff on an Aggregator endpoint and is exercised with official chip-tool.
