require "../spec_helper"

describe Matter::Cluster::PressureMeasurement do
  describe "initialization" do
    it "creates with default values" do
      cluster = build(Matter::Cluster::PressureMeasurement)
      cluster.measured_value.should be_nil
      cluster.min_measured_value.should be_nil
      cluster.max_measured_value.should be_nil
      cluster.tolerance.should eq(0_u16)
    end

    it "creates with custom values" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16, # 101.3 kPa (standard atmosphere)
        min_measured_value: 800_i16,
        max_measured_value: 1200_i16,
        tolerance: 10_u16
      )
      cluster.measured_value.should eq(1013_i16)
      cluster.min_measured_value.should eq(800_i16)
      cluster.max_measured_value.should eq(1200_i16)
      cluster.tolerance.should eq(10_u16)
    end

    it "validates min_measured_value maximum (must be <= 32766)" do
      expect_raises(ArgumentError, /min_measured_value must be <= 32766/) do
        build(Matter::Cluster::PressureMeasurement,
          min_measured_value: 32767_i16
        )
      end
    end

    it "validates min/max relationship" do
      expect_raises(ArgumentError, /min_measured_value must be < max_measured_value/) do
        build(Matter::Cluster::PressureMeasurement,
          min_measured_value: 1200_i16,
          max_measured_value: 800_i16
        )
      end
    end

    it "validates measured value is within range" do
      expect_raises(ArgumentError, /measured_value must be <= max_measured_value/) do
        build(Matter::Cluster::PressureMeasurement,
          measured_value: 1500_i16,
          min_measured_value: 800_i16,
          max_measured_value: 1200_i16
        )
      end
    end

    it "validates tolerance maximum" do
      expect_raises(ArgumentError, /tolerance must be <= 2048/) do
        build(Matter::Cluster::PressureMeasurement,
          tolerance: 2049_u16
        )
      end
    end

    it "allows negative pressure values" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: -100_i16, # -10.0 kPa (vacuum)
        min_measured_value: -1000_i16,
        max_measured_value: 2000_i16
      )
      cluster.measured_value.should eq(-100_i16)
    end
  end

  describe "attributes" do
    it "has required attributes" do
      cluster = build(Matter::Cluster::PressureMeasurement, tolerance: 0_u16)
      attrs = cluster.attributes
      attrs.size.should eq(4)
      attrs.map(&.name).should contain("measuredValue")
      attrs.map(&.name).should contain("minMeasuredValue")
      attrs.map(&.name).should contain("maxMeasuredValue")
      attrs.map(&.name).should contain("tolerance")
    end

    it "reads MeasuredValue when set" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16
      )
      read(cluster, Matter::Cluster::PressureMeasurement::ATTR_MEASURED_VALUE).should eq(1013)
    end

    it "reads MeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::PressureMeasurement)
      read(cluster, Matter::Cluster::PressureMeasurement::ATTR_MEASURED_VALUE).should be_nil
    end

    it "reads MinMeasuredValue when set" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        min_measured_value: 800_i16
      )
      read(cluster, Matter::Cluster::PressureMeasurement::ATTR_MIN_MEASURED_VALUE).should eq(800)
    end

    it "reads MinMeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::PressureMeasurement)
      read(cluster, Matter::Cluster::PressureMeasurement::ATTR_MIN_MEASURED_VALUE).should be_nil
    end

    it "reads MaxMeasuredValue when set" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        max_measured_value: 1200_i16
      )
      read(cluster, Matter::Cluster::PressureMeasurement::ATTR_MAX_MEASURED_VALUE).should eq(1200)
    end

    it "reads MaxMeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::PressureMeasurement)
      read(cluster, Matter::Cluster::PressureMeasurement::ATTR_MAX_MEASURED_VALUE).should be_nil
    end

    it "reads Tolerance when set" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        tolerance: 10_u16
      )
      read(cluster, Matter::Cluster::PressureMeasurement::ATTR_TOLERANCE).should eq(10)
    end

    it "returns unsupported for Tolerance when not set" do
      cluster = build(Matter::Cluster::PressureMeasurement)
      read_status(cluster, Matter::Cluster::PressureMeasurement::ATTR_TOLERANCE).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "update_pressure" do
    it "updates pressure value" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16,
        min_measured_value: 800_i16,
        max_measured_value: 1200_i16
      )
      cluster.update_pressure(1050_i16)
      cluster.measured_value.should eq(1050_i16)
    end

    it "accepts nil for unknown pressure" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16
      )
      cluster.update_pressure(nil)
      cluster.measured_value.should be_nil
    end

    it "rejects pressure below minimum" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16,
        min_measured_value: 800_i16,
        max_measured_value: 1200_i16
      )
      expect_raises(ArgumentError, /below minimum/) do
        cluster.update_pressure(700_i16)
      end
    end

    it "rejects pressure above maximum" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16,
        min_measured_value: 800_i16,
        max_measured_value: 1200_i16
      )
      expect_raises(ArgumentError, /above maximum/) do
        cluster.update_pressure(1300_i16)
      end
    end

    it "calls callback when pressure changes" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16
      )

      old_val = nil.as(Int16?)
      new_val = nil.as(Int16?)
      cluster.on_pressure_changed do |old, new|
        old_val = old
        new_val = new
      end

      cluster.update_pressure(1050_i16)
      old_val.should eq(1013_i16)
      new_val.should eq(1050_i16)
    end

    it "doesn't call callback when pressure doesn't change" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16
      )

      callback_called = false
      cluster.on_pressure_changed do |_, _|
        callback_called = true
      end

      cluster.update_pressure(1013_i16)
      callback_called.should be_false
    end

    it "increments data version only on changes" do
      cluster = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16
      )

      initial_version = cluster.data_version
      cluster.update_pressure(1013_i16) # Same value
      cluster.data_version.should eq(initial_version)

      cluster.update_pressure(1050_i16) # Different value
      cluster.data_version.should eq(initial_version + 1)
    end
  end

  describe "pressure conversion helpers" do
    it "converts from 0.1 kPa to kPa" do
      kpa = Matter::Cluster::PressureMeasurement.to_kilopascals(1013_i16)
      kpa.should be_close(101.3, 0.01)
    end

    it "converts from kPa to 0.1 kPa" do
      value = Matter::Cluster::PressureMeasurement.from_kilopascals(101.3)
      value.should eq(1013_i16)
    end

    it "converts from 0.1 kPa to hPa/mbar" do
      # 1013 (0.1 kPa) = 101.3 kPa = 1013 hPa
      hpa = Matter::Cluster::PressureMeasurement.to_hectopascals(1013_i16)
      hpa.should be_close(1013.0, 0.01)
    end

    it "converts from hPa/mbar to 0.1 kPa" do
      # 1013 hPa = 101.3 kPa = 1013 (0.1 kPa)
      value = Matter::Cluster::PressureMeasurement.from_hectopascals(1013.0)
      value.should eq(1013_i16)
    end

    it "converts from 0.1 kPa to mmHg" do
      # 1013 (0.1 kPa) = 101.3 kPa = 759.9 mmHg (approx)
      mmhg = Matter::Cluster::PressureMeasurement.to_mmhg(1013_i16)
      mmhg.should be_close(759.9, 1.0)
    end

    it "converts from mmHg to 0.1 kPa" do
      # 760 mmHg ≈ 101.325 kPa ≈ 1013 (0.1 kPa)
      value = Matter::Cluster::PressureMeasurement.from_mmhg(760.0)
      value.should be_close(1013_i16, 1)
    end

    it "converts from 0.1 kPa to inHg" do
      # 1013 (0.1 kPa) = 101.3 kPa ≈ 29.92 inHg
      inhg = Matter::Cluster::PressureMeasurement.to_inhg(1013_i16)
      inhg.should be_close(29.92, 0.1)
    end

    it "converts from inHg to 0.1 kPa" do
      # 29.92 inHg ≈ 101.3 kPa = 1013 (0.1 kPa)
      value = Matter::Cluster::PressureMeasurement.from_inhg(29.92)
      value.should be_close(1013_i16, 1)
    end

    it "handles negative pressure (vacuum)" do
      kpa = Matter::Cluster::PressureMeasurement.to_kilopascals(-100_i16)
      kpa.should eq(-10.0)

      value = Matter::Cluster::PressureMeasurement.from_kilopascals(-10.0)
      value.should eq(-100_i16)
    end
  end

  describe "practical scenarios" do
    it "models a barometric pressure sensor (weather station)" do
      # Standard atmospheric pressure: 101.325 kPa = 1013.25 hPa
      # Typical range: 950-1050 hPa (95-105 kPa)

      sensor = build(Matter::Cluster::PressureMeasurement,
        measured_value: 1013_i16, # 101.3 kPa (1013 hPa)
        min_measured_value: 950_i16,
        max_measured_value: 1050_i16,
        tolerance: 10_u16 # ±1.0 kPa (±10 hPa)
      )

      # Verify initial value
      kpa = Matter::Cluster::PressureMeasurement.to_kilopascals(sensor.measured_value.as(Int16))
      kpa.should be_close(101.3, 0.1)

      hpa = Matter::Cluster::PressureMeasurement.to_hectopascals(sensor.measured_value.as(Int16))
      hpa.should be_close(1013.0, 1.0)

      # High pressure system moves in
      sensor.update_pressure(1030_i16) # 103.0 kPa (1030 hPa)
      hpa = Matter::Cluster::PressureMeasurement.to_hectopascals(sensor.measured_value.as(Int16))
      hpa.should be_close(1030.0, 1.0)

      # Low pressure system (storm)
      sensor.update_pressure(980_i16) # 98.0 kPa (980 hPa)
      hpa = Matter::Cluster::PressureMeasurement.to_hectopascals(sensor.measured_value.as(Int16))
      hpa.should be_close(980.0, 1.0)
    end

    it "models an altitude-compensated sensor" do
      # Sea level: 101.3 kPa
      # Mountain (2000m): ~79.5 kPa

      sensor = build(Matter::Cluster::PressureMeasurement, 2,
        measured_value: 795_i16, # 79.5 kPa (altitude pressure)
        min_measured_value: 600_i16,
        max_measured_value: 1050_i16
      )

      # Verify pressure at altitude
      kpa = Matter::Cluster::PressureMeasurement.to_kilopascals(sensor.measured_value.as(Int16))
      kpa.should be_close(79.5, 0.5)
    end

    it "models a vacuum sensor (industrial)" do
      # Vacuum applications use negative pressure relative to atmospheric

      sensor = build(Matter::Cluster::PressureMeasurement, 3,
        measured_value: -500_i16, # -50.0 kPa (vacuum)
        min_measured_value: -1000_i16,
        max_measured_value: 100_i16
      )

      # Verify vacuum pressure
      kpa = Matter::Cluster::PressureMeasurement.to_kilopascals(sensor.measured_value.as(Int16))
      kpa.should eq(-50.0)

      # Increase vacuum (more negative)
      sensor.update_pressure(-800_i16)
      kpa = Matter::Cluster::PressureMeasurement.to_kilopascals(sensor.measured_value.as(Int16))
      kpa.should eq(-80.0)
    end

    it "handles sensor failure (unknown pressure)" do
      sensor = build(Matter::Cluster::PressureMeasurement, 4,
        measured_value: 1013_i16
      )

      sensor.measured_value.should_not be_nil

      # Sensor failure
      sensor.update_pressure(nil)
      sensor.measured_value.should be_nil

      # Read attribute returns null
      read(sensor, Matter::Cluster::PressureMeasurement::ATTR_MEASURED_VALUE).should be_nil
    end

    it "works with different pressure units" do
      # Convert standard atmospheric pressure to different units
      standard_atm = 1013_i16 # 101.3 kPa

      kpa = Matter::Cluster::PressureMeasurement.to_kilopascals(standard_atm)
      kpa.should be_close(101.3, 0.1)

      hpa = Matter::Cluster::PressureMeasurement.to_hectopascals(standard_atm)
      hpa.should be_close(1013.0, 1.0)

      mmhg = Matter::Cluster::PressureMeasurement.to_mmhg(standard_atm)
      mmhg.should be_close(760.0, 5.0) # 760 mmHg is standard atmosphere

      inhg = Matter::Cluster::PressureMeasurement.to_inhg(standard_atm)
      inhg.should be_close(29.92, 0.2) # 29.92 inHg is standard atmosphere
    end
  end

  describe "error handling" do
    it "returns error for unsupported attributes" do
      cluster = build(Matter::Cluster::PressureMeasurement)
      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end
end
