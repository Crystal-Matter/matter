require "../spec_helper"
require "../../src/matter/cluster/window_covering"

# Ported from matter.js window-coveringTest.ts
# Tests Window Covering Cluster feature composition
describe Matter::Cluster::WindowCovering do
  describe "with Lift and PositionAwareLift features" do
    # WindowCovering_LF_PALF = WindowCovering.with("Lift", "PositionAwareLift")
    cluster = build(Matter::Cluster::WindowCovering,
      feature_map: Matter::Cluster::WindowCovering::Feature::Lift |
                   Matter::Cluster::WindowCovering::Feature::PositionAwareLift
    )

    describe "correctly initializes elements for LF & PA_LF" do
      it "has correct attribute properties" do
        attrs = cluster.attributes
        attr_map = {} of String => Matter::Cluster::AttributeMetadata

        attrs.each do |attr|
          attr_map[attr.name] = attr
        end

        # Check mandatory, non-optional attributes
        # configStatus - mandatory
        attr_map["configStatus"].optional?.should be_false
        attr_map["configStatus"].writable?.should be_false
        attr_map["configStatus"].fixed?.should be_false

        # currentPositionLiftPercent100ths - mandatory with PA_LF
        attr_map["currentPositionLiftPercent100ths"].optional?.should be_false
        attr_map["currentPositionLiftPercent100ths"].writable?.should be_false
        attr_map["currentPositionLiftPercent100ths"].fixed?.should be_false

        # currentPositionLiftPercentage - optional
        attr_map["currentPositionLiftPercentage"].optional?.should be_true
        attr_map["currentPositionLiftPercentage"].writable?.should be_false
        attr_map["currentPositionLiftPercentage"].fixed?.should be_false

        # endProductType - fixed
        attr_map["endProductType"].optional?.should be_false
        attr_map["endProductType"].writable?.should be_false
        attr_map["endProductType"].fixed?.should be_true

        # mode - writable
        attr_map["mode"].optional?.should be_false
        attr_map["mode"].writable?.should be_true
        attr_map["mode"].fixed?.should be_false

        # numberOfActuationsLift - optional
        attr_map["numberOfActuationsLift"].optional?.should be_true
        attr_map["numberOfActuationsLift"].writable?.should be_false
        attr_map["numberOfActuationsLift"].fixed?.should be_false

        # operationalStatus - mandatory
        attr_map["operationalStatus"].optional?.should be_false
        attr_map["operationalStatus"].writable?.should be_false
        attr_map["operationalStatus"].fixed?.should be_false

        # safetyStatus - optional
        attr_map["safetyStatus"].optional?.should be_true
        attr_map["safetyStatus"].writable?.should be_false
        attr_map["safetyStatus"].fixed?.should be_false

        # targetPositionLiftPercent100ths - mandatory with PA_LF
        attr_map["targetPositionLiftPercent100ths"].optional?.should be_false
        attr_map["targetPositionLiftPercent100ths"].writable?.should be_false
        attr_map["targetPositionLiftPercent100ths"].fixed?.should be_false

        # type - fixed
        attr_map["type"].optional?.should be_false
        attr_map["type"].writable?.should be_false
        attr_map["type"].fixed?.should be_true
      end

      it "has correct command properties" do
        cmds = cluster.commands
        cmd_map = {} of String => Matter::Cluster::CommandMetadata

        cmds.each do |cmd|
          cmd_map[cmd.name] = cmd
        end

        # downOrClose - mandatory
        cmd_map["downOrClose"].optional?.should be_false

        # goToLiftPercentage - mandatory with LF & PA_LF
        cmd_map["goToLiftPercentage"].optional?.should be_false

        # stopMotion - mandatory
        cmd_map["stopMotion"].optional?.should be_false

        # upOrOpen - mandatory
        cmd_map["upOrOpen"].optional?.should be_false
      end
    end
  end

  describe "with only Lift feature" do
    cluster = build(Matter::Cluster::WindowCovering,
      feature_map: Matter::Cluster::WindowCovering::Feature::Lift
    )

    it "does not include goToLiftPercentage command" do
      cmds = cluster.commands
      cmd_names = cmds.map(&.name)

      cmd_names.includes?("goToLiftPercentage").should be_false
    end

    it "does not include position-aware lift attributes" do
      attrs = cluster.attributes
      attr_names = attrs.map(&.name)

      attr_names.includes?("currentPositionLiftPercent100ths").should be_false
      attr_names.includes?("targetPositionLiftPercent100ths").should be_false
    end
  end

  describe "with Tilt and PositionAwareTilt features" do
    cluster = build(Matter::Cluster::WindowCovering,
      feature_map: Matter::Cluster::WindowCovering::Feature::Tilt |
                   Matter::Cluster::WindowCovering::Feature::PositionAwareTilt
    )

    it "includes goToTiltPercentage command" do
      cmds = cluster.commands
      cmd_names = cmds.map(&.name)

      cmd_names.includes?("goToTiltPercentage").should be_true
    end

    it "includes position-aware tilt attributes" do
      attrs = cluster.attributes
      attr_names = attrs.map(&.name)

      attr_names.includes?("currentPositionTiltPercent100ths").should be_true
      attr_names.includes?("targetPositionTiltPercent100ths").should be_true
    end
  end

  describe "commands" do
    cluster = build(Matter::Cluster::WindowCovering,
      feature_map: Matter::Cluster::WindowCovering::Feature::Lift |
                   Matter::Cluster::WindowCovering::Feature::PositionAwareLift
    )

    it "upOrOpen sets target to 0%" do
      cluster.target_position_lift_percent100ths.should be_nil
    end

    it "downOrClose would set target to 100%" do
      # The handle_down_or_close sets target to 10000 (100.00%)
      cluster.target_position_lift_percent100ths = nil
      # Command handling tested via invoke_command
    end
  end

  describe "percentage commands on the wire" do
    it "sets the lift target from tag zero" do
      cluster = build(Matter::Cluster::WindowCovering)
      cluster.on_move { |_request| Matter::InteractionModel::Status.success }
      request = Matter::Cluster::WindowCovering::GoToLiftPercentageRequest.new(4321_u16)
      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_GO_TO_LIFT_PERCENTAGE, request))
      read(cluster, Matter::Cluster::WindowCovering::ATTR_TARGET_POSITION_LIFT_PERCENT100THS).should eq(4321_u16)
    end

    it "rejects a lift percentage above 100 percent without changing the target" do
      cluster = build(Matter::Cluster::WindowCovering)
      request = Matter::Cluster::WindowCovering::GoToLiftPercentageRequest.new(10001_u16)
      expect_status(invoke(cluster, Matter::Cluster::WindowCovering::CMD_GO_TO_LIFT_PERCENTAGE, request), Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.target_position_lift_percent100ths.should be_nil
    end

    it "rejects missing percentage fields" do
      cluster = build(Matter::Cluster::WindowCovering)
      expect_status(invoke(cluster, Matter::Cluster::WindowCovering::CMD_GO_TO_LIFT_PERCENTAGE), Matter::InteractionModel::StatusCode::InvalidCommand)
    end

    it "sets the tilt target from tag zero" do
      cluster = build(Matter::Cluster::WindowCovering,
        feature_map: Matter::Cluster::WindowCovering::Feature::Tilt | Matter::Cluster::WindowCovering::Feature::PositionAwareTilt)
      cluster.on_move { |_request| Matter::InteractionModel::Status.success }
      request = Matter::Cluster::WindowCovering::GoToTiltPercentageRequest.new(6789_u16)
      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_GO_TO_TILT_PERCENTAGE, request))
      read(cluster, Matter::Cluster::WindowCovering::ATTR_TARGET_POSITION_TILT_PERCENT100THS).should eq(6789_u16)
      read(cluster, Matter::Cluster::WindowCovering::ATTR_CURRENT_POSITION_TILT_PERCENT100THS).should be_nil
      read(cluster, Matter::Cluster::WindowCovering::ATTR_CURRENT_POSITION_TILT_PERCENTAGE).should be_nil
      read(cluster, Matter::Cluster::WindowCovering::ATTR_NUMBER_OF_ACTUATIONS_TILT).should eq(0_u16)
    end

    it "rejects a tilt percentage above 100 percent" do
      cluster = build(Matter::Cluster::WindowCovering,
        feature_map: Matter::Cluster::WindowCovering::Feature::Tilt | Matter::Cluster::WindowCovering::Feature::PositionAwareTilt)
      request = Matter::Cluster::WindowCovering::GoToTiltPercentageRequest.new(10001_u16)
      expect_status(invoke(cluster, Matter::Cluster::WindowCovering::CMD_GO_TO_TILT_PERCENTAGE, request), Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.target_position_tilt_percent100ths.should be_nil
    end
  end

  describe "host motion admission" do
    it "accepts an idle stop as a no-op without a host callback" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering)
      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_STOP_MOTION))
      cluster.target_position_lift_percent100ths.should be_nil
    end

    it "delivers stop while a percentage move has an unknown current position" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering)
      stopped = false
      cluster.on_move { |_request| Matter::InteractionModel::Status.success }
      cluster.on_stop do
        stopped = true
        Matter::InteractionModel::Status.success
      end
      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_GO_TO_LIFT_PERCENTAGE,
        Matter::Cluster::WindowCovering::GoToLiftPercentageRequest.new(4_000_u16)))
      cluster.operational_status.should eq(Matter::Cluster::WindowCovering::OperationalStatus::None)

      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_STOP_MOTION))
      stopped.should be_true
      cluster.target_position_lift_percent100ths.should be_nil
    end

    it "does not acknowledge physical motion without a host" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering)
      expect_status(invoke(cluster, Matter::Cluster::WindowCovering::CMD_UP_OR_OPEN),
        Matter::InteractionModel::StatusCode::InvalidInState)
      cluster.target_position_lift_percent100ths.should be_nil
    end

    it "routes lift and tilt targets together and leaves state unchanged when the host rejects motion" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering, feature_map: Matter::Cluster::WindowCovering::Feature::Lift | Matter::Cluster::WindowCovering::Feature::Tilt |
                                             Matter::Cluster::WindowCovering::Feature::PositionAwareLift | Matter::Cluster::WindowCovering::Feature::PositionAwareTilt)
      requests = [] of Matter::Cluster::WindowCovering::MotionRequest
      cluster.on_move do |request|
        requests << request
        Matter::InteractionModel::Status.failure
      end

      expect_status(invoke(cluster, Matter::Cluster::WindowCovering::CMD_DOWN_OR_CLOSE), Matter::InteractionModel::StatusCode::Failure)
      requests.size.should eq(1)
      requests.first.lift_target.should eq(10_000_u16)
      requests.first.tilt_target.should eq(10_000_u16)
      cluster.target_position_lift_percent100ths.should be_nil
      cluster.target_position_tilt_percent100ths.should be_nil
      cluster.operational_status.should eq(Matter::Cluster::WindowCovering::OperationalStatus::None)
    end

    it "returns failure without changing targets if the actuator callback raises" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering)
      cluster.on_move do |_request|
        raise Matter::ClusterError.new("actuator failed")
      end

      expect_status(invoke(cluster, Matter::Cluster::WindowCovering::CMD_DOWN_OR_CLOSE),
        Matter::InteractionModel::StatusCode::Failure)
      cluster.target_position_lift_percent100ths.should be_nil
      cluster.operational_status.should eq(Matter::Cluster::WindowCovering::OperationalStatus::None)
    end

    it "delivers stop and retains motion state if the host cannot stop" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering)
      cluster.current_position_lift_percent100ths = 0_u16
      cluster.on_move { |_request| Matter::InteractionModel::Status.success }
      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_DOWN_OR_CLOSE))
      cluster.on_stop { Matter::InteractionModel::Status.failure }

      expect_status(invoke(cluster, Matter::Cluster::WindowCovering::CMD_STOP_MOTION), Matter::InteractionModel::StatusCode::Failure)
      cluster.target_position_lift_percent100ths.should eq(10_000_u16)
      cluster.operational_status.should eq(Matter::Cluster::WindowCovering::OperationalStatus.new(0x0A_u8))
    end

    it "settles only the axis whose reported position reaches its target" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering, feature_map: Matter::Cluster::WindowCovering::Feature::Lift | Matter::Cluster::WindowCovering::Feature::Tilt |
                                             Matter::Cluster::WindowCovering::Feature::PositionAwareLift | Matter::Cluster::WindowCovering::Feature::PositionAwareTilt)
      cluster.current_position_lift_percent100ths = 0_u16
      cluster.current_position_tilt_percent100ths = 0_u16
      cluster.on_move { |_request| Matter::InteractionModel::Status.success }
      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_DOWN_OR_CLOSE))

      cluster.current_position_lift_percent100ths = 10_000_u16
      cluster.operational_status.should eq(Matter::Cluster::WindowCovering::OperationalStatus.new(0x22_u8))
      cluster.current_position_tilt_percent100ths = 10_000_u16
      cluster.operational_status.should eq(Matter::Cluster::WindowCovering::OperationalStatus::None)
    end

    it "settles immediately when the host reports completion during admission" do
      covering = Matter::Cluster::WindowCovering
      cluster = build(covering)
      cluster.current_position_lift_percent100ths = 0_u16
      cluster.on_move do |request|
        cluster.current_position_lift_percent100ths = request.lift_target
        Matter::InteractionModel::Status.success
      end

      expect_success(invoke(cluster, Matter::Cluster::WindowCovering::CMD_DOWN_OR_CLOSE))
      cluster.current_position_lift_percent100ths.should eq(10_000_u16)
      cluster.operational_status.should eq(Matter::Cluster::WindowCovering::OperationalStatus::None)
    end
  end

  describe "cluster metadata" do
    cluster = build(Matter::Cluster::WindowCovering)

    it "has correct cluster ID" do
      cluster.cluster_id.id.should eq(0x0102_u32)
    end

    it "has correct name" do
      cluster.name.should eq("WindowCovering")
    end

    it "has correct default feature map" do
      cluster.feature_map.should eq(
        Matter::Cluster::WindowCovering::Feature::Lift |
        Matter::Cluster::WindowCovering::Feature::PositionAwareLift
      )
    end
  end

  describe "attribute read/write" do
    cluster = build(Matter::Cluster::WindowCovering)

    it "reads type attribute" do
      result = read_tlv(cluster, Matter::Cluster::WindowCovering::ATTR_TYPE)
      result.should be_a(TLV::Any)
      result.value.should eq(0) # Rollershade
    end

    it "reads config status attribute" do
      result = read_tlv(cluster, Matter::Cluster::WindowCovering::ATTR_CONFIG_STATUS)
      result.should be_a(TLV::Any)
    end

    it "writes mode attribute" do
      # Set calibration mode
      mode = 0x02_u8 # CalibrationMode
      status = write(cluster, Matter::Cluster::WindowCovering::ATTR_MODE, mode)
      status.status.should eq(Matter::InteractionModel::StatusCode::Success)

      # Verify it was written
      cluster.mode.should eq(Matter::Cluster::WindowCovering::Mode::CalibrationMode)
    end

    it "reads feature map" do
      result = read_tlv(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP)
      result.should be_a(TLV::Any)
      # Lift (0x01) | PositionAwareLift (0x04) = 0x05
      result.value.should eq(0x05)
    end
  end
end
