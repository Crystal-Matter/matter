require "spec"
require "../../examples/support/motion_hold"

describe MatterMotionSensor::MotionHold do
  it "holds occupancy until the configured duration after the last detection" do
    detector = MatterMotionSensor::MotionHold.new
    start = Time.instant
    detector.sample(true, 60_u16, start).should be_true
    detector.sample(false, 60_u16, start + 30.seconds).should be_nil
    detector.sample(true, 60_u16, start + 40.seconds).should be_nil
    detector.sample(false, 60_u16, start + 99.seconds).should be_nil
    detector.sample(false, 60_u16, start + 100.seconds).should be_false
  end

  it "uses a newly configured hold time for an active occupancy" do
    detector = MatterMotionSensor::MotionHold.new
    start = Time.instant
    detector.sample(true, 120_u16, start).should be_true
    detector.sample(false, 10_u16, start + 9.seconds).should be_nil
    detector.sample(false, 10_u16, start + 10.seconds).should be_false
  end
end
