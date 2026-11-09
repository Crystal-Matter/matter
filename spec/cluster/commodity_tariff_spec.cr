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
  it "projects RNDM day entries on second boundaries with persisted defaults" do
    cluster = build(Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::Randomization)
    baseline = tariff_publication
    entries = [
      Tariff::DayEntry.new(10_u32, 0_u16, randomization_offset: 0_i16,
        randomization_type: Tariff::DayEntryRandomizationType::None),
      Tariff::DayEntry.new(11_u32, 1_u16),
    ]
    publication = Tariff::Publication.new(baseline.info, baseline.unit,
      baseline.start_date, entries, baseline.day_patterns,
      baseline.calendar_periods, baseline.individual_days,
      baseline.components, baseline.tariff_periods,
      default_randomization_offset: 20_i16,
      default_randomization_type: Tariff::DayEntryRandomizationType::Fixed)
    cluster.publish(publication, at: 79_u32)

    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq((Tariff::Feature::Pricing | Tariff::Feature::Randomization).value)
    read_tlv(cluster, Tariff::ATTR_DEFAULT_RANDOMIZATION_OFFSET).value.should eq(20_i16)
    read_tlv(cluster, Tariff::ATTR_DEFAULT_RANDOMIZATION_TYPE).value.should eq(Tariff::DayEntryRandomizationType::Fixed.value)
    first = read_tlv(cluster, Tariff::ATTR_DAY_ENTRIES).as_list.first.as_structure
    first[3_u8].value.should eq(0_i16)
    first[4_u8].value.should eq(Tariff::DayEntryRandomizationType::None.value)
    read_tlv(cluster, Tariff::ATTR_DAY_ENTRIES).as_list.last.as_structure.has_key?(3_u8).should be_false
    read(cluster, Tariff::ATTR_NEXT_DAY_ENTRY_DATE).should eq(80_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
    cluster.refresh_at(80_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(11_u32)

    restored = build(Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::Randomization)
    restored.restore_state(cluster.save_state)
    restored.refresh_at(79_u32)
    restored.next_day_entry_date.should eq(80_u32)
    restored.refresh_at(80_u32)
    restored.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(11_u32)
  end

  it "keeps random day-entry choices stable through refresh and restart" do
    baseline = tariff_publication
    [
      {Tariff::DayEntryRandomizationType::Random, 30_i16, 43_170_u32, 43_230_u32},
      {Tariff::DayEntryRandomizationType::RandomPositive, 30_i16, 43_200_u32, 43_230_u32},
      {Tariff::DayEntryRandomizationType::RandomNegative, -30_i16, 43_170_u32, 43_200_u32},
    ].each do |kind, offset, earliest, latest|
      cluster = build(Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::Randomization)
      entries = [
        Tariff::DayEntry.new(10_u32, 0_u16, randomization_type: Tariff::DayEntryRandomizationType::None),
        Tariff::DayEntry.new(11_u32, 720_u16, randomization_offset: offset, randomization_type: kind),
      ]
      publication = Tariff::Publication.new(baseline.info, baseline.unit,
        baseline.start_date, entries, baseline.day_patterns,
        baseline.calendar_periods, baseline.individual_days,
        baseline.components, baseline.tariff_periods)
      cluster.publish(publication, at: 100_u32)
      next_date = cluster.next_day_entry_date.as(UInt32)
      (earliest..latest).includes?(next_date).should be_true
      cluster.refresh_at(100_u32)
      cluster.next_day_entry_date.should eq(next_date)
      restored = build(Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::Randomization)
      restored.restore_state(cluster.save_state)
      restored.refresh_at(100_u32)
      restored.next_day_entry_date.should eq(next_date)
    end
  end

  it "rejects invalid randomization fields and overtaking entries before publication" do
    baseline = tariff_publication
    plain = build(Tariff)
    entries = [Tariff::DayEntry.new(10_u32, 0_u16,
      randomization_type: Tariff::DayEntryRandomizationType::Fixed)]
    publication = Tariff::Publication.new(baseline.info, baseline.unit,
      baseline.start_date, entries, baseline.day_patterns,
      baseline.calendar_periods, baseline.individual_days,
      baseline.components, baseline.tariff_periods)
    expect_raises(ArgumentError, /Randomization feature/) { plain.publish(publication, at: 100_u32) }

    randomized = build(Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::Randomization)
    bad_offsets = [
      {Tariff::DayEntryRandomizationType::Random, -1_i16},
      {Tariff::DayEntryRandomizationType::RandomPositive, -1_i16},
      {Tariff::DayEntryRandomizationType::RandomNegative, 1_i16},
    ]
    bad_offsets.each do |kind, offset|
      changed = [Tariff::DayEntry.new(10_u32, 0_u16),
                 Tariff::DayEntry.new(11_u32, 720_u16, randomization_offset: offset, randomization_type: kind)]
      rejected = Tariff::Publication.new(baseline.info, baseline.unit,
        baseline.start_date, changed, baseline.day_patterns,
        baseline.calendar_periods, baseline.individual_days,
        baseline.components, baseline.tariff_periods)
      expect_raises(ArgumentError, /offset/) { randomized.publish(rejected, at: 100_u32) }
    end
    overtaking = [Tariff::DayEntry.new(10_u32, 0_u16),
                  Tariff::DayEntry.new(11_u32, 1_u16, randomization_offset: 61_i16,
                    randomization_type: Tariff::DayEntryRandomizationType::Random)]
    rejected = Tariff::Publication.new(baseline.info, baseline.unit,
      baseline.start_date, overtaking, baseline.day_patterns,
      baseline.calendar_periods, baseline.individual_days,
      baseline.components, baseline.tariff_periods)
    expect_raises(ArgumentError, /overtake/) { randomized.publish(rejected, at: 100_u32) }
    randomized.tariff_info.should be_nil
  end

  it "publishes an AuxiliaryLoad-only calendar without Currency or Price" do
    cluster = build(Tariff, feature_map: Tariff::Feature::AuxiliaryLoad)
    baseline = tariff_publication
    info = Tariff::TariffInformation.new("Auxiliary load", "Supplier", nil, Tariff::BlockMode::NoBlock)
    components = [
      Tariff::TariffComponent.new(30_u32, nil, nil,
        auxiliary_load: Tariff::AuxiliaryLoadSwitchSettings.new(1_u8, Tariff::AuxiliaryLoadSetting::On)),
      Tariff::TariffComponent.new(31_u32, nil, nil,
        auxiliary_load: Tariff::AuxiliaryLoadSwitchSettings.new(1_u8, Tariff::AuxiliaryLoadSetting::Off)),
    ]
    publication = Tariff::Publication.new(info, nil, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    cluster.publish(publication, at: 100_u32)
    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq(Tariff::Feature::AuxiliaryLoad.value)
    read_tlv(cluster, Tariff::ATTR_TARIFF_INFO).as_structure.has_key?(2_u8).should be_false
    read_tlv(cluster, Tariff::ATTR_TARIFF_UNIT).value.should be_nil
    current = read_tlv(cluster, Tariff::ATTR_CURRENT_TARIFF_COMPONENTS).as_list.first.as_structure
    current.has_key?(1_u8).should be_false
    current[3_u8].as_structure[1_u8].value.should eq(Tariff::AuxiliaryLoadSetting::On.value)
    cluster.refresh_at(43_200_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.auxiliary_load
      .as(Tariff::AuxiliaryLoadSwitchSettings).required_state.should eq(Tariff::AuxiliaryLoadSetting::Off)
    restored = build(Tariff, feature_map: Tariff::Feature::AuxiliaryLoad)
    restored.restore_state(cluster.save_state)
    restored.refresh_at(43_200_u32)
    restored.current_tariff_components.as(Array(Tariff::TariffComponent)).first.auxiliary_load
      .as(Tariff::AuxiliaryLoadSwitchSettings).required_state.should eq(Tariff::AuxiliaryLoadSetting::Off)
    read_tlv(restored, Tariff::ATTR_TARIFF_INFO).as_structure.has_key?(2_u8).should be_false
    read_tlv(restored, Tariff::ATTR_TARIFF_UNIT).value.should be_nil
    response = invoke(restored, Tariff::CMD_GET_TARIFF_COMPONENT,
      Tariff::GetTariffComponentRequest.new(30_u32)).as(Matter::Cluster::CommandResponse)
    Tariff::GetTariffComponentResponse.from_tlv(response.response.as(TLV::Any))
      .tariff_component.auxiliary_load.as(Tariff::AuxiliaryLoadSwitchSettings)
      .required_state.should eq(Tariff::AuxiliaryLoadSetting::On)

    with_currency = Tariff::Publication.new(baseline.info, nil, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    expect_raises(ArgumentError, /Currency requires Pricing/) { cluster.publish(with_currency, at: 100_u32) }
    priced = Tariff::Publication.new(info, nil, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, baseline.components, baseline.tariff_periods)
    expect_raises(ArgumentError, /Price requires Pricing/) { cluster.publish(priced, at: 100_u32) }
  end

  it "publishes a FriendlyCredit-only calendar without Currency or Price" do
    cluster = build(Tariff, feature_map: Tariff::Feature::FriendlyCredit)
    baseline = tariff_publication
    info = Tariff::TariffInformation.new("Friendly credit", "Supplier", nil, Tariff::BlockMode::NoBlock)
    components = [
      Tariff::TariffComponent.new(30_u32, nil, nil, friendly_credit: true),
      Tariff::TariffComponent.new(31_u32, nil, nil, friendly_credit: false),
    ]
    publication = Tariff::Publication.new(info, nil, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    cluster.publish(publication, at: 100_u32)
    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq(Tariff::Feature::FriendlyCredit.value)
    read_tlv(cluster, Tariff::ATTR_TARIFF_INFO).as_structure.has_key?(2_u8).should be_false
    read_tlv(cluster, Tariff::ATTR_TARIFF_UNIT).value.should be_nil
    current = read_tlv(cluster, Tariff::ATTR_CURRENT_TARIFF_COMPONENTS).as_list.first.as_structure
    current.has_key?(1_u8).should be_false
    current[2_u8].as_bool.should be_true
    cluster.refresh_at(43_200_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.friendly_credit.should be_false
    restored = build(Tariff, feature_map: Tariff::Feature::FriendlyCredit)
    restored.restore_state(cluster.save_state)
    restored.refresh_at(43_200_u32)
    restored.current_tariff_components.as(Array(Tariff::TariffComponent)).first.friendly_credit.should be_false
    read_tlv(restored, Tariff::ATTR_TARIFF_INFO).as_structure.has_key?(2_u8).should be_false
    read_tlv(restored, Tariff::ATTR_TARIFF_UNIT).value.should be_nil
    response = invoke(restored, Tariff::CMD_GET_TARIFF_COMPONENT,
      Tariff::GetTariffComponentRequest.new(30_u32)).as(Matter::Cluster::CommandResponse)
    Tariff::GetTariffComponentResponse.from_tlv(response.response.as(TLV::Any))
      .tariff_component.friendly_credit.should be_true

    with_currency = Tariff::Publication.new(baseline.info, nil, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    expect_raises(ArgumentError, /Currency requires Pricing/) { cluster.publish(with_currency, at: 100_u32) }
    priced = Tariff::Publication.new(info, nil, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, baseline.components, baseline.tariff_periods)
    expect_raises(ArgumentError, /Price requires Pricing/) { cluster.publish(priced, at: 100_u32) }
    pricing = build(Tariff, feature_map: Tariff::Feature::Pricing)
    expect_raises(ArgumentError, /Pricing requires Currency/) { pricing.publish(priced, at: 100_u32) }
  end

  it "projects and persists opt-in power thresholds with nullable source" do
    feature_map = Tariff::Feature::Pricing | Tariff::Feature::PowerThreshold
    cluster = build(Tariff, feature_map: feature_map)
    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    expect_raises(ArgumentError, /fixed/) { cluster.feature_map = Tariff::Feature::Pricing }
    expect_raises(ArgumentError, /Pricing/) { build(Tariff, feature_map: Tariff::Feature::PowerThreshold) }
    baseline = tariff_publication
    components = [
      Tariff::TariffComponent.new(30_u32, nil, nil, power_threshold: Tariff::PowerThreshold.new(power_threshold: 2_000_i64,
        power_threshold_source: Tariff::PowerThresholdSource::Contract)),
      Tariff::TariffComponent.new(31_u32,
        Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil,
        power_threshold: Tariff::PowerThreshold.new(apparent_power_threshold: 3_000_i64)),
    ]
    publication = Tariff::Publication.new(baseline.info, baseline.unit, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    cluster.publish(publication, at: 100_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.power_threshold
      .as(Tariff::PowerThreshold).power_threshold.should eq(2_000_i64)
    cluster.next_tariff_components.as(Array(Tariff::TariffComponent)).first.power_threshold
      .as(Tariff::PowerThreshold).apparent_power_threshold.should eq(3_000_i64)
    current = read_tlv(cluster, Tariff::ATTR_CURRENT_TARIFF_COMPONENTS).as_list.first.as_structure
    current.has_key?(1_u8).should be_false
    current[5_u8].as_structure[0_u8].value.should eq(2_000_i64)
    current[5_u8].as_structure.has_key?(1_u8).should be_false
    current[5_u8].as_structure[2_u8].value.should eq(Tariff::PowerThresholdSource::Contract.value)
    following = read_tlv(cluster, Tariff::ATTR_NEXT_TARIFF_COMPONENTS).as_list.first.as_structure
    following[5_u8].as_structure.has_key?(0_u8).should be_false
    following[5_u8].as_structure[1_u8].value.should eq(3_000_i64)
    following[5_u8].as_structure[2_u8].value.should be_nil
    response = invoke(cluster, Tariff::CMD_GET_TARIFF_COMPONENT,
      Tariff::GetTariffComponentRequest.new(30_u32)).as(Matter::Cluster::CommandResponse)
    Tariff::GetTariffComponentResponse.from_tlv(response.response.as(TLV::Any))
      .tariff_component.power_threshold.as(Tariff::PowerThreshold).power_threshold_source
      .should eq(Tariff::PowerThresholdSource::Contract)
    cluster.refresh_at(43_200_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.power_threshold
      .as(Tariff::PowerThreshold).apparent_power_threshold.should eq(3_000_i64)
    restored = build(Tariff, feature_map: feature_map)
    restored.restore_state(cluster.save_state)
    restored.refresh_at(43_200_u32)
    restored.current_tariff_components.as(Array(Tariff::TariffComponent)).first.power_threshold
      .as(Tariff::PowerThreshold).apparent_power_threshold.should eq(3_000_i64)

    pricing = tariff_fixture
    expect_raises(ArgumentError, /PowerThreshold/) { pricing.publish(publication, at: 100_u32) }
    pricing.publish(baseline, at: 100_u32)
    read_tlv(pricing, Tariff::ATTR_TARIFF_COMPONENTS).as_list.first.as_structure.has_key?(5_u8).should be_false
  end

  it "projects and persists opt-in auxiliary switch settings" do
    feature_map = Tariff::Feature::Pricing | Tariff::Feature::AuxiliaryLoad
    cluster = build(Tariff, feature_map: feature_map)
    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    expect_raises(ArgumentError, /fixed/) { cluster.feature_map = Tariff::Feature::Pricing }
    baseline = tariff_publication
    components = [
      Tariff::TariffComponent.new(30_u32, nil, nil,
        auxiliary_load: Tariff::AuxiliaryLoadSwitchSettings.new(1_u8, Tariff::AuxiliaryLoadSetting::On)),
      Tariff::TariffComponent.new(31_u32,
        Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil,
        auxiliary_load: Tariff::AuxiliaryLoadSwitchSettings.new(1_u8, Tariff::AuxiliaryLoadSetting::Off)),
    ]
    publication = Tariff::Publication.new(baseline.info, baseline.unit, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    cluster.publish(publication, at: 100_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.auxiliary_load
      .as(Tariff::AuxiliaryLoadSwitchSettings).required_state.should eq(Tariff::AuxiliaryLoadSetting::On)
    cluster.next_tariff_components.as(Array(Tariff::TariffComponent)).first.auxiliary_load
      .as(Tariff::AuxiliaryLoadSwitchSettings).required_state.should eq(Tariff::AuxiliaryLoadSetting::Off)
    current = read_tlv(cluster, Tariff::ATTR_CURRENT_TARIFF_COMPONENTS).as_list.first.as_structure
    current.has_key?(1_u8).should be_false
    current[3_u8].as_structure[0_u8].value.should eq(1_u8)
    current[3_u8].as_structure[1_u8].value.should eq(Tariff::AuxiliaryLoadSetting::On.value)
    response = invoke(cluster, Tariff::CMD_GET_TARIFF_COMPONENT,
      Tariff::GetTariffComponentRequest.new(30_u32)).as(Matter::Cluster::CommandResponse)
    Tariff::GetTariffComponentResponse.from_tlv(response.response.as(TLV::Any))
      .tariff_component.auxiliary_load.as(Tariff::AuxiliaryLoadSwitchSettings).number.should eq(1_u8)
    cluster.refresh_at(43_200_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.auxiliary_load
      .as(Tariff::AuxiliaryLoadSwitchSettings).required_state.should eq(Tariff::AuxiliaryLoadSetting::Off)
    restored = build(Tariff, feature_map: feature_map)
    restored.restore_state(cluster.save_state)
    restored.refresh_at(43_200_u32)
    restored.current_tariff_components.as(Array(Tariff::TariffComponent)).first.auxiliary_load
      .as(Tariff::AuxiliaryLoadSwitchSettings).required_state.should eq(Tariff::AuxiliaryLoadSetting::Off)

    pricing = tariff_fixture
    expect_raises(ArgumentError, /AuxiliaryLoad/) { pricing.publish(publication, at: 100_u32) }
    pricing.publish(baseline, at: 100_u32)
    read_tlv(pricing, Tariff::ATTR_TARIFF_COMPONENTS).as_list.first.as_structure.has_key?(3_u8).should be_false
  end

  it "projects and persists opt-in peak periods without changing Pricing or FriendlyCredit" do
    feature_map = Tariff::Feature::Pricing | Tariff::Feature::PeakPeriod
    cluster = build(Tariff, feature_map: feature_map)
    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    expect_raises(ArgumentError, /fixed/) { cluster.feature_map = Tariff::Feature::Pricing }
    baseline = tariff_publication
    components = [
      Tariff::TariffComponent.new(30_u32, nil, nil,
        peak_period: Tariff::PeakPeriod.new(Tariff::PeakPeriodSeverity::Low, 1_u16)),
      Tariff::TariffComponent.new(31_u32,
        Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil,
        peak_period: Tariff::PeakPeriod.new(Tariff::PeakPeriodSeverity::High, 2_u16)),
    ]
    publication = Tariff::Publication.new(baseline.info, baseline.unit, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    cluster.publish(publication, at: 100_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.peak_period
      .as(Tariff::PeakPeriod).severity.should eq(Tariff::PeakPeriodSeverity::Low)
    cluster.next_tariff_components.as(Array(Tariff::TariffComponent)).first.peak_period
      .as(Tariff::PeakPeriod).period.should eq(2_u16)
    current = read_tlv(cluster, Tariff::ATTR_CURRENT_TARIFF_COMPONENTS).as_list.first.as_structure
    current.has_key?(1_u8).should be_false
    current[4_u8].as_structure[0_u8].value.should eq(Tariff::PeakPeriodSeverity::Low.value)
    current[4_u8].as_structure[1_u8].value.should eq(1_u16)
    response = invoke(cluster, Tariff::CMD_GET_TARIFF_COMPONENT,
      Tariff::GetTariffComponentRequest.new(30_u32)).as(Matter::Cluster::CommandResponse)
    Tariff::GetTariffComponentResponse.from_tlv(response.response.as(TLV::Any))
      .tariff_component.peak_period.as(Tariff::PeakPeriod).period.should eq(1_u16)
    cluster.refresh_at(43_200_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.peak_period
      .as(Tariff::PeakPeriod).severity.should eq(Tariff::PeakPeriodSeverity::High)
    restored = build(Tariff, feature_map: feature_map)
    restored.restore_state(cluster.save_state)
    restored.refresh_at(43_200_u32)
    restored.current_tariff_components.as(Array(Tariff::TariffComponent)).first.peak_period
      .as(Tariff::PeakPeriod).period.should eq(2_u16)

    pricing = tariff_fixture
    expect_raises(ArgumentError, /PeakPeriod/) { pricing.publish(publication, at: 100_u32) }
    zero_peak = components.dup
    zero_peak[0] = Tariff::TariffComponent.new(30_u32, nil, nil,
      peak_period: Tariff::PeakPeriod.new(Tariff::PeakPeriodSeverity::Low, 0_u16))
    invalid = Tariff::Publication.new(baseline.info, baseline.unit, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, zero_peak, baseline.tariff_periods)
    expect_raises(ArgumentError, /PeakPeriod number/) { cluster.publish(invalid, at: 100_u32) }
    pricing.publish(baseline, at: 100_u32)
    read_tlv(pricing, Tariff::ATTR_TARIFF_COMPONENTS).as_list.first.as_structure.has_key?(4_u8).should be_false

    credit = build(Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::FriendlyCredit |
                                        Tariff::Feature::PeakPeriod)
    credit.publish(publication, at: 100_u32)
    read(credit, Tariff::GLOBAL_FEATURE_MAP).should eq(credit.feature_map.value)
  end

  it "projects and persists opt-in friendly credit transitions without changing Pricing-only components" do
    feature_map = Tariff::Feature::Pricing | Tariff::Feature::FriendlyCredit
    cluster = build(Tariff, feature_map: feature_map)
    read(cluster, Tariff::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    expect_raises(ArgumentError, /fixed/) { cluster.feature_map = Tariff::Feature::Pricing }
    baseline = tariff_publication
    components = [
      Tariff::TariffComponent.new(30_u32, nil, nil, friendly_credit: true),
      Tariff::TariffComponent.new(31_u32,
        Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil,
        friendly_credit: false),
    ]
    publication = Tariff::Publication.new(baseline.info, baseline.unit, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, components, baseline.tariff_periods)
    cluster.publish(publication, at: 100_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.friendly_credit.should be_true
    cluster.next_tariff_components.as(Array(Tariff::TariffComponent)).first.friendly_credit.should be_false
    current = read_tlv(cluster, Tariff::ATTR_CURRENT_TARIFF_COMPONENTS).as_list.first.as_structure
    current[2_u8].as_bool.should be_true
    current.has_key?(1_u8).should be_false
    response = invoke(cluster, Tariff::CMD_GET_TARIFF_COMPONENT,
      Tariff::GetTariffComponentRequest.new(30_u32)).as(Matter::Cluster::CommandResponse)
    Tariff::GetTariffComponentResponse.from_tlv(response.response.as(TLV::Any))
      .tariff_component.friendly_credit.should be_true
    cluster.refresh_at(43_200_u32)
    cluster.current_tariff_components.as(Array(Tariff::TariffComponent)).first.friendly_credit.should be_false
    restored = build(Tariff, feature_map: feature_map)
    restored.restore_state(cluster.save_state)
    restored.refresh_at(43_200_u32)
    restored.current_tariff_components.as(Array(Tariff::TariffComponent)).first.friendly_credit.should be_false
    read_tlv(restored, Tariff::ATTR_TARIFF_COMPONENTS).as_list.first.as_structure[2_u8].as_bool.should be_true

    pricing = tariff_fixture
    expect_raises(ArgumentError, /FriendlyCredit/) { pricing.publish(publication, at: 100_u32) }
    no_price = Tariff::Publication.new(baseline.info, baseline.unit, baseline.start_date,
      baseline.day_entries, baseline.day_patterns, baseline.calendar_periods,
      baseline.individual_days, [Tariff::TariffComponent.new(30_u32, nil, nil)] + baseline.components.last(1),
      baseline.tariff_periods)
    expect_raises(ArgumentError, /price/) { pricing.publish(no_price, at: 100_u32) }
    pricing.publish(baseline, at: 100_u32)
    read_tlv(pricing, Tariff::ATTR_TARIFF_COMPONENTS).as_list.first.as_structure.has_key?(2_u8).should be_false
  end

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

  it "advances rotating day patterns in calendar order" do
    cluster = tariff_fixture
    valid = tariff_publication
    patterns = [
      Tariff::DayPattern.new(20_u32, 0_u8, [10_u32]),
      Tariff::DayPattern.new(21_u32, 0_u8, [12_u32]),
    ]
    periods = [Tariff::CalendarPeriod.new(0_u32, [20_u32, 21_u32])]
    rotating = Tariff::Publication.new(valid.info, valid.unit, 0_u32,
      valid.day_entries + [Tariff::DayEntry.new(12_u32, 0_u16)],
      patterns, periods, valid.individual_days,
      valid.components, valid.tariff_periods + [Tariff::TariffPeriod.new("Rotating", [12_u32], [30_u32])])
    cluster.publish(rotating, at: 100_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
    cluster.next_day.as(Tariff::Day).day_entry_ids.should eq([12_u32])
    cluster.refresh_at(86_500_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(12_u32)
    cluster.refresh_at(172_900_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
  end

  it "persists the start of an immediate rotating calendar" do
    cluster = tariff_fixture
    valid = tariff_publication
    patterns = [
      Tariff::DayPattern.new(20_u32, 0_u8, [10_u32]),
      Tariff::DayPattern.new(21_u32, 0_u8, [12_u32]),
    ]
    periods = [Tariff::CalendarPeriod.new(nil, [20_u32, 21_u32])]
    rotating = Tariff::Publication.new(valid.info, valid.unit, nil,
      valid.day_entries + [Tariff::DayEntry.new(12_u32, 0_u16)],
      patterns, periods, valid.individual_days,
      valid.components, valid.tariff_periods + [Tariff::TariffPeriod.new("Rotating", [12_u32], [30_u32])])
    cluster.publish(rotating, at: 172_900_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
    restored = tariff_fixture
    restored.restore_state(cluster.save_state)
    restored.refresh_at(259_300_u32)
    restored.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(12_u32)
  end

  it "restarts rotation when a new calendar period begins" do
    cluster = tariff_fixture
    valid = tariff_publication
    patterns = [
      Tariff::DayPattern.new(20_u32, 0_u8, [10_u32]),
      Tariff::DayPattern.new(21_u32, 0_u8, [12_u32]),
    ]
    periods = [
      Tariff::CalendarPeriod.new(0_u32, [20_u32, 21_u32]),
      Tariff::CalendarPeriod.new(172_800_u32, [21_u32, 20_u32]),
    ]
    publication = Tariff::Publication.new(valid.info, valid.unit, 0_u32,
      valid.day_entries + [Tariff::DayEntry.new(12_u32, 0_u16)],
      patterns, periods, valid.individual_days,
      valid.components, valid.tariff_periods + [Tariff::TariffPeriod.new("Rotating", [12_u32], [30_u32])])
    cluster.publish(publication, at: 100_u32)
    cluster.refresh_at(172_900_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(12_u32)
    cluster.refresh_at(259_300_u32)
    cluster.current_day_entry.as(Tariff::DayEntry).day_entry_id.should eq(10_u32)
  end

  it "rejects a calendar period mixing rotating and weekday patterns" do
    cluster = tariff_fixture
    valid = tariff_publication
    patterns = [
      Tariff::DayPattern.new(20_u32, 0_u8, [10_u32]),
      Tariff::DayPattern.new(21_u32, 0x7F_u8, [10_u32]),
    ]
    publication = Tariff::Publication.new(valid.info, valid.unit,
      valid.start_date, valid.day_entries, patterns,
      [Tariff::CalendarPeriod.new(0_u32, [20_u32, 21_u32])],
      valid.individual_days, valid.components, valid.tariff_periods)
    expect_raises(ArgumentError, /rotating and weekday patterns cannot mix/) do
      cluster.publish(publication, at: 100_u32)
    end
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
