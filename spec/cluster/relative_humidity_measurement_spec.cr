require "../spec_helper"
require "../../src/matter/cluster/relative_humidity_measurement"

describe Matter::Cluster::RelativeHumidityMeasurement do
  describe "initialization" do
    it "creates humidity measurement cluster with defaults" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement)

      cluster.cluster_id.id.should eq(0x0405_u32)
      cluster.name.should eq("RelativeHumidityMeasurement")
      cluster.measured_value.should be_nil
      cluster.min_measured_value.should be_nil
      cluster.max_measured_value.should be_nil
      cluster.tolerance.should eq(0_u16)
    end

    it "creates with custom values" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5500_u16,     # 55.00%
        min_measured_value: 1000_u16, # 10.00%
        max_measured_value: 9500_u16, # 95.00%
        tolerance: 200_u16            # ±2.00%
      )

      cluster.measured_value.should eq(5500_u16)
      cluster.min_measured_value.should eq(1000_u16)
      cluster.max_measured_value.should eq(9500_u16)
      cluster.tolerance.should eq(200_u16)
    end

    it "rejects min_measured_value above 9999" do
      expect_raises(ArgumentError, /min_measured_value must be <= 9999/) do
        build(Matter::Cluster::RelativeHumidityMeasurement,
          min_measured_value: 10000_u16
        )
      end
    end

    it "accepts max_measured_value at absolute maximum" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        max_measured_value: 10000_u16
      )

      cluster.max_measured_value.should eq(10000_u16)
    end

    it "accepts an undefined bound independently of the other bound" do
      lower_only = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 10000_u16, min_measured_value: 9999_u16)
      upper_only = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 0_u16, max_measured_value: 0_u16)

      lower_only.max_measured_value.should be_nil
      upper_only.min_measured_value.should be_nil
    end

    it "rejects a reading above the absolute limit with undefined bounds" do
      expect_raises(ArgumentError, /measured_value must be between min and max/) do
        build(Matter::Cluster::RelativeHumidityMeasurement,
          measured_value: 10001_u16)
      end
    end

    it "rejects min >= max" do
      expect_raises(ArgumentError, /min_measured_value must be < max_measured_value/) do
        build(Matter::Cluster::RelativeHumidityMeasurement,
          min_measured_value: 8000_u16,
          max_measured_value: 5000_u16
        )
      end
      expect_raises(ArgumentError, /min_measured_value must be < max_measured_value/) do
        build(Matter::Cluster::RelativeHumidityMeasurement,
          min_measured_value: 5000_u16,
          max_measured_value: 5000_u16
        )
      end
    end

    it "rejects measured_value outside range" do
      expect_raises(ArgumentError, /measured_value must be between min and max/) do
        build(Matter::Cluster::RelativeHumidityMeasurement,
          measured_value: 9500_u16,
          min_measured_value: 1000_u16,
          max_measured_value: 8000_u16
        )
      end
    end

    it "rejects tolerance above maximum" do
      expect_raises(ArgumentError, /tolerance must be <= 2048/) do
        build(Matter::Cluster::RelativeHumidityMeasurement,
          tolerance: 3000_u16
        )
      end
    end
  end

  describe "attributes" do
    it "advertises revision 5 nullable fixed limits and fixed nonnullable tolerance" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement, tolerance: 0_u16)

      cluster.cluster_revision.should eq(5_u16)
      min = cluster.attributes.find! { |attr| attr.id.id == 0x0001_u32 }
      max = cluster.attributes.find! { |attr| attr.id.id == 0x0002_u32 }
      tolerance = cluster.attributes.find! { |attr| attr.id.id == 0x0003_u32 }
      min.fixed?.should be_true
      max.fixed?.should be_true
      tolerance.fixed?.should be_true
      tolerance.optional?.should be_true
      read(cluster, 0x0003_u32).should eq(0_u16)
    end

    it "reads undefined sensor limits as null" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement)

      read(cluster, 0x0001_u32).should be_nil
      read(cluster, 0x0002_u32).should be_nil
    end

    it "keeps fixed sensor limits and tolerance unchanged after construction" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        min_measured_value: 1000_u16, max_measured_value: 9000_u16, tolerance: 100_u16)
      initial_version = cluster.data_version

      expect_raises(ArgumentError, /fixed/) { cluster.min_measured_value = 2000_u16 }
      expect_raises(ArgumentError, /fixed/) { cluster.max_measured_value = nil }
      expect_raises(ArgumentError, /fixed/) { cluster.tolerance = 200_u16 }
      cluster.min_measured_value.should eq(1000_u16)
      cluster.max_measured_value.should eq(9000_u16)
      cluster.tolerance.should eq(100_u16)
      cluster.data_version.should eq(initial_version)
    end

    it "has required attributes" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement, tolerance: 0_u16)

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
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 4500_u16 # 45.00%
      )

      read(cluster, 0x0000_u32).should eq(4500)
    end

    it "reads MeasuredValue as null when not set" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement)

      read(cluster, 0x0000_u32).should be_nil
    end

    it "reads MinMeasuredValue attribute" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        min_measured_value: 2000_u16
      )

      read(cluster, 0x0001_u32).should eq(2000)
    end

    it "reads MaxMeasuredValue attribute" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        max_measured_value: 9500_u16
      )

      read(cluster, 0x0002_u32).should eq(9500)
    end

    it "reads Tolerance attribute when set" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        tolerance: 150_u16
      )

      read(cluster, 0x0003_u32).should eq(150_u16)
    end

    it "returns unsupported for Tolerance when not set" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement)

      read_status(cluster, 0x0003_u32).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedAttribute
      )
    end
  end

  describe "update_humidity" do
    it "validates direct host assignments before changing state or data version" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16, min_measured_value: 1000_u16, max_measured_value: 9000_u16)
      initial_version = cluster.data_version

      expect_raises(ArgumentError, /outside measurable range/) { cluster.measured_value = 9500_u16 }
      cluster.measured_value.should eq(5000_u16)
      cluster.data_version.should eq(initial_version)
    end

    it "applies absolute limits when a nullable sensor bound is undefined" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        min_measured_value: nil, max_measured_value: nil)

      cluster.update_humidity(0_u16)
      cluster.update_humidity(10000_u16)
      expect_raises(ArgumentError, /outside measurable range/) { cluster.measured_value = 10001_u16 }
    end

    it "updates humidity value" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement)

      cluster.update_humidity(6000_u16)
      cluster.measured_value.should eq(6000_u16)
    end

    it "accepts nil to indicate unknown humidity" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16
      )

      cluster.update_humidity(nil)
      cluster.measured_value.should be_nil
    end

    it "rejects humidity below minimum" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        min_measured_value: 1000_u16,
        max_measured_value: 9000_u16
      )

      expect_raises(ArgumentError, /outside measurable range/) do
        cluster.update_humidity(500_u16)
      end
    end

    it "rejects humidity above maximum" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        min_measured_value: 1000_u16,
        max_measured_value: 9000_u16
      )

      expect_raises(ArgumentError, /outside measurable range/) do
        cluster.update_humidity(9500_u16)
      end
    end

    it "calls callback when humidity changes" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16
      )

      old_value : UInt16? = nil
      new_value : UInt16? = nil

      cluster.on_humidity_changed do |old, new|
        old_value = old
        new_value = new
      end

      cluster.update_humidity(5500_u16)

      old_value.should eq(5000_u16)
      new_value.should eq(5500_u16)
    end

    it "does not call callback when humidity doesn't change" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16
      )

      callback_called = false

      cluster.on_humidity_changed do |_, _|
        callback_called = true
      end

      cluster.update_humidity(5000_u16)

      callback_called.should be_false
    end

    it "increments data version when humidity changes" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16
      )

      initial_version = cluster.data_version

      cluster.update_humidity(5500_u16)

      cluster.data_version.should eq(initial_version + 1)
    end

    it "notifies attribute subscribers when humidity changes" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
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

      cluster.update_humidity(5500_u16)

      notified.should be_true
      notified_endpoint.should eq(1_u16)
      notified_cluster.should eq(Matter::Cluster::RelativeHumidityMeasurement::CLUSTER_ID)
      notified_attribute.should eq(Matter::Cluster::RelativeHumidityMeasurement::ATTR_MEASURED_VALUE)
    end

    it "does not notify attribute subscribers when humidity is unchanged" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16
      )

      notifications = 0
      cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
        notifications += 1
      }

      cluster.update_humidity(5000_u16)

      notifications.should eq(0)
    end

    it "does not increment data version when humidity doesn't change" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16
      )

      initial_version = cluster.data_version

      cluster.update_humidity(5000_u16)

      cluster.data_version.should eq(initial_version)
    end
  end

  describe "humidity conversion helpers" do
    it "converts from 0.01% to percent" do
      Matter::Cluster::RelativeHumidityMeasurement.to_percent(5500_u16).should be_close(55.0, 0.01)
      Matter::Cluster::RelativeHumidityMeasurement.to_percent(0_u16).should be_close(0.0, 0.01)
      Matter::Cluster::RelativeHumidityMeasurement.to_percent(10000_u16).should be_close(100.0, 0.01)
    end

    it "converts from percent to 0.01%" do
      Matter::Cluster::RelativeHumidityMeasurement.from_percent(55.0).should eq(5500_u16)
      Matter::Cluster::RelativeHumidityMeasurement.from_percent(0.0).should eq(0_u16)
      Matter::Cluster::RelativeHumidityMeasurement.from_percent(100.0).should eq(10000_u16)
    end

    it "rejects negative percent values" do
      expect_raises(ArgumentError, /must be between 0 and 100/) do
        Matter::Cluster::RelativeHumidityMeasurement.from_percent(-5.0)
      end
    end

    it "rejects percent values above 100" do
      expect_raises(ArgumentError, /must be between 0 and 100/) do
        Matter::Cluster::RelativeHumidityMeasurement.from_percent(105.0)
      end
    end
  end

  describe "practical scenarios" do
    it "models an indoor humidity sensor" do
      sensor = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 4500_u16,     # 45.00%
        min_measured_value: 1000_u16, # 10.00%
        max_measured_value: 9500_u16, # 95.00%
        tolerance: 200_u16            # ±2.00%
      )

      # Simulating humidity changes
      changes = [] of {UInt16?, UInt16?}

      sensor.on_humidity_changed do |old, new|
        changes << {old, new}
      end

      # Humidity increases
      sensor.update_humidity(5000_u16) # 50.00%
      sensor.update_humidity(5500_u16) # 55.00%
      sensor.update_humidity(6000_u16) # 60.00%

      changes.size.should eq(3)
      changes[0].should eq({4500_u16, 5000_u16})
      changes[1].should eq({5000_u16, 5500_u16})
      changes[2].should eq({5500_u16, 6000_u16})
    end

    it "models a greenhouse humidity sensor with wide range" do
      sensor = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 7000_u16,     # 70.00%
        min_measured_value: 2000_u16, # 20.00%
        max_measured_value: 9800_u16, # 98.00%
        tolerance: 300_u16            # ±3.00%
      )

      # Test low humidity
      sensor.update_humidity(2500_u16) # 25.00%
      sensor.measured_value.should eq(2500_u16)

      # Test high humidity
      sensor.update_humidity(9500_u16) # 95.00%
      sensor.measured_value.should eq(9500_u16)
    end

    it "handles sensor failure (unknown humidity)" do
      sensor = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 5000_u16
      )

      # Sensor reports normal humidity
      sensor.measured_value.should eq(5000_u16)

      # Sensor fails and reports unknown
      sensor.update_humidity(nil)
      sensor.measured_value.should be_nil

      # Sensor recovers
      sensor.update_humidity(5000_u16)
      sensor.measured_value.should eq(5000_u16)
    end

    it "works with conversion helpers" do
      sensor = build(Matter::Cluster::RelativeHumidityMeasurement)

      # Set humidity in percent
      percent_value = 62.5
      encoded_value = Matter::Cluster::RelativeHumidityMeasurement.from_percent(percent_value)
      sensor.update_humidity(encoded_value)

      # Read back in percent
      measured = sensor.measured_value.as(UInt16)
      result_percent = Matter::Cluster::RelativeHumidityMeasurement.to_percent(measured)
      result_percent.should be_close(62.5, 0.01)
    end

    it "models a bathroom humidity sensor tracking shower use" do
      sensor = build(Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: 4500_u16, # 45.00% - normal
        min_measured_value: 2000_u16,
        max_measured_value: 9500_u16,
        tolerance: 200_u16
      )

      # Before shower
      sensor.measured_value.should eq(4500_u16)

      # During shower - humidity rises
      sensor.update_humidity(7000_u16) # 70.00%
      sensor.update_humidity(8000_u16) # 80.00%
      sensor.update_humidity(8500_u16) # 85.00%

      # After shower - humidity drops
      sensor.update_humidity(7500_u16) # 75.00%
      sensor.update_humidity(6500_u16) # 65.00%
      sensor.update_humidity(5000_u16) # 50.00%

      # Returns to normal
      sensor.measured_value.should eq(5000_u16)
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute" do
      cluster = build(Matter::Cluster::RelativeHumidityMeasurement)

      read_status(cluster, 0x9999_u32).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedAttribute
      )
    end
  end
end
