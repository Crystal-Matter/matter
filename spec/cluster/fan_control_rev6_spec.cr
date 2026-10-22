require "../spec_helper"

private alias Fan = Matter::Cluster::FanControl

describe "Fan Control Matter 1.6 revision 6" do
  it "advertises revision 6 with the XML-required feature-gated surface" do
    mandatory = build(Fan, feature_map: Fan::Feature::None)
    mandatory.cluster_revision.should eq(6_u16)
    mandatory.attributes.map(&.id.id).should eq([
      Fan::ATTR_FAN_MODE,
      Fan::ATTR_FAN_MODE_SEQUENCE,
      Fan::ATTR_PERCENT_SETTING,
      Fan::ATTR_PERCENT_CURRENT,
    ])
    mandatory.commands.should be_empty

    all = build(Fan,
      feature_map: Fan::Feature::MultiSpeed | Fan::Feature::Auto | Fan::Feature::Rocking |
                   Fan::Feature::Wind | Fan::Feature::Step | Fan::Feature::AirflowDirection,
      fan_mode_sequence: Fan::FanModeSequence::OffLowMedHighAuto,
      rock_support: Fan::RockSupport::RockLeftRight,
      wind_support: Fan::WindSupport::SleepWind)
    all.attributes.map(&.id.id).should eq((Fan::ATTR_FAN_MODE..Fan::ATTR_AIRFLOW_DIRECTION).to_a)
    all.commands.map(&.id.id).should eq([Fan::CMD_STEP])
  end

  it "requires Operate privilege for every writable attribute" do
    fan = build(Fan,
      feature_map: Fan::Feature::MultiSpeed | Fan::Feature::Rocking | Fan::Feature::Wind | Fan::Feature::AirflowDirection,
      rock_support: Fan::RockSupport::RockLeftRight,
      wind_support: Fan::WindSupport::SleepWind)
    writable_ids = [Fan::ATTR_FAN_MODE, Fan::ATTR_PERCENT_SETTING, Fan::ATTR_SPEED_SETTING,
                    Fan::ATTR_ROCK_SETTING, Fan::ATTR_WIND_SETTING, Fan::ATTR_AIRFLOW_DIRECTION]
    writable_ids.each do |id|
      metadata = fan.attributes.find!(&.id.id.==(id))
      metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    end
  end

  it "persists only FanMode, leaving removed P-quality settings volatile" do
    features = Fan::Feature::MultiSpeed | Fan::Feature::Rocking | Fan::Feature::Wind | Fan::Feature::AirflowDirection
    source = build(Fan, feature_map: features,
      rock_support: Fan::RockSupport::RockLeftRight,
      wind_support: Fan::WindSupport::SleepWind)
    write(source, Fan::ATTR_FAN_MODE, Fan::FanMode::High.value.to_u8)
    write(source, Fan::ATTR_PERCENT_SETTING, 75_u8)
    write(source, Fan::ATTR_ROCK_SETTING, Fan::RockSupport::RockLeftRight.value.to_u8)
    write(source, Fan::ATTR_WIND_SETTING, Fan::WindSupport::SleepWind.value.to_u8)
    write(source, Fan::ATTR_AIRFLOW_DIRECTION, Fan::AirflowDirectionEnum::Reverse.value.to_u8)

    saved = source.save_state.as(Matter::Storage::Document)
    saved.keys.should contain("fan_mode")
    %w[percent_setting speed_setting rock_setting wind_setting airflow_direction].each do |name|
      saved.keys.should_not contain(name)
    end

    restored = build(Fan, feature_map: features,
      rock_support: Fan::RockSupport::RockLeftRight,
      wind_support: Fan::WindSupport::SleepWind)
    restored.restore_state(saved)
    restored.fan_mode.should eq(Fan::FanMode::High)
    restored.percent_setting.should eq(0_u8)
    restored.speed_setting.should eq(0_u8)
    restored.rock_setting.should eq(Fan::RockSupport::None)
    restored.wind_setting.should eq(Fan::WindSupport::None)
    restored.airflow_direction.should eq(Fan::AirflowDirectionEnum::Forward)
  end
end
