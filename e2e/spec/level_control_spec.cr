require "./e2e_helper"

# Dimmable light, color light and window covering endpoints.
module LevelControlE2E
  COLOR_ENDPOINT               =  2
  COVERING_ENDPOINT            =  3
  GROUP_ID                     = 42
  GROUP_NAME                   = "Reading room"
  TARGET_HUE                   =   90
  OFF_TARGET_HUE               =  120
  COLOR_TEMPERATURE            =  300
  COUPLED_TEMPERATURE_MIN      =  200
  PHYSICAL_TEMPERATURE_MAX     =  500
  COUPLED_MIDPOINT_TEMPERATURE =  350
  LEVEL_MINIMUM                =    1
  LEVEL_MIDPOINT               =  127
  LEVEL_MAXIMUM                =  254
  COUPLE_COLOR_OPTION          =    2
  START_COLOR_TEMPERATURE      =  250
  STARTUP_COLOR_TEMPERATURE    =  320
  HUE_MODE                     =    0
  TEMPERATURE_MODE             =    2
  LIFT_POSITION                = 5000
  COVERING_POSITION_TIMEOUT    = 10.seconds
  COVERING_POLL_INTERVAL       = 100.milliseconds
  COVERING_CANCELED_WAIT       = 4.seconds
  NO_TRANSITION                = "0"
  TIMED_TRANSITION             = "50"
  NO_OPTIONS                   = "0"
  SHORTEST_HUE_DIRECTION       = "0"
  COLOR_OPTIONS                = 1
  COLOR_OPTIONS_CLEAR          = 0
  EXECUTE_IF_OFF               = 1
  COVERING_MODE                = 1
  COVERING_STOPPED_STATUS      = 0
  COVERING_REVISION            = 8
  COVERING_MAINTENANCE         = 4
  COVERING_CALIBRATION         = 2
  COVERING_REVERSED            = 1
end

def wait_for_covering_lift(device : E2E::Device, target : Int32, endpoint : Int32) : Nil
  deadline = Time.instant + LevelControlE2E::COVERING_POSITION_TIMEOUT
  loop do
    current = read_int(device, "windowcovering", "current-position-lift-percent100ths", "CurrentPositionLiftPercent100ths", endpoint)
    return if current == target
    current.should eq(target) if Time.instant >= deadline
    sleep LevelControlE2E::COVERING_POLL_INTERVAL
  end
end

describe "matter_level_control example" do
  device = E2E::Device["matter_level_control"]

  it "commissions with chip-tool" do
    device.commission!
  end

  it "is a dimmable light with two fixed labels" do
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x0101_i64
    expect_success(device.read("fixedlabel", "label-list")).values("Value").should eq ["Example Level", "Example Mute"]
  end

  it "reads the current level and its limits" do
    read_int(device, "levelcontrol", "min-level", "MinLevel").should eq 1
    read_int(device, "levelcontrol", "max-level", "MaxLevel").should eq 254
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should be_in(1..254)
  end

  it "moves to a level" do
    expect_success(device.invoke("levelcontrol", "move-to-level-with-on-off", ["200", "0", "0", "0"]))
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 200
    read_bool(device, "onoff", "on-off", "OnOff").should be_true
  end

  it "turns the light off when moved to the minimum level" do
    expect_success(device.invoke("levelcontrol", "move-to-level-with-on-off", ["1", "0", "0", "0"]))
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 1
    read_bool(device, "onoff", "on-off", "OnOff").should be_false
  end

  it "ignores ordinary level commands while off unless ExecuteIfOff is set" do
    # A preceding groupcast test may leave the default Options bit enabled.
    # Override it per command so this assertion is independent of test order.
    expect_success(device.invoke("levelcontrol", "move-to-level", ["255", "0", "1", "0"]))
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 1
    expect_success(device.invoke("levelcontrol", "move-to-level", ["255", "0", "1", "1"]))
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 254
    read_bool(device, "onoff", "on-off", "OnOff").should be_false
  end

  it "writes the OnLevel attribute" do
    expect_success(device.write("levelcontrol", "on-level", 100))
    read_int(device, "levelcontrol", "on-level", "OnLevel").should eq 100
  end

  it "uses OnLevel when an On command turns the light on" do
    expect_success(device.invoke("onoff", "off"))
    expect_success(device.invoke("onoff", "on"))
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 100
  end

  it "toggles on/off" do
    before = read_bool(device, "onoff", "on-off", "OnOff")
    expect_success(device.invoke("onoff", "toggle"))
    read_bool(device, "onoff", "on-off", "OnOff").should eq !before
  end

  it "adds, views, lists and removes a group using Matter command structures" do
    group = LevelControlE2E::GROUP_ID.to_s
    added = expect_success(device.invoke("groups", "add-group", [group, LevelControlE2E::GROUP_NAME]))
    added.int("groupID").should eq(LevelControlE2E::GROUP_ID), added.output
    viewed = expect_success(device.invoke("groups", "view-group", [group]))
    viewed.value("groupName").should eq(LevelControlE2E::GROUP_NAME), viewed.output
    listed = expect_success(device.invoke("groups", "get-group-membership", ["[#{group}]"]))
    listed.int_list("groupList").should contain(LevelControlE2E::GROUP_ID.to_i64)
    removed = expect_success(device.invoke("groups", "remove-group", [group]))
    removed.int("groupID").should eq(LevelControlE2E::GROUP_ID), removed.output
    listed = expect_success(device.invoke("groups", "get-group-membership", ["[]"]))
    listed.int_list("groupList").should_not contain(LevelControlE2E::GROUP_ID.to_i64)
  end

  it "moves color hue and temperature using standard chip-tool requests" do
    endpoint = LevelControlE2E::COLOR_ENDPOINT
    expect_success(device.invoke("onoff", "on", endpoint: endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      LevelControlE2E::TARGET_HUE.to_s,
      LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS,
      LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "current-hue", "CurrentHue", endpoint).should eq LevelControlE2E::TARGET_HUE
    expect_success(device.invoke("colorcontrol", "move-to-color-temperature", [
      LevelControlE2E::COLOR_TEMPERATURE.to_s,
      LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS,
      LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "color-temperature-mireds", "ColorTemperatureMireds", endpoint).should eq LevelControlE2E::COLOR_TEMPERATURE
    expect_success(device.write("colorcontrol", "options", LevelControlE2E::COLOR_OPTIONS, endpoint))
    read_int(device, "colorcontrol", "options", "Options", endpoint).should eq LevelControlE2E::COLOR_OPTIONS
  end

  it "couples level changes to color temperature with effective command options" do
    endpoint = LevelControlE2E::COLOR_ENDPOINT
    expect_success(device.invoke("onoff", "on", endpoint: endpoint))
    expect_success(device.write("levelcontrol", "options", LevelControlE2E::COUPLE_COLOR_OPTION, endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-color-temperature", [
      LevelControlE2E::COLOR_TEMPERATURE.to_s, LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "couple-color-temp-to-level-min-mireds", "CoupleColorTempToLevelMinMireds", endpoint)
      .should eq LevelControlE2E::COUPLED_TEMPERATURE_MIN

    expect_success(device.invoke("levelcontrol", "move-to-level-with-on-off", [
      LevelControlE2E::LEVEL_MINIMUM.to_s, LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "color-temperature-mireds", "ColorTemperatureMireds", endpoint)
      .should eq LevelControlE2E::PHYSICAL_TEMPERATURE_MAX

    expect_success(device.invoke("levelcontrol", "move-to-level-with-on-off", [
      LevelControlE2E::LEVEL_MAXIMUM.to_s, LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::COUPLE_COLOR_OPTION.to_s, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "color-temperature-mireds", "ColorTemperatureMireds", endpoint)
      .should eq LevelControlE2E::PHYSICAL_TEMPERATURE_MAX

    expect_success(device.invoke("levelcontrol", "move-to-level-with-on-off", [
      LevelControlE2E::LEVEL_MIDPOINT.to_s, LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::COUPLE_COLOR_OPTION.to_s, LevelControlE2E::COUPLE_COLOR_OPTION.to_s,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "color-temperature-mireds", "ColorTemperatureMireds", endpoint)
      .should eq LevelControlE2E::COUPLED_MIDPOINT_TEMPERATURE
  end

  it "advertises Color Control revision 9 and restores startup temperature" do
    endpoint = LevelControlE2E::COLOR_ENDPOINT
    read_int(device, "colorcontrol", "cluster-revision", "ClusterRevision", endpoint).should eq 9
    read_value(device, "colorcontrol", "number-of-primaries", "NumberOfPrimaries", endpoint).should eq "null"
    read_int(device, "colorcontrol", "couple-color-temp-to-level-min-mireds", "CoupleColorTempToLevelMinMireds", endpoint)
      .should eq LevelControlE2E::COUPLED_TEMPERATURE_MIN

    expect_failure(device.write("colorcontrol", "start-up-color-temperature-mireds", 0, endpoint), "CONSTRAINT_ERROR")
    expect_success(device.write("colorcontrol", "start-up-color-temperature-mireds", LevelControlE2E::STARTUP_COLOR_TEMPERATURE, endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-color-temperature", [
      LevelControlE2E::START_COLOR_TEMPERATURE.to_s, LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "color-temperature-mireds", "ColorTemperatureMireds", endpoint)
      .should eq LevelControlE2E::START_COLOR_TEMPERATURE

    device.restart!

    read_int(device, "colorcontrol", "start-up-color-temperature-mireds", "StartUpColorTemperatureMireds", endpoint)
      .should eq LevelControlE2E::STARTUP_COLOR_TEMPERATURE
    read_int(device, "colorcontrol", "color-temperature-mireds", "ColorTemperatureMireds", endpoint)
      .should eq LevelControlE2E::STARTUP_COLOR_TEMPERATURE
    read_int(device, "colorcontrol", "color-mode", "ColorMode", endpoint).should eq LevelControlE2E::TEMPERATURE_MODE
    read_int(device, "colorcontrol", "enhanced-color-mode", "EnhancedColorMode", endpoint).should eq LevelControlE2E::TEMPERATURE_MODE
  end

  it "switches ColorMode on a same-value command and at the start of a timed transition" do
    endpoint = LevelControlE2E::COLOR_ENDPOINT
    expect_success(device.invoke("onoff", "on", endpoint: endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      LevelControlE2E::TARGET_HUE.to_s, LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::NO_TRANSITION, LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-color-temperature", [
      LevelControlE2E::START_COLOR_TEMPERATURE.to_s, LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      LevelControlE2E::TARGET_HUE.to_s, LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::NO_TRANSITION, LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "color-mode", "ColorMode", endpoint).should eq LevelControlE2E::HUE_MODE

    expect_success(device.invoke("colorcontrol", "move-to-color-temperature", [
      LevelControlE2E::COLOR_TEMPERATURE.to_s, LevelControlE2E::TIMED_TRANSITION,
      LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "remaining-time", "RemainingTime", endpoint).should be > 0
    read_int(device, "colorcontrol", "color-mode", "ColorMode", endpoint).should eq LevelControlE2E::TEMPERATURE_MODE
    read_int(device, "colorcontrol", "enhanced-color-mode", "EnhancedColorMode", endpoint).should eq LevelControlE2E::TEMPERATURE_MODE
  end

  it "moves color hue over the requested five seconds" do
    endpoint = LevelControlE2E::COLOR_ENDPOINT
    expect_success(device.invoke("onoff", "on", endpoint: endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      "10", LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::NO_TRANSITION, LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      "110", LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::TIMED_TRANSITION, LevelControlE2E::NO_OPTIONS, LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "remaining-time", "RemainingTime", endpoint).should be > 0
    read_int(device, "colorcontrol", "current-hue", "CurrentHue", endpoint).should be < 110
    sleep 5.seconds
    read_int(device, "colorcontrol", "current-hue", "CurrentHue", endpoint).should eq 110
    read_int(device, "colorcontrol", "remaining-time", "RemainingTime", endpoint).should eq 0
  end

  it "applies Color Control ExecuteIfOff overrides on an off light" do
    endpoint = LevelControlE2E::COLOR_ENDPOINT
    expect_success(device.invoke("onoff", "on", endpoint: endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      LevelControlE2E::TARGET_HUE.to_s,
      LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS,
      LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    expect_success(device.invoke("onoff", "off", endpoint: endpoint))
    expect_success(device.write("colorcontrol", "options", LevelControlE2E::COLOR_OPTIONS_CLEAR, endpoint))
    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      LevelControlE2E::OFF_TARGET_HUE.to_s,
      LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::NO_OPTIONS,
      LevelControlE2E::NO_OPTIONS,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "current-hue", "CurrentHue", endpoint).should eq LevelControlE2E::TARGET_HUE

    expect_success(device.invoke("colorcontrol", "move-to-hue", [
      LevelControlE2E::OFF_TARGET_HUE.to_s,
      LevelControlE2E::SHORTEST_HUE_DIRECTION,
      LevelControlE2E::NO_TRANSITION,
      LevelControlE2E::EXECUTE_IF_OFF.to_s,
      LevelControlE2E::EXECUTE_IF_OFF.to_s,
    ], endpoint: endpoint))
    read_int(device, "colorcontrol", "current-hue", "CurrentHue", endpoint).should eq LevelControlE2E::OFF_TARGET_HUE
    read_bool(device, "onoff", "on-off", "OnOff", endpoint).should be_false
  end

  it "moves the window lift and reads and writes its attributes" do
    endpoint = LevelControlE2E::COVERING_ENDPOINT
    read_int(device, "windowcovering", "current-position-lift-percent100ths", "CurrentPositionLiftPercent100ths", endpoint).should eq 0
    read_value(device, "windowcovering", "target-position-lift-percent100ths", "TargetPositionLiftPercent100ths", endpoint).should eq "null"
    expect_success(device.invoke("windowcovering", "go-to-lift-percentage", [LevelControlE2E::LIFT_POSITION.to_s], endpoint: endpoint))
    read_int(device, "windowcovering", "target-position-lift-percent100ths", "TargetPositionLiftPercent100ths", endpoint).should eq LevelControlE2E::LIFT_POSITION
    wait_for_covering_lift(device, LevelControlE2E::LIFT_POSITION, endpoint)
    read_int(device, "windowcovering", "operational-status", "OperationalStatus", endpoint).should eq LevelControlE2E::COVERING_STOPPED_STATUS

    expect_success(device.invoke("windowcovering", "down-or-close", endpoint: endpoint))
    expect_success(device.invoke("windowcovering", "stop-motion", endpoint: endpoint))
    sleep LevelControlE2E::COVERING_CANCELED_WAIT
    read_int(device, "windowcovering", "current-position-lift-percent100ths", "CurrentPositionLiftPercent100ths", endpoint).should eq LevelControlE2E::LIFT_POSITION
    read_int(device, "windowcovering", "target-position-lift-percent100ths", "TargetPositionLiftPercent100ths", endpoint).should eq LevelControlE2E::LIFT_POSITION
    expect_success(device.invoke("windowcovering", "up-or-open", endpoint: endpoint))
    wait_for_covering_lift(device, 0, endpoint)
    expect_success(device.write("windowcovering", "mode", LevelControlE2E::COVERING_MODE, endpoint))
    read_int(device, "windowcovering", "mode", "Mode", endpoint).should eq LevelControlE2E::COVERING_MODE
  end

  it "advertises revision 8 and honors Window Covering Mode across restart" do
    endpoint = LevelControlE2E::COVERING_ENDPOINT
    read_int(device, "windowcovering", "cluster-revision", "ClusterRevision", endpoint).should eq LevelControlE2E::COVERING_REVISION
    read_int(device, "windowcovering", "feature-map", "FeatureMap", endpoint).should eq 0x05
    commands = expect_success(device.read("windowcovering", "accepted-command-list", endpoint)).int_list("AcceptedCommandList")
    commands.should contain(0_i64)
    commands.should contain(1_i64)
    commands.should contain(2_i64)
    commands.should contain(5_i64)
    commands.should_not contain(4_i64)
    commands.should_not contain(7_i64)

    expect_success(device.write("windowcovering", "mode", LevelControlE2E::COVERING_MAINTENANCE, endpoint))
    expect_failure(device.invoke("windowcovering", "up-or-open", endpoint: endpoint), "BUSY")
    (read_int(device, "windowcovering", "config-status", "ConfigStatus", endpoint) & 0x01).should eq 0
    expect_success(device.write("windowcovering", "mode", LevelControlE2E::COVERING_CALIBRATION, endpoint))
    expect_failure(device.invoke("windowcovering", "go-to-lift-percentage", ["2500"], endpoint: endpoint), "FAILURE")
    expect_success(device.write("windowcovering", "mode", LevelControlE2E::COVERING_REVERSED, endpoint))
    (read_int(device, "windowcovering", "config-status", "ConfigStatus", endpoint) & 0x05).should eq 0x05
    expect_success(device.invoke("windowcovering", "go-to-lift-percentage", ["2500"], endpoint: endpoint))
    read_int(device, "windowcovering", "target-position-lift-percent100ths", "TargetPositionLiftPercent100ths", endpoint).should eq 2_500

    device.restart!
    read_int(device, "windowcovering", "mode", "Mode", endpoint).should eq LevelControlE2E::COVERING_REVERSED
    (read_int(device, "windowcovering", "config-status", "ConfigStatus", endpoint) & 0x05).should eq 0x05
  end

  it "applies StartUpCurrentLevel after an ordinary device restart" do
    expect_success(device.write("levelcontrol", "start-up-current-level", 42))
    expect_success(device.invoke("levelcontrol", "move-to-level-with-on-off", ["80", "0", "0", "0"]))
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 80

    device.restart!

    device.operational?.should be_true
    read_int(device, "levelcontrol", "start-up-current-level", "StartUpCurrentLevel").should eq 42
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 42
  end

  it "advertises all mandatory commands and resets volatile settings after restart" do
    expect_success(device.read("levelcontrol", "accepted-command-list"))
      .int_list("AcceptedCommandList").should eq((0_i64..7_i64).to_a)
    expect_success(device.write("levelcontrol", "options", 1))
    expect_success(device.write("levelcontrol", "on-level", 100))
    expect_success(device.write("levelcontrol", "on-off-transition-time", 3))
    expect_success(device.write("levelcontrol", "start-up-current-level", 50))
    expect_success(device.invoke("levelcontrol", "move-to-level-with-on-off", ["80", "0", "0", "0"]))

    device.restart!

    read_int(device, "levelcontrol", "start-up-current-level", "StartUpCurrentLevel").should eq 50
    read_int(device, "levelcontrol", "current-level", "CurrentLevel").should eq 50
    read_int(device, "levelcontrol", "options", "Options").should eq 0
    read_int(device, "levelcontrol", "on-off-transition-time", "OnOffTransitionTime").should eq 0
    read_value(device, "levelcontrol", "on-level", "OnLevel").should eq "null"
  end
end
