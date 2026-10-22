require "../spec_helper"

describe Matter::Cluster::FanControl do
  describe "initialization" do
    it "creates with default values (off)" do
      cluster = build(Matter::Cluster::FanControl)
      cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
      cluster.fan_mode_sequence.should eq(Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh)
      cluster.percent_setting.should eq(0_u8)
      cluster.percent_current.should eq(0_u8)
    end

    it "creates with custom values" do
      cluster = build(Matter::Cluster::FanControl,
        fan_mode: Matter::Cluster::FanControl::FanMode::High,
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowHigh,
        percent_setting: 75_u8,
        percent_current: 75_u8
      )
      cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::High)
      cluster.fan_mode_sequence.should eq(Matter::Cluster::FanControl::FanModeSequence::OffLowHigh)
      cluster.percent_setting.should eq(75_u8)
      cluster.percent_current.should eq(75_u8)
    end

    it "creates with OffLowMedHighAuto sequence" do
      cluster = build(Matter::Cluster::FanControl,
        feature_map: Matter::Cluster::FanControl::Feature::Auto,
        fan_mode: Matter::Cluster::FanControl::FanMode::Auto,
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHighAuto
      )
      cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Auto)
      cluster.fan_mode_sequence.should eq(Matter::Cluster::FanControl::FanModeSequence::OffLowMedHighAuto)
    end

    it "validates percent_setting range" do
      expect_raises(ArgumentError, /percent_setting must be between 0 and 100/) do
        build(Matter::Cluster::FanControl,
          percent_setting: 101_u8
        )
      end
    end

    it "validates percent_current range" do
      expect_raises(ArgumentError, /percent_current must be between 0 and 100/) do
        build(Matter::Cluster::FanControl,
          percent_current: 101_u8
        )
      end
    end

    it "bounds SpeedMax to the Matter 1.6 range" do
      expect_raises(ArgumentError, /speed_max/) do
        build(Matter::Cluster::FanControl, speed_max: 101_u8)
      end
    end

    it "validates fan mode is supported by sequence" do
      expect_raises(ArgumentError, /FanMode Medium not supported/) do
        build(Matter::Cluster::FanControl,
          fan_mode: Matter::Cluster::FanControl::FanMode::Medium,
          fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowHigh
        )
      end
    end

    it "allows Off mode for all sequences" do
      sequences = [
        Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh,
        Matter::Cluster::FanControl::FanModeSequence::OffLowHigh,
        Matter::Cluster::FanControl::FanModeSequence::OffLowMedHighAuto,
        Matter::Cluster::FanControl::FanModeSequence::OffLowHighAuto,
        Matter::Cluster::FanControl::FanModeSequence::OffHighAuto,
        Matter::Cluster::FanControl::FanModeSequence::OffHigh,
      ]

      sequences.each do |sequence|
        cluster = build(Matter::Cluster::FanControl,
          feature_map: sequence.in?(Matter::Cluster::FanControl::FanModeSequence::OffLowMedHighAuto,
            Matter::Cluster::FanControl::FanModeSequence::OffLowHighAuto,
            Matter::Cluster::FanControl::FanModeSequence::OffHighAuto) ? Matter::Cluster::FanControl::Feature::Auto : Matter::Cluster::FanControl::Feature::None,
          fan_mode: Matter::Cluster::FanControl::FanMode::Off,
          fan_mode_sequence: sequence
        )
        cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
      end
    end

    it "exposes only mandatory attributes when no optional feature is selected" do
      cluster = build(Matter::Cluster::FanControl,
        feature_map: Matter::Cluster::FanControl::Feature::None)

      cluster.feature_map.should eq(Matter::Cluster::FanControl::Feature::None)
      cluster.attributes.map(&.id.id).should_not contain(Matter::Cluster::FanControl::ATTR_SPEED_MAX)
      cluster.attributes.map(&.id.id).should_not contain(Matter::Cluster::FanControl::ATTR_SPEED_SETTING)
      cluster.attributes.map(&.id.id).should_not contain(Matter::Cluster::FanControl::ATTR_SPEED_CURRENT)
      read_status(cluster, Matter::Cluster::FanControl::ATTR_SPEED_MAX).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)

      expect_status(write(cluster, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 40_u8),
        Matter::InteractionModel::StatusCode::Success)
      cluster.percent_current.should eq(40_u8)
    end

    it "keeps the default multi-speed feature for existing configurations" do
      cluster = build(Matter::Cluster::FanControl)
      cluster.feature_map.multi_speed?.should be_true
      cluster.attributes.map(&.id.id).should contain(Matter::Cluster::FanControl::ATTR_SPEED_MAX)
    end

    it "requires AUT for an Auto sequence and forbids an Auto-less sequence with AUT" do
      expect_raises(ArgumentError, /Auto.*feature|feature.*Auto/) do
        build(Matter::Cluster::FanControl,
          fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHighAuto)
      end
      expect_raises(ArgumentError, /Auto.*feature|feature.*Auto/) do
        build(Matter::Cluster::FanControl,
          feature_map: Matter::Cluster::FanControl::Feature::Auto,
          fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh)
      end
    end

    it "requires a nonempty supported movement map for RCK and WND" do
      expect_raises(ArgumentError, /rock_support/) do
        build(Matter::Cluster::FanControl,
          feature_map: Matter::Cluster::FanControl::Feature::Rocking)
      end
      expect_raises(ArgumentError, /wind_support/) do
        build(Matter::Cluster::FanControl,
          feature_map: Matter::Cluster::FanControl::Feature::Wind)
      end
    end

    it "rejects reserved movement bits on the wire" do
      rock = build(Matter::Cluster::FanControl,
        feature_map: Matter::Cluster::FanControl::Feature::Rocking,
        rock_support: Matter::Cluster::FanControl::RockSupport::RockLeftRight)
      wind = build(Matter::Cluster::FanControl,
        feature_map: Matter::Cluster::FanControl::Feature::Wind,
        wind_support: Matter::Cluster::FanControl::WindSupport::SleepWind)

      expect_status(write(rock, Matter::Cluster::FanControl::ATTR_ROCK_SETTING, 0x80_u8),
        Matter::InteractionModel::StatusCode::ConstraintError)
      expect_status(write(wind, Matter::Cluster::FanControl::ATTR_WIND_SETTING, 0x80_u8),
        Matter::InteractionModel::StatusCode::ConstraintError)
      rock.rock_setting.should eq(Matter::Cluster::FanControl::RockSupport::None)
      wind.wind_setting.should eq(Matter::Cluster::FanControl::WindSupport::None)
    end

    it "rejects initial rocking and wind settings outside the supported maps" do
      expect_raises(ArgumentError, /rock_setting/) do
        build(Matter::Cluster::FanControl,
          feature_map: Matter::Cluster::FanControl::Feature::Rocking,
          rock_support: Matter::Cluster::FanControl::RockSupport::RockLeftRight,
          rock_setting: Matter::Cluster::FanControl::RockSupport::RockUpDown)
      end
      expect_raises(ArgumentError, /wind_setting/) do
        build(Matter::Cluster::FanControl,
          feature_map: Matter::Cluster::FanControl::Feature::Wind,
          wind_support: Matter::Cluster::FanControl::WindSupport::SleepWind,
          wind_setting: Matter::Cluster::FanControl::WindSupport::NaturalWind)
      end
    end
  end

  describe "attributes" do
    it "has required attributes including speed" do
      cluster = build(Matter::Cluster::FanControl)
      attrs = cluster.attributes
      attrs.size.should eq(7)
      attrs.map(&.name).should contain("fanMode")
      attrs.map(&.name).should contain("fanModeSequence")
      attrs.map(&.name).should contain("percentSetting")
      attrs.map(&.name).should contain("percentCurrent")
      attrs.map(&.name).should contain("speedMax")
      attrs.map(&.name).should contain("speedSetting")
      attrs.map(&.name).should contain("speedCurrent")
    end

    it "reads FanMode" do
      cluster = build(Matter::Cluster::FanControl,
        fan_mode: Matter::Cluster::FanControl::FanMode::High
      )
      read(cluster, Matter::Cluster::FanControl::ATTR_FAN_MODE).should eq(3_u8) # High = 3
    end

    it "reads FanModeSequence" do
      cluster = build(Matter::Cluster::FanControl,
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowHigh
      )
      read(cluster, Matter::Cluster::FanControl::ATTR_FAN_MODE_SEQUENCE).should eq(1_u8) # OffLowHigh = 1
    end

    it "reads PercentSetting" do
      cluster = build(Matter::Cluster::FanControl,
        percent_setting: 50_u8
      )
      read(cluster, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING).should eq(50_u8)
    end

    it "reads PercentCurrent" do
      cluster = build(Matter::Cluster::FanControl,
        percent_current: 75_u8
      )
      read(cluster, Matter::Cluster::FanControl::ATTR_PERCENT_CURRENT).should eq(75_u8)
    end

    it "marks fanMode as writable" do
      cluster = build(Matter::Cluster::FanControl)
      attr = cluster.attributes.find { |attribute| attribute.name == "fanMode" }
      attr.should_not be_nil
      attr.as(Matter::Cluster::AttributeMetadata).writable?.should be_true
    end

    it "marks percentSetting as writable" do
      cluster = build(Matter::Cluster::FanControl)
      attr = cluster.attributes.find { |attribute| attribute.name == "percentSetting" }
      attr.should_not be_nil
      attr.as(Matter::Cluster::AttributeMetadata).writable?.should be_true
    end
  end

  describe "write_attribute" do
    describe "FanMode" do
      it "writes valid fan mode" do
        cluster = build(Matter::Cluster::FanControl,
          fan_mode: Matter::Cluster::FanControl::FanMode::Off
        )

        status = write(cluster,
          Matter::Cluster::FanControl::ATTR_FAN_MODE,
          1_u8 # Low
        )
        status.should be_a(Matter::InteractionModel::Status)
        status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Success)
        cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Low)
      end

      it "rejects unsupported fan mode for sequence" do
        cluster = build(Matter::Cluster::FanControl,
          fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowHigh
        )

        status = write(cluster,
          Matter::Cluster::FanControl::ATTR_FAN_MODE,
          2_u8 # Medium - not supported
        )
        status.should be_a(Matter::InteractionModel::Status)
        status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
        cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off) # Unchanged
      end

      it "rejects invalid fan mode value" do
        cluster = build(Matter::Cluster::FanControl)

        status = write(cluster,
          Matter::Cluster::FanControl::ATTR_FAN_MODE,
          7_u8 # Invalid value
        )
        status.should be_a(Matter::InteractionModel::Status)
        status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
      end

      it "sets percent to 0 when fan mode changes to Off" do
        cluster = build(Matter::Cluster::FanControl,
          fan_mode: Matter::Cluster::FanControl::FanMode::High,
          percent_setting: 75_u8,
          percent_current: 75_u8
        )

        write(cluster,
          Matter::Cluster::FanControl::ATTR_FAN_MODE,
          0_u8 # Off
        )
        cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
        cluster.percent_setting.should eq(0_u8)
        cluster.percent_current.should eq(0_u8)
      end

      it "calls callback when fan mode changes" do
        cluster = build(Matter::Cluster::FanControl,
          fan_mode: Matter::Cluster::FanControl::FanMode::Off
        )

        old_mode = nil.as(Matter::Cluster::FanControl::FanMode?)
        new_mode = nil.as(Matter::Cluster::FanControl::FanMode?)
        cluster.on_fan_mode_changed do |old, new|
          old_mode = old
          new_mode = new
        end

        write(cluster,
          Matter::Cluster::FanControl::ATTR_FAN_MODE,
          1_u8 # Low
        )
        old_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
        new_mode.should eq(Matter::Cluster::FanControl::FanMode::Low)
      end
    end

    describe "PercentSetting" do
      it "writes valid percent setting" do
        cluster = build(Matter::Cluster::FanControl)

        status = write(cluster,
          Matter::Cluster::FanControl::ATTR_PERCENT_SETTING,
          50_u8
        )
        status.should be_a(Matter::InteractionModel::Status)
        status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Success)
        cluster.percent_setting.should eq(50_u8)
        cluster.percent_current.should eq(50_u8)
      end

      it "rejects percent setting > 100" do
        cluster = build(Matter::Cluster::FanControl)

        status = write(cluster,
          Matter::Cluster::FanControl::ATTR_PERCENT_SETTING,
          101_u8
        )
        status.should be_a(Matter::InteractionModel::Status)
        status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
      end

      it "sets fan mode to Off when percent is 0" do
        cluster = build(Matter::Cluster::FanControl,
          fan_mode: Matter::Cluster::FanControl::FanMode::High,
          percent_setting: 75_u8
        )

        write(cluster,
          Matter::Cluster::FanControl::ATTR_PERCENT_SETTING,
          0_u8
        )
        cluster.percent_setting.should eq(0_u8)
        cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
      end

      it "turns fan on when setting non-zero percent from Off" do
        cluster = build(Matter::Cluster::FanControl,
          fan_mode: Matter::Cluster::FanControl::FanMode::Off
        )

        write(cluster,
          Matter::Cluster::FanControl::ATTR_PERCENT_SETTING,
          50_u8
        )
        cluster.percent_setting.should eq(50_u8)
        cluster.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Low)
      end

      it "calls callback when percent changes" do
        cluster = build(Matter::Cluster::FanControl)

        old_percent = nil.as(UInt8??)
        new_percent = nil.as(UInt8?)
        cluster.on_percent_changed do |old, new|
          old_percent = old
          new_percent = new
        end

        write(cluster,
          Matter::Cluster::FanControl::ATTR_PERCENT_SETTING,
          50_u8
        )
        old_percent.should eq(0_u8)
        new_percent.should eq(50_u8)
      end
    end

    it "returns error for read-only attributes" do
      cluster = build(Matter::Cluster::FanControl)
      status = write(cluster,
        Matter::Cluster::FanControl::ATTR_FAN_MODE_SEQUENCE,
        1_u8
      )
      status.should be_a(Matter::InteractionModel::Status)
      status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end

    it "returns error for unsupported attributes" do
      cluster = build(Matter::Cluster::FanControl)
      status = write(cluster, 0x9999_u32, 1_u8)
      status.should be_a(Matter::InteractionModel::Status)
      status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "update_percent_current" do
    it "updates percent current" do
      cluster = build(Matter::Cluster::FanControl)
      cluster.update_percent_current(75_u8)
      cluster.percent_current.should eq(75_u8)
    end

    it "validates range" do
      cluster = build(Matter::Cluster::FanControl)
      expect_raises(ArgumentError, /percent_current must be between 0 and 100/) do
        cluster.update_percent_current(101_u8)
      end
    end

    it "increments data version on change" do
      cluster = build(Matter::Cluster::FanControl)
      initial_version = cluster.data_version
      cluster.update_percent_current(50_u8)
      cluster.data_version.should eq(initial_version + 1)
    end

    it "doesn't increment version if value unchanged" do
      cluster = build(Matter::Cluster::FanControl,
        percent_current: 50_u8
      )
      initial_version = cluster.data_version
      cluster.update_percent_current(50_u8)
      cluster.data_version.should eq(initial_version)
    end
  end

  describe "practical scenarios" do
    it "models a basic ceiling fan with three speeds" do
      # Ceiling fan with Off, Low, Medium, High
      fan = build(Matter::Cluster::FanControl,
        fan_mode: Matter::Cluster::FanControl::FanMode::Off,
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh
      )

      # Turn on to low speed
      write(fan,
        Matter::Cluster::FanControl::ATTR_FAN_MODE,
        1_u8 # Low
      )
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Low)

      # Increase to medium
      write(fan,
        Matter::Cluster::FanControl::ATTR_FAN_MODE,
        2_u8 # Medium
      )
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Medium)

      # Increase to high
      write(fan,
        Matter::Cluster::FanControl::ATTR_FAN_MODE,
        3_u8 # High
      )
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::High)

      # Turn off
      write(fan,
        Matter::Cluster::FanControl::ATTR_FAN_MODE,
        0_u8 # Off
      )
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
    end

    it "models a simple two-speed fan" do
      # Fan with Off, Low, High only
      fan = build(Matter::Cluster::FanControl,
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowHigh
      )

      # Can use Low and High
      write(fan, Matter::Cluster::FanControl::ATTR_FAN_MODE, 1_u8) # Low
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Low)

      write(fan, Matter::Cluster::FanControl::ATTR_FAN_MODE, 3_u8) # High
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::High)

      # Cannot use Medium
      status = write(fan, Matter::Cluster::FanControl::ATTR_FAN_MODE, 2_u8)
      status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end

    it "models a smart fan with automatic mode" do
      # Fan with Auto mode support
      fan = build(Matter::Cluster::FanControl,
        feature_map: Matter::Cluster::FanControl::Feature::Auto,
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHighAuto
      )

      # Set to Auto mode
      write(fan,
        Matter::Cluster::FanControl::ATTR_FAN_MODE,
        5_u8 # Auto
      )
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Auto)
    end

    it "syncs speed and percent when writing percent" do
      fan = build(Matter::Cluster::FanControl,
        speed_max: 4_u8
      )

      write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 50_u8)
      fan.percent_setting.should eq(50_u8)
      fan.speed_setting.should eq(2_u8)
      fan.speed_current.should eq(2_u8)

      write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 100_u8)
      fan.speed_setting.should eq(4_u8)
    end

    it "syncs percent and speed when writing speed" do
      fan = build(Matter::Cluster::FanControl,
        speed_max: 4_u8
      )

      write(fan, Matter::Cluster::FanControl::ATTR_SPEED_SETTING, 3_u8)
      fan.speed_setting.should eq(3_u8)
      fan.percent_setting.should eq(75_u8)
      fan.percent_current.should eq(75_u8)

      write(fan, Matter::Cluster::FanControl::ATTR_SPEED_SETTING, 0_u8)
      fan.percent_setting.should eq(0_u8)
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
    end

    it "fires percent callback when speed is written" do
      fan = build(Matter::Cluster::FanControl,
        speed_max: 4_u8
      )

      received_percent = nil.as(UInt8?)
      fan.on_percent_changed do |_old, new_val|
        received_percent = new_val
      end

      write(fan, Matter::Cluster::FanControl::ATTR_SPEED_SETTING, 2_u8)
      received_percent.should eq(50_u8)
    end

    it "fires speed callback when percent is written" do
      fan = build(Matter::Cluster::FanControl,
        speed_max: 4_u8
      )

      received_speed = nil.as(UInt8?)
      fan.on_speed_changed do |_old, new_val|
        received_speed = new_val
      end

      write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 75_u8)
      received_speed.should eq(3_u8)
    end

    it "models percent-based speed control" do
      # Fan controlled by percentage
      fan = build(Matter::Cluster::FanControl)

      # Set to 25% speed
      write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 25_u8)
      fan.percent_setting.should eq(25_u8)
      fan.percent_current.should eq(25_u8)

      # Increase to 75%
      write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 75_u8)
      fan.percent_setting.should eq(75_u8)

      # Turn off via percent
      write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 0_u8)
      fan.percent_setting.should eq(0_u8)
      fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
    end

    it "tracks state changes with callbacks" do
      fan = build(Matter::Cluster::FanControl)

      mode_changes = [] of String
      fan.on_fan_mode_changed do |old, new|
        mode_changes << "#{old} -> #{new}"
      end

      percent_changes = [] of String
      fan.on_percent_changed do |old, new|
        percent_changes << "#{old} -> #{new}"
      end

      # Multiple state changes
      write(fan, Matter::Cluster::FanControl::ATTR_FAN_MODE, 1_u8) # Low
      write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 50_u8)
      write(fan, Matter::Cluster::FanControl::ATTR_FAN_MODE, 3_u8) # High
      write(fan, Matter::Cluster::FanControl::ATTR_FAN_MODE, 0_u8) # Off

      mode_changes.should eq([
        "Off -> Low",
        "Low -> High",
        "High -> Off",
      ])

      percent_changes.size.should eq(2)
    end

    it "models an air purifier with fan control" do
      # Air purifier from the behavioral test
      air_purifier = build(Matter::Cluster::FanControl,
        fan_mode: Matter::Cluster::FanControl::FanMode::On, # Deprecated but supported
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh,
        percent_setting: 50_u8,
        percent_current: 50_u8
      )

      air_purifier.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::On)
      air_purifier.percent_setting.should eq(50_u8)
      air_purifier.percent_current.should eq(50_u8)
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute reads" do
      cluster = build(Matter::Cluster::FanControl)
      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end
end
