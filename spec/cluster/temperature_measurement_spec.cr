require "../spec_helper"
require "../../src/matter/cluster/temperature_measurement"

describe Matter::Cluster::TemperatureMeasurement do
  describe "initialization" do
    it "creates temperature measurement cluster with defaults" do
      cluster = build(Matter::Cluster::TemperatureMeasurement)

      cluster.cluster_id.id.should eq(0x0402_u32)
      cluster.name.should eq("TemperatureMeasurement")
      cluster.measured_value.should be_nil
      cluster.min_measured_value.should be_nil
      cluster.max_measured_value.should be_nil
      cluster.tolerance.should eq(0_u16)
    end

    it "creates with custom values" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2550_i16,      # 25.50°C
        min_measured_value: -4000_i16, # -40.00°C
        max_measured_value: 8500_i16,  # 85.00°C
        tolerance: 50_u16              # ±0.50°C
      )

      cluster.measured_value.should eq(2550_i16)
      cluster.min_measured_value.should eq(-4000_i16)
      cluster.max_measured_value.should eq(8500_i16)
      cluster.tolerance.should eq(50_u16)
    end

    it "rejects min_measured_value below absolute minimum" do
      expect_raises(ArgumentError, /min_measured_value must be >= -27315/) do
        build(Matter::Cluster::TemperatureMeasurement,
          min_measured_value: -30000_i16
        )
      end
    end

    it "accepts max_measured_value at absolute maximum" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        max_measured_value: 32767_i16
      )

      cluster.max_measured_value.should eq(32767_i16)
    end

    it "rejects min > max" do
      expect_raises(ArgumentError, /min_measured_value must be < max_measured_value/) do
        build(Matter::Cluster::TemperatureMeasurement,
          min_measured_value: 5000_i16,
          max_measured_value: 1000_i16
        )
      end
    end

    it "rejects measured_value outside range" do
      expect_raises(ArgumentError, /measured_value must be between min and max/) do
        build(Matter::Cluster::TemperatureMeasurement,
          measured_value: 10000_i16,
          min_measured_value: 0_i16,
          max_measured_value: 5000_i16
        )
      end
    end

    it "rejects tolerance above maximum" do
      expect_raises(ArgumentError, /tolerance must be <= 2048/) do
        build(Matter::Cluster::TemperatureMeasurement,
          tolerance: 3000_u16
        )
      end
    end
  end

  describe "attributes" do
    it "has required attributes" do
      cluster = build(Matter::Cluster::TemperatureMeasurement, tolerance: 0_u16)

      attributes = cluster.attributes
      attributes.size.should eq(4)

      measured_value = attributes.find { |attr| attr.id.id == 0x0000_u32 }
      measured_value.should_not be_nil
      measured_attr = measured_value.as(Matter::Cluster::AttributeMetadata)
      measured_attr.name.should eq("measuredValue")
      measured_attr.writable?.should be_false

      min_value = attributes.find { |attr| attr.id.id == 0x0001_u32 }
      min_value.should_not be_nil
      min_value.as(Matter::Cluster::AttributeMetadata).name.should eq("minMeasuredValue")

      max_value = attributes.find { |attr| attr.id.id == 0x0002_u32 }
      max_value.should_not be_nil
      max_value.as(Matter::Cluster::AttributeMetadata).name.should eq("maxMeasuredValue")

      tolerance = attributes.find { |attr| attr.id.id == 0x0003_u32 }
      tolerance.should_not be_nil
      tolerance.as(Matter::Cluster::AttributeMetadata).name.should eq("tolerance")
    end

    it "reads MeasuredValue attribute when set" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16 # 20.00°C
      )

      read(cluster, 0x0000_u32).should eq(2000)
    end

    it "reads MeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::TemperatureMeasurement)

      read(cluster, 0x0000_u32).should be_nil
    end

    it "reads MinMeasuredValue attribute" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        min_measured_value: -2000_i16
      )

      read(cluster, 0x0001_u32).should eq(-2000)
    end

    it "reads MaxMeasuredValue attribute" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        max_measured_value: 12500_i16
      )

      read(cluster, 0x0002_u32).should eq(12500)
    end

    it "reads Tolerance attribute when set" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        tolerance: 100_u16
      )

      read(cluster, 0x0003_u32).should eq(100)
    end

    it "returns unsupported for Tolerance when not set" do
      cluster = build(Matter::Cluster::TemperatureMeasurement)

      read_status(cluster, 0x0003_u32).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedAttribute
      )
    end
  end

  describe "update_temperature" do
    it "updates temperature value" do
      cluster = build(Matter::Cluster::TemperatureMeasurement)

      cluster.update_temperature(2550_i16)
      cluster.measured_value.should eq(2550_i16)
    end

    it "accepts nil to indicate unknown temperature" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16
      )

      cluster.update_temperature(nil)
      cluster.measured_value.should be_nil
    end

    it "rejects temperature below minimum" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        min_measured_value: 0_i16,
        max_measured_value: 5000_i16
      )

      expect_raises(ArgumentError, /outside measurable range/) do
        cluster.update_temperature(-100_i16)
      end
    end

    it "rejects temperature above maximum" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        min_measured_value: 0_i16,
        max_measured_value: 5000_i16
      )

      expect_raises(ArgumentError, /outside measurable range/) do
        cluster.update_temperature(6000_i16)
      end
    end

    it "calls callback when temperature changes" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16
      )

      old_value : Int16? = nil
      new_value : Int16? = nil

      cluster.on_temperature_changed do |old, new|
        old_value = old
        new_value = new
      end

      cluster.update_temperature(2500_i16)

      old_value.should eq(2000_i16)
      new_value.should eq(2500_i16)
    end

    it "does not call callback when temperature doesn't change" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16
      )

      callback_called = false

      cluster.on_temperature_changed do |_, _|
        callback_called = true
      end

      cluster.update_temperature(2000_i16)

      callback_called.should be_false
    end

    it "increments data version when temperature changes" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16
      )

      initial_version = cluster.data_version

      cluster.update_temperature(2500_i16)

      cluster.data_version.should eq(initial_version + 1)
    end

    it "notifies attribute change subscribers when temperature changes" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16
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

      cluster.update_temperature(2500_i16)

      notified.should be_true
      notified_endpoint.should eq(1_u16)
      notified_cluster.should eq(Matter::Cluster::TemperatureMeasurement::CLUSTER_ID)
      notified_attribute.should eq(Matter::Cluster::TemperatureMeasurement::ATTR_MEASURED_VALUE)
    end

    it "does not notify attribute change subscribers when temperature is unchanged" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16
      )

      notifications = 0
      cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
        notifications += 1
      }

      cluster.update_temperature(2000_i16)

      notifications.should eq(0)
    end

    it "does not increment data version when temperature doesn't change" do
      cluster = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2000_i16
      )

      initial_version = cluster.data_version

      cluster.update_temperature(2000_i16)

      cluster.data_version.should eq(initial_version)
    end
  end

  describe "temperature conversion helpers" do
    it "converts from 0.01°C to Celsius" do
      Matter::Cluster::TemperatureMeasurement.to_celsius(2550_i16).should be_close(25.50, 0.01)
      Matter::Cluster::TemperatureMeasurement.to_celsius(0_i16).should be_close(0.0, 0.01)
      Matter::Cluster::TemperatureMeasurement.to_celsius(-1500_i16).should be_close(-15.0, 0.01)
    end

    it "converts from Celsius to 0.01°C" do
      Matter::Cluster::TemperatureMeasurement.from_celsius(25.50).should eq(2550_i16)
      Matter::Cluster::TemperatureMeasurement.from_celsius(0.0).should eq(0_i16)
      Matter::Cluster::TemperatureMeasurement.from_celsius(-15.0).should eq(-1500_i16)
    end

    it "converts from 0.01°C to Fahrenheit" do
      Matter::Cluster::TemperatureMeasurement.to_fahrenheit(2550_i16).should be_close(77.9, 0.1)
      Matter::Cluster::TemperatureMeasurement.to_fahrenheit(0_i16).should be_close(32.0, 0.1)
      Matter::Cluster::TemperatureMeasurement.to_fahrenheit(-1500_i16).should be_close(5.0, 0.1)
    end

    it "converts from Fahrenheit to 0.01°C" do
      Matter::Cluster::TemperatureMeasurement.from_fahrenheit(77.9).should be_close(2550_i16, 2)
      Matter::Cluster::TemperatureMeasurement.from_fahrenheit(32.0).should eq(0_i16)
      Matter::Cluster::TemperatureMeasurement.from_fahrenheit(5.0).should be_close(-1500_i16, 1)
    end
  end

  describe "practical scenarios" do
    it "models a room temperature sensor" do
      sensor = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2200_i16,      # 22.00°C
        min_measured_value: -1000_i16, # -10.00°C
        max_measured_value: 5000_i16,  # 50.00°C
        tolerance: 50_u16              # ±0.50°C
      )

      # Simulating temperature changes
      changes = [] of {Int16?, Int16?}

      sensor.on_temperature_changed do |old, new|
        changes << {old, new}
      end

      # Room warms up
      sensor.update_temperature(2250_i16) # 22.50°C
      sensor.update_temperature(2300_i16) # 23.00°C
      sensor.update_temperature(2350_i16) # 23.50°C

      changes.size.should eq(3)
      changes[0].should eq({2200_i16, 2250_i16})
      changes[1].should eq({2250_i16, 2300_i16})
      changes[2].should eq({2300_i16, 2350_i16})
    end

    it "models an outdoor temperature sensor with wide range" do
      sensor = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 1500_i16,      # 15.00°C
        min_measured_value: -4000_i16, # -40.00°C
        max_measured_value: 6000_i16,  # 60.00°C
        tolerance: 100_u16             # ±1.00°C
      )

      # Test extreme cold
      sensor.update_temperature(-3500_i16) # -35.00°C
      sensor.measured_value.should eq(-3500_i16)

      # Test extreme heat
      sensor.update_temperature(5500_i16) # 55.00°C
      sensor.measured_value.should eq(5500_i16)
    end

    it "handles sensor failure (unknown temperature)" do
      sensor = build(Matter::Cluster::TemperatureMeasurement,
        measured_value: 2200_i16
      )

      # Sensor reports normal temperature
      sensor.measured_value.should eq(2200_i16)

      # Sensor fails and reports unknown
      sensor.update_temperature(nil)
      sensor.measured_value.should be_nil

      # Sensor recovers
      sensor.update_temperature(2200_i16)
      sensor.measured_value.should eq(2200_i16)
    end

    it "works with Fahrenheit using conversion helpers" do
      sensor = build(Matter::Cluster::TemperatureMeasurement)

      # Set temperature in Fahrenheit
      fahrenheit_value = 72.0 # 72°F
      celsius_value = Matter::Cluster::TemperatureMeasurement.from_fahrenheit(fahrenheit_value)
      sensor.update_temperature(celsius_value)

      # Read back in Fahrenheit
      measured = sensor.measured_value.as(Int16)
      result_fahrenheit = Matter::Cluster::TemperatureMeasurement.to_fahrenheit(measured)
      result_fahrenheit.should be_close(72.0, 0.2)
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute" do
      cluster = build(Matter::Cluster::TemperatureMeasurement)

      read_status(cluster, 0x9999_u32).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedAttribute
      )
    end
  end
end
