require "../spec_helper"

private alias SteppingFan = Matter::Cluster::FanControl

describe "Fan Control Step with MultiSpeed" do
  it "wraps from SpeedMax to the lowest running speed" do
    fan = build(SteppingFan,
      feature_map: SteppingFan::Feature::MultiSpeed | SteppingFan::Feature::Step,
      speed_max: 3_u8)
    write(fan, SteppingFan::ATTR_SPEED_SETTING, 3_u8)

    request = SteppingFan::StepRequest.new(SteppingFan::StepDirection::Increase,
      wrap: true, lowest_off: false)
    invoke(fan, SteppingFan::CMD_STEP, request)

    fan.speed_current.should eq(1_u8)
    fan.speed_setting.should eq(1_u8)
  end

  it "wraps from the lowest running speed to SpeedMax" do
    fan = build(SteppingFan,
      feature_map: SteppingFan::Feature::MultiSpeed | SteppingFan::Feature::Step,
      speed_max: 3_u8)
    write(fan, SteppingFan::ATTR_SPEED_SETTING, 1_u8)

    request = SteppingFan::StepRequest.new(SteppingFan::StepDirection::Decrease,
      wrap: true, lowest_off: false)
    invoke(fan, SteppingFan::CMD_STEP, request)

    fan.speed_current.should eq(3_u8)
    fan.speed_setting.should eq(3_u8)
  end
end
