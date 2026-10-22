require "../spec_helper"

describe Matter::Cluster::IlluminanceMeasurement do
  describe "Matter 1.6 revision 5" do
    it "reports revision 5 through the global attribute" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(5_u16)
    end

    it "marks configuration attributes fixed while the live reading remains mutable" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        tolerance: 0_u16,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode
      )
      fixed_ids = {
        Matter::Cluster::IlluminanceMeasurement::ATTR_MIN_MEASURED_VALUE,
        Matter::Cluster::IlluminanceMeasurement::ATTR_MAX_MEASURED_VALUE,
        Matter::Cluster::IlluminanceMeasurement::ATTR_TOLERANCE,
        Matter::Cluster::IlluminanceMeasurement::ATTR_LIGHT_SENSOR_TYPE,
      }
      cluster.attributes.find! { |attribute| attribute.id.id == Matter::Cluster::IlluminanceMeasurement::ATTR_MEASURED_VALUE }.fixed?.should be_false
      fixed_ids.each do |id|
        cluster.attributes.find! { |attribute| attribute.id.id == id }.fixed?.should be_true
      end
    end

    it "rejects host changes to fixed configuration without changing DataVersion" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        min_measured_value: 1_u16,
        max_measured_value: 1000_u16,
        tolerance: 10_u16,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode
      )
      version = cluster.data_version

      expect_raises(ArgumentError, /fixed illuminance/) { cluster.min_measured_value = 2_u16 }
      expect_raises(ArgumentError, /fixed illuminance/) { cluster.max_measured_value = 999_u16 }
      expect_raises(ArgumentError, /fixed illuminance/) { cluster.tolerance = 11_u16 }
      expect_raises(ArgumentError, /fixed illuminance/) { cluster.light_sensor_type = Matter::Cluster::IlluminanceMeasurement::LightSensorType::CMOS }

      cluster.min_measured_value.should eq(1_u16)
      cluster.max_measured_value.should eq(1000_u16)
      cluster.tolerance.should eq(10_u16)
      cluster.light_sensor_type.should eq(Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode)
      cluster.data_version.should eq(version)
    end

    it "requires at least one step between non-null minimum and maximum" do
      expect_raises(ArgumentError, /max_measured_value must be at least min_measured_value \+ 1/) do
        build(Matter::Cluster::IlluminanceMeasurement,
          min_measured_value: 500_u16,
          max_measured_value: 500_u16
        )
      end
      build(Matter::Cluster::IlluminanceMeasurement,
        min_measured_value: 500_u16,
        max_measured_value: 501_u16
      ).max_measured_value.should eq(501_u16)
    end

    it "rejects the nullable sentinel as a concrete reading" do
      expect_raises(ArgumentError, /measured_value must be <= 65534/) do
        build(Matter::Cluster::IlluminanceMeasurement, measured_value: 65535_u16)
      end

      cluster = build(Matter::Cluster::IlluminanceMeasurement, measured_value: 100_u16)
      version = cluster.data_version
      expect_raises(ArgumentError, /above maximum/) { cluster.update_illuminance(65535_u16) }
      cluster.measured_value.should eq(100_u16)
      cluster.data_version.should eq(version)
    end

    it "reports a non-null optional tolerance when advertised" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement, tolerance: 0_u16)
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_TOLERANCE).should eq(0_u16)
      cluster.attributes.find! { |attribute| attribute.id.id == Matter::Cluster::IlluminanceMeasurement::ATTR_TOLERANCE }.optional?.should be_true
    end
  end

  describe "initialization" do
    it "creates with default values" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      cluster.measured_value.should be_nil
      cluster.min_measured_value.should be_nil
      cluster.max_measured_value.should be_nil
      cluster.tolerance.should be_nil
      cluster.light_sensor_type.should be_nil
    end

    it "creates with custom values" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16,
        min_measured_value: 1_u16,
        max_measured_value: 10000_u16,
        tolerance: 100_u16,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode
      )
      cluster.measured_value.should eq(5000_u16)
      cluster.min_measured_value.should eq(1_u16)
      cluster.max_measured_value.should eq(10000_u16)
      cluster.tolerance.should eq(100_u16)
      cluster.light_sensor_type.should eq(Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode)
    end

    it "validates min_measured_value minimum (must be >= 1)" do
      expect_raises(ArgumentError, /min_measured_value must be between 1 and 65533/) do
        build(Matter::Cluster::IlluminanceMeasurement,
          min_measured_value: 0_u16
        )
      end
    end

    it "validates min_measured_value maximum (must be <= 65533)" do
      expect_raises(ArgumentError, /min_measured_value must be between 1 and 65533/) do
        build(Matter::Cluster::IlluminanceMeasurement,
          min_measured_value: 65534_u16
        )
      end
    end

    it "validates max_measured_value maximum" do
      expect_raises(ArgumentError, /max_measured_value must be <= 65534/) do
        build(Matter::Cluster::IlluminanceMeasurement,
          max_measured_value: 65535_u16
        )
      end
    end

    it "validates min/max relationship" do
      expect_raises(ArgumentError, /max_measured_value must be at least min_measured_value \+ 1/) do
        build(Matter::Cluster::IlluminanceMeasurement,
          min_measured_value: 10000_u16,
          max_measured_value: 5000_u16
        )
      end
    end

    it "validates measured value is within range" do
      expect_raises(ArgumentError, /measured_value must be <= max_measured_value/) do
        build(Matter::Cluster::IlluminanceMeasurement,
          measured_value: 15000_u16,
          min_measured_value: 1_u16,
          max_measured_value: 10000_u16
        )
      end
    end

    it "allows measured_value of 0 (too low to measure)" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 0_u16,
        min_measured_value: 1_u16,
        max_measured_value: 10000_u16
      )
      cluster.measured_value.should eq(0_u16)
    end

    it "validates tolerance maximum" do
      expect_raises(ArgumentError, /tolerance must be <= 2048/) do
        build(Matter::Cluster::IlluminanceMeasurement,
          tolerance: 2049_u16
        )
      end
    end
  end

  describe "attributes" do
    it "has required attributes" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement, tolerance: 0_u16, light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode)
      attrs = cluster.attributes
      attrs.size.should eq(5)
      attrs.map(&.name).should contain("measuredValue")
      attrs.map(&.name).should contain("minMeasuredValue")
      attrs.map(&.name).should contain("maxMeasuredValue")
      attrs.map(&.name).should contain("tolerance")
      attrs.map(&.name).should contain("lightSensorType")
    end

    it "reads MeasuredValue when set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16
      )
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_MEASURED_VALUE).should eq(5000)
    end

    it "reads MeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_MEASURED_VALUE).should be_nil
    end

    it "reads MeasuredValue as 0 (too low to measure)" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 0_u16
      )
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_MEASURED_VALUE).should eq(0)
    end

    it "reads MinMeasuredValue when set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        min_measured_value: 1_u16
      )
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_MIN_MEASURED_VALUE).should eq(1)
    end

    it "reads MinMeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_MIN_MEASURED_VALUE).should be_nil
    end

    it "reads MaxMeasuredValue when set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        max_measured_value: 10000_u16
      )
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_MAX_MEASURED_VALUE).should eq(10000)
    end

    it "reads MaxMeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_MAX_MEASURED_VALUE).should be_nil
    end

    it "reads Tolerance when set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        tolerance: 100_u16
      )
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_TOLERANCE).should eq(100)
    end

    it "returns unsupported for Tolerance when not set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      read_status(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_TOLERANCE).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end

    it "reads LightSensorType when set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::CMOS
      )
      read(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_LIGHT_SENSOR_TYPE).should eq(1_u8) # CMOS = 1
    end

    it "returns unsupported for LightSensorType when not set" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      read_status(cluster, Matter::Cluster::IlluminanceMeasurement::ATTR_LIGHT_SENSOR_TYPE).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "update_illuminance" do
    it "updates illuminance value" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16,
        min_measured_value: 1_u16,
        max_measured_value: 10000_u16
      )
      cluster.update_illuminance(6000_u16)
      cluster.measured_value.should eq(6000_u16)
    end

    it "accepts nil for unknown illuminance" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16
      )
      cluster.update_illuminance(nil)
      cluster.measured_value.should be_nil
    end

    it "accepts 0 for too low to measure" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16,
        min_measured_value: 1_u16,
        max_measured_value: 10000_u16
      )
      cluster.update_illuminance(0_u16)
      cluster.measured_value.should eq(0_u16)
    end

    it "rejects illuminance below minimum" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16,
        min_measured_value: 1000_u16,
        max_measured_value: 10000_u16
      )
      expect_raises(ArgumentError, /below minimum/) do
        cluster.update_illuminance(500_u16)
      end
    end

    it "rejects illuminance above maximum" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16,
        min_measured_value: 1_u16,
        max_measured_value: 10000_u16
      )
      expect_raises(ArgumentError, /above maximum/) do
        cluster.update_illuminance(15000_u16)
      end
    end

    it "calls callback when illuminance changes" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16
      )

      old_val = nil.as(UInt16?)
      new_val = nil.as(UInt16?)
      cluster.on_illuminance_changed do |old, new|
        old_val = old
        new_val = new
      end

      cluster.update_illuminance(6000_u16)
      old_val.should eq(5000_u16)
      new_val.should eq(6000_u16)
    end

    it "doesn't call callback when illuminance doesn't change" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16
      )

      callback_called = false
      cluster.on_illuminance_changed do |_, _|
        callback_called = true
      end

      cluster.update_illuminance(5000_u16)
      callback_called.should be_false
    end

    it "increments data version only on changes" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16
      )

      initial_version = cluster.data_version
      cluster.update_illuminance(5000_u16) # Same value
      cluster.data_version.should eq(initial_version)

      cluster.update_illuminance(6000_u16) # Different value
      cluster.data_version.should eq(initial_version + 1)
    end

    it "notifies attribute subscribers when illuminance changes" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16
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

      cluster.update_illuminance(6000_u16)

      notified.should be_true
      notified_endpoint.should eq(1_u16)
      notified_cluster.should eq(Matter::Cluster::IlluminanceMeasurement::CLUSTER_ID)
      notified_attribute.should eq(Matter::Cluster::IlluminanceMeasurement::ATTR_MEASURED_VALUE)
    end

    it "does not notify attribute subscribers when illuminance is unchanged" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: 5000_u16
      )

      notifications = 0
      cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
        notifications += 1
      }

      cluster.update_illuminance(5000_u16)

      notifications.should eq(0)
    end
  end

  describe "illuminance conversion helpers" do
    it "converts from measured value to lux" do
      # MeasuredValue = 10,000 x log10(illuminance) + 1
      # For 100 lux: MeasuredValue = 10000 x log10(100) + 1 = 10000 x 2 + 1 = 20001
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(20001_u16)
      lux.round(2).should be_close(100.0, 0.1)
    end

    it "converts from lux to measured value" do
      # For 100 lux: MeasuredValue = 10000 x log10(100) + 1 = 20001
      measured = Matter::Cluster::IlluminanceMeasurement.from_lux(100.0)
      measured.should eq(20001_u16)
    end

    it "handles 0 for too low to measure" do
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(0_u16)
      lux.should eq(0.0)
    end

    it "returns 0 for lux below 1" do
      measured = Matter::Cluster::IlluminanceMeasurement.from_lux(0.5)
      measured.should eq(0_u16)
    end

    it "validates lux maximum (3,576,000 lux)" do
      expect_raises(ArgumentError, /must be <= 3,576,000/) do
        Matter::Cluster::IlluminanceMeasurement.from_lux(4_000_000.0)
      end
    end

    it "handles minimum measurable illuminance (1 lx)" do
      # For 1 lux: MeasuredValue = 10000 x log10(1) + 1 = 10000 x 0 + 1 = 1
      measured = Matter::Cluster::IlluminanceMeasurement.from_lux(1.0)
      measured.should eq(1_u16)
    end

    it "handles maximum measurable illuminance (3.576 Mlx)" do
      # For 3,576,000 lux (3.576 Mlx): MeasuredValue = 10000 x log10(3,576,000) + 1 ≈ 65534
      measured = Matter::Cluster::IlluminanceMeasurement.from_lux(3_576_000.0)
      measured.should be <= 65534_u16
      measured.should be >= 65533_u16
    end
  end

  describe "practical scenarios" do
    it "models a room light sensor" do
      # Typical indoor lighting: 100-500 lux
      # Range: very dim (1 lx) to bright (1000 lx)

      # Convert range to measured values
      min_val = Matter::Cluster::IlluminanceMeasurement.from_lux(1.0)    # 1 lux
      max_val = Matter::Cluster::IlluminanceMeasurement.from_lux(1000.0) # 1000 lux

      sensor = build(Matter::Cluster::IlluminanceMeasurement,
        measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(300.0), # 300 lux - typical
        min_measured_value: min_val,
        max_measured_value: max_val,
        tolerance: 50_u16,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode
      )

      # Verify initial value
      sensor.measured_value.should_not be_nil
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(sensor.measured_value.as(UInt16))
      lux.round.should be_close(300.0, 10.0)

      # Lights turned on - increase to 500 lux
      sensor.update_illuminance(Matter::Cluster::IlluminanceMeasurement.from_lux(500.0))
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(sensor.measured_value.as(UInt16))
      lux.round.should be_close(500.0, 10.0)

      # Lights dimmed - decrease to 200 lux
      sensor.update_illuminance(Matter::Cluster::IlluminanceMeasurement.from_lux(200.0))
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(sensor.measured_value.as(UInt16))
      lux.round.should be_close(200.0, 10.0)
    end

    it "models an outdoor daylight sensor" do
      # Outdoor range: very bright
      # Overcast day: 1,000 lux
      # Full daylight: 10,000 - 25,000 lux
      # Direct sunlight: 32,000 - 100,000 lux

      sensor = build(Matter::Cluster::IlluminanceMeasurement, 2,
        measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(10000.0), # Bright day
        min_measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(100.0),
        max_measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(100000.0),
        tolerance: 200_u16
      )

      # Verify measurement
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(sensor.measured_value.as(UInt16))
      lux.round.should be_close(10000.0, 500.0)

      # Cloud cover - drops to 1000 lux
      sensor.update_illuminance(Matter::Cluster::IlluminanceMeasurement.from_lux(1000.0))
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(sensor.measured_value.as(UInt16))
      lux.round.should be_close(1000.0, 50.0)

      # Direct sunlight - increases to 50000 lux
      sensor.update_illuminance(Matter::Cluster::IlluminanceMeasurement.from_lux(50000.0))
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(sensor.measured_value.as(UInt16))
      lux.round.should be_close(50000.0, 1000.0)
    end

    it "handles very low light (too low to measure)" do
      sensor = build(Matter::Cluster::IlluminanceMeasurement, 3,
        measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(10.0),
        min_measured_value: 1_u16,
        max_measured_value: 20000_u16
      )

      # Light goes out - becomes too low to measure
      sensor.update_illuminance(0_u16)
      sensor.measured_value.should eq(0_u16)

      # Convert back to lux
      lux = Matter::Cluster::IlluminanceMeasurement.to_lux(0_u16)
      lux.should eq(0.0)
    end

    it "handles sensor failure (unknown illuminance)" do
      sensor = build(Matter::Cluster::IlluminanceMeasurement, 4,
        measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(500.0)
      )

      sensor.measured_value.should_not be_nil

      # Sensor failure
      sensor.update_illuminance(nil)
      sensor.measured_value.should be_nil

      # Read attribute returns null
      read(sensor, Matter::Cluster::IlluminanceMeasurement::ATTR_MEASURED_VALUE).should be_nil
    end

    it "works with different sensor types" do
      # Photodiode sensor
      photodiode = build(Matter::Cluster::IlluminanceMeasurement, 5,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode
      )
      photodiode.light_sensor_type.should eq(Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode)

      # CMOS sensor
      cmos = build(Matter::Cluster::IlluminanceMeasurement, 6,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::CMOS
      )
      cmos.light_sensor_type.should eq(Matter::Cluster::IlluminanceMeasurement::LightSensorType::CMOS)
    end
  end

  describe "error handling" do
    it "returns error for unsupported attributes" do
      cluster = build(Matter::Cluster::IlluminanceMeasurement)
      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end
end
