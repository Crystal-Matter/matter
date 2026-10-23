require "../spec_helper"

private alias Grid = Matter::Cluster::ElectricalGridConditions
private alias GridStatus = Matter::InteractionModel::StatusCode

private def grid_condition(start : UInt32, finish : UInt32? = nil,
                           grid : Int16 = 200_i16, local : Int16 = 200_i16) : Grid::Condition
  Grid::Condition.new(start, finish, grid, Grid::ThreeLevel::Medium,
    local, Grid::ThreeLevel::Medium)
end

describe Grid do
  it "exposes revision 1, conditional forecasting, and typed TLV field tags" do
    condition = grid_condition(100_u32, nil)
    condition.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8])
    Grid::Condition.from_tlv(condition.to_tlv(nil)).period_end.should be_nil

    basic = build(Grid)
    basic.cluster_id.id.should eq(0x00A0_u32)
    basic.cluster_revision.should eq(1_u16)
    read_status(basic, Grid::ATTR_FORECAST_CONDITIONS).status.should eq(GridStatus::UnsupportedAttribute)
    basic.get_event_metadata(Grid::EVENT_CURRENT_CONDITIONS_CHANGED).should_not be_nil

    forecast = build(Grid, feature_map: Grid::Feature::Forecasting)
    read_tlv(forecast, Grid::ATTR_FORECAST_CONDITIONS).as_list.should be_empty
  end

  it "validates period ends, forecast order, and 56-entry limit" do
    expect_raises(ArgumentError) { build(Grid, current_conditions: grid_condition(100_u32, 100_u32)) }
    expect_raises(ArgumentError) do
      build(Grid, feature_map: Grid::Feature::Forecasting,
        forecast_conditions: [grid_condition(100_u32), grid_condition(200_u32, 300_u32)])
    end
    expect_raises(ArgumentError) do
      build(Grid, feature_map: Grid::Feature::Forecasting,
        forecast_conditions: [grid_condition(100_u32, 200_u32), grid_condition(200_u32, 300_u32)])
    end
    expect_raises(ArgumentError) do
      build(Grid, feature_map: Grid::Feature::Forecasting,
        forecast_conditions: Array.new(57) { |index| grid_condition((index * 2).to_u32, (index * 2 + 1).to_u32) })
    end
  end

  it "keeps advertised forecast arrays isolated from host input and reads" do
    source = [grid_condition(100_u32, 200_u32), grid_condition(201_u32)]
    cluster = build(Grid, feature_map: Grid::Feature::Forecasting, forecast_conditions: source)
    source.clear
    cluster.forecast_conditions.size.should eq(2)
    cluster.forecast_conditions.clear
    read_tlv(cluster, Grid::ATTR_FORECAST_CONDITIONS).as_list.size.should eq(2)
  end

  it "enforces no-local-generation carbon equality and controller write access" do
    expect_raises(ArgumentError) do
      build(Grid, local_generation_available: false,
        current_conditions: grid_condition(100_u32, 200_u32, local: 100_i16))
    end
    cluster = build(Grid, local_generation_available: false, current_conditions: grid_condition(100_u32, 200_u32))
    expect_status(write(cluster, Grid::ATTR_LOCAL_GENERATION_AVAILABLE, true), GridStatus::Success)
    read(cluster, Grid::ATTR_LOCAL_GENERATION_AVAILABLE).should be_true

    with_generation = build(Grid, local_generation_available: true,
      current_conditions: grid_condition(100_u32, 200_u32, local: 100_i16))
    expect_status(write(with_generation, Grid::ATTR_LOCAL_GENERATION_AVAILABLE, false), GridStatus::ConstraintError)
    with_generation.local_generation_available?.should be_true
  end

  it "emits a typed event only when current conditions change" do
    cluster = build(Grid)
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(Grid::EVENT_CURRENT_CONDITIONS_CHANGED)
      priority.should eq(Matter::InteractionModel::EventPriority::Info)
      events << data
      nil
    end
    condition = grid_condition(100_u32, 200_u32)
    cluster.current_conditions = condition
    cluster.current_conditions = condition
    cluster.current_conditions = nil
    events.size.should eq(2)
    Grid::CurrentConditionsChangedEvent.from_tlv(events.first).current_conditions.should eq(condition)
    Grid::CurrentConditionsChangedEvent.from_tlv(events.last).current_conditions.should be_nil
  end
end
