require "../spec_helper"

private alias Tariff = Matter::Cluster::CommodityTariff
private alias IMCode = Matter::InteractionModel::StatusCode

private def tariff_fixture
  build(Tariff)
end

private def tariff_publication
  info = Tariff::TariffInformation.new("Home", "Supplier", Tariff::Currency.new(36_u16, 2_u8), Tariff::BlockMode::NoBlock)
  entries = [Tariff::DayEntry.new(10_u32, 0_u16), Tariff::DayEntry.new(11_u32, 720_u16)]
  pattern = Tariff::DayPattern.new(20_u32, 0x7F_u8, [10_u32, 11_u32])
  calendar = Tariff::CalendarPeriod.new(0_u32, [20_u32])
  prices = [
    Tariff::TariffComponent.new(30_u32, Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 20_i64), nil),
    Tariff::TariffComponent.new(31_u32, Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil),
  ]
  periods = [
    Tariff::TariffPeriod.new("Off peak", [10_u32], [30_u32]),
    Tariff::TariffPeriod.new("Peak", [11_u32], [31_u32]),
  ]
  Tariff::Publication.new(info, Tariff::TariffUnit::KWh, 0_u32,
    entries, [pattern], [calendar], [] of Tariff::Day,
    prices, periods)
end

describe Tariff do
  it "declares revision-one mandatory attributes and operate-level lookup commands" do
    cluster = tariff_fixture
    cluster.cluster_id.id.should eq(0x0700_u32)
    cluster.cluster_revision.should eq(1_u16)
    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq(1_u32)
    (0_u16..0x10_u16).each { |id| attribute_ids(cluster).should contain(id) }
    accepted_command_ids(cluster).should eq([Tariff::CMD_GET_TARIFF_COMPONENT, Tariff::CMD_GET_DAY_ENTRY])
    accepted_command_ids(cluster).each do |id|
      cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    end
    read_tlv(cluster, Tariff::ATTR_TARIFF_INFO).value.should be_nil
    read_tlv(cluster, Tariff::ATTR_TARIFF_COMPONENTS).value.as(Array(TLV::Any)).should be_empty
    read_tlv(cluster, Tariff::ATTR_TARIFF_PERIODS).value.as(Array(TLV::Any)).should be_empty
  end

  it "publishes a validated price calendar, projects active entries, and restores it" do
    cluster = tariff_fixture
    publication = tariff_publication
    cluster.publish(publication, at: 100_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.price.as(Tariff::TariffPrice).price.should eq(20_i64)
    cluster.next_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(11_u32)
    cluster.current_day_entry_date.should eq(0_u32)
    cluster.next_day_entry_date.should eq(43_200_u32)
    cluster.refresh_at(43_200_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(11_u32)
    cluster.current_day_entry_date.should eq(43_200_u32)
    restored = tariff_fixture
    restored.restore_state(cluster.save_state)
    restored.refresh_at(43_200_u32)
    restored.tariff_info.as(Tariff::TariffInformation).tariff_label.should eq("Home")
    restored.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(11_u32)
  end

  it "returns the canonical component and day entry responses" do
    cluster = tariff_fixture
    cluster.publish(tariff_publication, at: 100_u32)
    component_result = invoke(cluster, Tariff::CMD_GET_TARIFF_COMPONENT,
      Tariff::GetTariffComponentRequest.new(30_u32)).as(Matter::Cluster::CommandResponse)
    component_result.command_id.should eq(Tariff::CMD_GET_TARIFF_COMPONENT_RESPONSE)
    component = Tariff::GetTariffComponentResponse.from_tlv(component_result.response.as(TLV::Any))
    component.label.should eq("Off peak")
    component.day_entry_ids.should eq([10_u32])
    component.tariff_component.tariff_component_id.should eq(30_u32)
    day_result = invoke(cluster, Tariff::CMD_GET_DAY_ENTRY,
      Tariff::GetDayEntryRequest.new(11_u32)).as(Matter::Cluster::CommandResponse)
    day_result.command_id.should eq(Tariff::CMD_GET_DAY_ENTRY_RESPONSE)
    Tariff::GetDayEntryResponse.from_tlv(day_result.response.as(TLV::Any)).day_entry.day_entry_id.should eq(11_u32)
    expect_status(invoke(cluster, Tariff::CMD_GET_DAY_ENTRY,
      Tariff::GetDayEntryRequest.new(99_u32)), IMCode::NotFound)
  end

  it "keeps publication and response arrays isolated from callers" do
    cluster = tariff_fixture
    pattern_ids = [10_u32, 11_u32]
    calendar_ids = [20_u32]
    day_ids = [10_u32]
    component_ids = [30_u32]
    pattern = Tariff::DayPattern.new(20_u32, 0x7F_u8, pattern_ids)
    calendar = Tariff::CalendarPeriod.new(0_u32, calendar_ids)
    day = Tariff::Day.new(0_u32, Tariff::DayType::Standard, day_ids)
    period = Tariff::TariffPeriod.new("Off peak", day_ids, component_ids)
    publication = tariff_publication
    mutable_patterns = [pattern]
    mutable_calendar = [calendar]
    mutable_days = [day]
    mutable_periods = [period]
    cluster.publish(Tariff::Publication.new(publication.info, publication.unit,
      publication.start_date, publication.day_entries, mutable_patterns,
      mutable_calendar, mutable_days, publication.components.first(1), mutable_periods), at: 100_u32)
    pattern_ids.clear
    calendar_ids.clear
    day_ids.clear
    component_ids.clear
    mutable_patterns.clear
    mutable_calendar.clear
    mutable_days.clear
    mutable_periods.clear

    cluster.day_patterns.as(Array(Tariff::DayPattern)).first.day_entry_ids.should eq([10_u32, 11_u32])
    cluster.calendar_periods.as(Array(Tariff::CalendarPeriod)).first.day_pattern_ids.should eq([20_u32])
    cluster.individual_days.as(Array(Tariff::Day)).first.day_entry_ids.should eq([10_u32])
    cluster.tariff_periods.as(Array(Tariff::TariffPeriod)).first.tariff_component_ids.should eq([30_u32])

    exposed = cluster.tariff_periods.as(Array(Tariff::TariffPeriod))
    exposed.clear
    nested = cluster.day_patterns.as(Array(Tariff::DayPattern)).first.day_entry_ids
    nested.clear
    cluster.tariff_periods.as(Array(Tariff::TariffPeriod)).size.should eq(1)
    cluster.day_patterns.as(Array(Tariff::DayPattern)).first.day_entry_ids.should eq([10_u32, 11_u32])

    response = cluster.get_tariff_component(Tariff::GetTariffComponentRequest.new(30_u32))
      .as(Tariff::GetTariffComponentResponse)
    response.day_entry_ids.clear
    response.day_entry_ids.should eq([10_u32])
    cluster.get_tariff_component(Tariff::GetTariffComponentRequest.new(30_u32))
      .as(Tariff::GetTariffComponentResponse).day_entry_ids.should eq([10_u32])
    cluster.current_day.as(Tariff::Day).day_entry_ids.should eq([10_u32])
  end

  it "rejects dangling references without changing published state" do
    cluster = tariff_fixture
    valid = tariff_publication
    cluster.publish(valid, at: 100_u32)
    bad = Tariff::Publication.new(valid.info, valid.unit, valid.start_date,
      valid.day_entries, valid.day_patterns, valid.calendar_periods,
      valid.individual_days, valid.components,
      [Tariff::TariffPeriod.new("Bad", [99_u32], [30_u32])])
    expect_raises(ArgumentError) { cluster.publish(bad, at: 100_u32) }
    cluster.tariff_periods.as(Array(Tariff::TariffPeriod)).size.should eq(2)
  end

  it "rejects a day entry assigned to multiple tariff periods" do
    cluster = tariff_fixture
    publication = tariff_publication
    components = (100_u32..120_u32).map do |id|
      Tariff::TariffComponent.new(id,
        Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 20_i64), nil)
    end
    periods = [
      Tariff::TariffPeriod.new("First", [10_u32], (100_u32..119_u32).to_a),
      Tariff::TariffPeriod.new("Second", [10_u32], [120_u32]),
    ]
    overloaded = Tariff::Publication.new(publication.info, publication.unit,
      publication.start_date, publication.day_entries, publication.day_patterns,
      publication.calendar_periods, publication.individual_days, components, periods)
    expect_raises(ArgumentError, /day entry belongs to multiple tariff periods/) do
      cluster.publish(overloaded, at: 100_u32)
    end
    cluster.tariff_info.should be_nil
  end

  it "expires a duration-limited event day entry" do
    cluster = tariff_fixture
    publication = tariff_publication
    event_entry = Tariff::DayEntry.new(12_u32, 30_u16, 60_u16)
    event_day = Tariff::Day.new(0_u32, Tariff::DayType::Event, [12_u32])
    event_period = Tariff::TariffPeriod.new("Event", [12_u32], [30_u32])
    with_event = Tariff::Publication.new(publication.info, publication.unit,
      publication.start_date, publication.day_entries + [event_entry],
      publication.day_patterns, publication.calendar_periods, [event_day],
      publication.components, publication.tariff_periods + [event_period])
    cluster.publish(with_event, at: 1_800_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(12_u32)
    cluster.refresh_at(5_400_u32)
    cluster.current_day_entry.should be_nil
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).should be_empty
    cluster.next_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
  end

  it "rejects overlapping duration-limited event entries" do
    cluster = tariff_fixture
    publication = tariff_publication
    event_entries = [
      Tariff::DayEntry.new(12_u32, 30_u16, 60_u16),
      Tariff::DayEntry.new(13_u32, 60_u16),
    ]
    event_day = Tariff::Day.new(0_u32, Tariff::DayType::Event, [12_u32, 13_u32])
    event_period = Tariff::TariffPeriod.new("Event", [12_u32, 13_u32], [30_u32])
    overlapping = Tariff::Publication.new(publication.info, publication.unit,
      publication.start_date, publication.day_entries + event_entries,
      publication.day_patterns, publication.calendar_periods, [event_day],
      publication.components, publication.tariff_periods + [event_period])
    expect_raises(ArgumentError, /event day entries overlap/) { cluster.publish(overlapping, at: 1_800_u32) }
    cluster.tariff_info.should be_nil
  end

  it "keeps a future tariff inactive, then clears it durably" do
    cluster = tariff_fixture
    valid = tariff_publication
    future = Tariff::Publication.new(valid.info, valid.unit, 86_400_u32,
      valid.day_entries, valid.day_patterns,
      [Tariff::CalendarPeriod.new(86_400_u32, [20_u32])],
      valid.individual_days, valid.components, valid.tariff_periods)
    cluster.publish(future, at: 100_u32)
    cluster.current_day.should be_nil
    cluster.refresh_at(86_500_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
    cluster.clear_tariff
    cluster.tariff_info.should be_nil
    cluster.current_day_entry.should be_nil
    cluster.tariff_components.as(Array(Tariff::TariffComponent)).should be_empty
    cluster.tariff_periods.as(Array(Tariff::TariffPeriod)).should be_empty
    read_tlv(cluster, Tariff::ATTR_TARIFF_COMPONENTS).value.as(Array(TLV::Any)).should be_empty
    read_tlv(cluster, Tariff::ATTR_TARIFF_PERIODS).value.as(Array(TLV::Any)).should be_empty
    restored = tariff_fixture
    restored.restore_state(cluster.save_state)
    restored.tariff_info.should be_nil
  end
end
