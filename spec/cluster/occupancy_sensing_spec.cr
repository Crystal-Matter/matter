require "../spec_helper"

describe Matter::Cluster::OccupancySensing do
  describe "initialization" do
    it "creates with default values (unoccupied)" do
      cluster = build(Matter::Cluster::OccupancySensing)
      cluster.occupancy.should eq(0_u8) # Unoccupied
      cluster.occupancy_sensor_type.should eq(Matter::Cluster::OccupancySensing::OccupancySensorType::PIR)
      cluster.occupancy_sensor_type_bitmap.should eq(0x01_u8) # Bit 0 = PIR
      cluster.hold_time.should be_nil
      cluster.pir_occupied_to_unoccupied_delay.should eq(0_u16)
      cluster.pir_unoccupied_to_occupied_delay.should eq(0_u16)
      cluster.pir_unoccupied_to_occupied_threshold.should eq(1_u8)
    end

    it "creates with occupied state" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 1_u8
      )
      cluster.occupancy.should eq(1_u8)
      cluster.occupied?.should be_true
    end

    it "creates with PIR configuration" do
      cluster = build(Matter::Cluster::OccupancySensing,
        hold_time: 60_u16,
        pir_occupied_to_unoccupied_delay: 60_u16,
        pir_unoccupied_to_occupied_delay: 5_u16,
        pir_unoccupied_to_occupied_threshold: 3_u8
      )
      cluster.hold_time.should eq(60_u16)
      cluster.pir_occupied_to_unoccupied_delay.should eq(60_u16)
      cluster.pir_unoccupied_to_occupied_delay.should eq(5_u16)
      cluster.pir_unoccupied_to_occupied_threshold.should eq(3_u8)
    end

    it "validates occupancy bitmap (must be 0 or 1)" do
      expect_raises(ArgumentError, /occupancy must be <= 1/) do
        build(Matter::Cluster::OccupancySensing,
          occupancy: 2_u8
        )
      end
    end

    it "validates PIR threshold minimum (must be >= 1)" do
      expect_raises(ArgumentError, /pir_unoccupied_to_occupied_threshold must be between 1 and 254/) do
        build(Matter::Cluster::OccupancySensing,
          pir_unoccupied_to_occupied_threshold: 0_u8
        )
      end
    end

    it "validates PIR threshold maximum (must be <= 254)" do
      expect_raises(ArgumentError, /pir_unoccupied_to_occupied_threshold must be between 1 and 254/) do
        build(Matter::Cluster::OccupancySensing,
          pir_unoccupied_to_occupied_threshold: 255_u8
        )
      end
    end
  end

  describe "attributes" do
    it "has required attributes" do
      cluster = build(Matter::Cluster::OccupancySensing, hold_time: 60_u16)
      attrs = cluster.attributes
      # Base attributes (3) + HoldTime and limits + PIR timing attributes (3)
      attrs.size.should eq(8)
      attrs.map(&.name).should contain("occupancy")
      attrs.map(&.name).should contain("occupancySensorType")
      attrs.map(&.name).should contain("occupancySensorTypeBitmap")
      attrs.map(&.name).should contain("pirOccupiedToUnoccupiedDelay")
      attrs.map(&.name).should contain("pirUnoccupiedToOccupiedDelay")
      attrs.map(&.name).should contain("pirUnoccupiedToOccupiedThreshold")
    end

    it "includes holdTime attribute when set" do
      cluster = build(Matter::Cluster::OccupancySensing, hold_time: 60_u16)
      attrs = cluster.attributes
      attrs.map(&.name).should contain("holdTime")
      attrs.map(&.name).should contain("holdTimeLimits")
    end

    it "reads the global FeatureMap with the configured sensing features" do
      cluster = build(Matter::Cluster::OccupancySensing)
      # PIR feature bit (the default modality)
      read(cluster, 0xFFFC_u32).should eq(2_u32)
    end

    it "reads Occupancy when unoccupied" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 0_u8
      )
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_OCCUPANCY).should eq(0_u8)
    end

    it "reads Occupancy when occupied" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 1_u8
      )
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_OCCUPANCY).should eq(1_u8)
    end

    it "reads OccupancySensorType" do
      cluster = build(Matter::Cluster::OccupancySensing)
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_OCCUPANCY_SENSOR_TYPE).should eq(0_u8) # PIR = 0
    end

    it "reads OccupancySensorTypeBitmap" do
      cluster = build(Matter::Cluster::OccupancySensing)
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_OCCUPANCY_SENSOR_TYPE_BITMAP).should eq(0x01_u8) # Bit 0 = PIR
    end

    it "reads HoldTime when set" do
      cluster = build(Matter::Cluster::OccupancySensing,
        hold_time: 60_u16
      )
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_HOLD_TIME).should eq(60)
    end

    it "returns unsupported for HoldTime when not set" do
      cluster = build(Matter::Cluster::OccupancySensing)
      read_status(cluster, Matter::Cluster::OccupancySensing::ATTR_HOLD_TIME).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end

    it "reads PIROccupiedToUnoccupiedDelay when set" do
      cluster = build(Matter::Cluster::OccupancySensing,
        pir_occupied_to_unoccupied_delay: 30_u16,
        hold_time: 30_u16
      )
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_PIR_OCCUPIED_TO_UNOCCUPIED_DELAY).should eq(30)
    end

    it "returns default value for PIROccupiedToUnoccupiedDelay when not explicitly set" do
      cluster = build(Matter::Cluster::OccupancySensing, hold_time: 60_u16)
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_PIR_OCCUPIED_TO_UNOCCUPIED_DELAY).should eq(60)
    end

    it "returns unsupported for PIROccupiedToUnoccupiedDelay when PIR feature disabled" do
      cluster = build(Matter::Cluster::OccupancySensing,
        feature_map: Matter::Cluster::OccupancySensing::Feature::Ultrasonic,
        hold_time: 60_u16
      )
      read_status(cluster, Matter::Cluster::OccupancySensing::ATTR_PIR_OCCUPIED_TO_UNOCCUPIED_DELAY).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end

    it "reads PIRUnoccupiedToOccupiedThreshold when set" do
      cluster = build(Matter::Cluster::OccupancySensing,
        pir_unoccupied_to_occupied_threshold: 3_u8,
        hold_time: 60_u16
      )
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_PIR_UNOCCUPIED_TO_OCCUPIED_THRESHOLD).should eq(3_u8)
    end

    it "returns default value for PIRUnoccupiedToOccupiedThreshold when not explicitly set" do
      cluster = build(Matter::Cluster::OccupancySensing, hold_time: 60_u16)
      read(cluster, Matter::Cluster::OccupancySensing::ATTR_PIR_UNOCCUPIED_TO_OCCUPIED_THRESHOLD).should eq(1_u8) # Default value is 1
    end

    it "returns unsupported for PIRUnoccupiedToOccupiedThreshold when PIR feature disabled" do
      cluster = build(Matter::Cluster::OccupancySensing,
        feature_map: Matter::Cluster::OccupancySensing::Feature::Ultrasonic,
        hold_time: 60_u16
      )
      read_status(cluster, Matter::Cluster::OccupancySensing::ATTR_PIR_UNOCCUPIED_TO_OCCUPIED_THRESHOLD).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "update_occupancy" do
    it "updates to occupied" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 0_u8
      )
      cluster.occupied?.should be_false
      cluster.update_occupancy(true)
      cluster.occupancy.should eq(1_u8)
      cluster.occupied?.should be_true
    end

    it "updates to unoccupied" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 1_u8
      )
      cluster.occupied?.should be_true
      cluster.update_occupancy(false)
      cluster.occupancy.should eq(0_u8)
      cluster.occupied?.should be_false
    end

    it "calls callback when occupancy changes" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 0_u8
      )

      old_val = nil.as(UInt8?)
      new_val = nil.as(UInt8?)
      cluster.on_occupancy_changed do |old, new|
        old_val = old
        new_val = new
      end

      cluster.update_occupancy(true)
      old_val.should eq(0_u8)
      new_val.should eq(1_u8)
    end

    it "doesn't call callback when occupancy doesn't change" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 1_u8
      )

      callback_called = false
      cluster.on_occupancy_changed do |_, _|
        callback_called = true
      end

      cluster.update_occupancy(true) # Already occupied
      callback_called.should be_false
    end

    it "increments data version only on changes" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 0_u8
      )

      initial_version = cluster.data_version
      cluster.update_occupancy(false) # Same value (unoccupied)
      cluster.data_version.should eq(initial_version)

      cluster.update_occupancy(true) # Different value (occupied)
      cluster.data_version.should eq(initial_version + 1)
    end

    it "notifies attribute subscribers when occupancy changes" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 0_u8
      )

      notified = false
      notified_endpoint : UInt16 = 0_u16
      notified_cluster : UInt32 = 0_u32
      notified_attribute : UInt32 = 0_u32

      cluster.on_attribute_changed = ->(ep : UInt16, cl : UInt32, attr : UInt32) {
        notified = true
        notified_endpoint = ep
        notified_cluster = cl
        notified_attribute = attr
      }

      cluster.update_occupancy(true)

      notified.should be_true
      notified_endpoint.should eq(1_u16)
      notified_cluster.should eq(Matter::Cluster::OccupancySensing::CLUSTER_ID)
      notified_attribute.should eq(Matter::Cluster::OccupancySensing::ATTR_OCCUPANCY)
    end

    it "does not notify attribute subscribers when occupancy is unchanged" do
      cluster = build(Matter::Cluster::OccupancySensing,
        occupancy: 0_u8
      )

      notifications = 0
      cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
        notifications += 1
      }

      cluster.update_occupancy(false)

      notifications.should eq(0)
    end
  end

  describe "practical scenarios" do
    it "models a PIR motion sensor in a room" do
      # Simple PIR sensor that detects motion

      sensor = build(Matter::Cluster::OccupancySensing,
        occupancy: 0_u8, # Initially unoccupied
        hold_time: 60_u16,
        pir_occupied_to_unoccupied_delay: 60_u16,  # 60 seconds hold after last motion
        pir_unoccupied_to_occupied_delay: 0_u16,   # Instant detection
        pir_unoccupied_to_occupied_threshold: 1_u8 # Single detection needed
      )

      sensor.occupied?.should be_false

      # Person enters room - motion detected
      sensor.update_occupancy(true)
      sensor.occupied?.should be_true

      # Person leaves room - after delay, marked unoccupied
      sensor.update_occupancy(false)
      sensor.occupied?.should be_false
    end

    it "models a PIR sensor with debouncing (multiple detections required)" do
      # PIR sensor that requires multiple detections to avoid false positives

      sensor = build(Matter::Cluster::OccupancySensing, 2,
        occupancy: 0_u8,
        hold_time: 60_u16,
        pir_unoccupied_to_occupied_threshold: 3_u8 # 3 detections required
      )

      # This would require tracking detection events in a real implementation
      # For now, we just verify the threshold is configured
      sensor.pir_unoccupied_to_occupied_threshold.should eq(3_u8)
      sensor.occupied?.should be_false

      # After 3 detections, would transition to occupied
      sensor.update_occupancy(true)
      sensor.occupied?.should be_true
    end

    it "models a hallway sensor with hold time" do
      # Hallway sensor that holds occupied state for a while after last motion

      sensor = build(Matter::Cluster::OccupancySensing, 3,
        occupancy: 0_u8,
        hold_time: 120_u16, # 2 minutes hold time
        pir_occupied_to_unoccupied_delay: 120_u16
      )

      sensor.hold_time.should eq(120_u16)

      # Person walks through hallway
      sensor.update_occupancy(true)
      sensor.occupied?.should be_true

      # Stays occupied for 120 seconds even without motion
      # (hold time implementation would be in a higher layer)

      # After hold time expires
      sensor.update_occupancy(false)
      sensor.occupied?.should be_false
    end

    it "models an office occupancy sensor with delays" do
      # Office sensor with delays to prevent flickering

      sensor = build(Matter::Cluster::OccupancySensing, 4,
        occupancy: 0_u8,
        hold_time: 300_u16,
        pir_occupied_to_unoccupied_delay: 300_u16, # 5 minutes to unoccupied
        pir_unoccupied_to_occupied_delay: 2_u16,   # 2 seconds to occupied
        pir_unoccupied_to_occupied_threshold: 2_u8 # 2 detections
      )

      changes = [] of Bool
      sensor.on_occupancy_changed do |_, new|
        changes << (new == 1_u8)
      end

      # Person enters office
      sensor.update_occupancy(true)
      changes.should eq([true])

      # Person leaves office (after 5 min delay)
      sensor.update_occupancy(false)
      changes.should eq([true, false])

      # Person returns
      sensor.update_occupancy(true)
      changes.should eq([true, false, true])
    end

    it "tracks occupancy state transitions" do
      sensor = build(Matter::Cluster::OccupancySensing, 5)

      transitions = [] of String
      sensor.on_occupancy_changed do |old, new|
        old_state = (old == 1_u8) ? "occupied" : "unoccupied"
        new_state = (new == 1_u8) ? "occupied" : "unoccupied"
        transitions << "#{old_state} -> #{new_state}"
      end

      # Multiple state changes
      sensor.update_occupancy(true)
      sensor.update_occupancy(false)
      sensor.update_occupancy(true)
      sensor.update_occupancy(false)

      transitions.should eq([
        "unoccupied -> occupied",
        "occupied -> unoccupied",
        "unoccupied -> occupied",
        "occupied -> unoccupied",
      ])
    end
  end

  describe "error handling" do
    it "returns error for unsupported attributes" do
      cluster = build(Matter::Cluster::OccupancySensing)
      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end
end
