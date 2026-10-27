require "./support/console"
require "./support/main"

# Matter Humidity Sensor Device Example
#
# - Presents as a Humidity Sensor (endpoint 1)
# - Samples a simulated relative humidity every 10 seconds
module MatterHumiditySensor
  class Device < Matter::Device
    include Examples::Console

    SAMPLE_INTERVAL = 10.seconds

    # Hundredths of a percent, as the cluster reports them.
    MIN_HUMIDITY = 3500_u16 # 35.00%
    MAX_HUMIDITY = 8000_u16 # 80.00%
    TOLERANCE    =  150_u16

    identity vendor: "Spider-Gazelle", product: "Crystal Humidity Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::HUMIDITY_SENSOR

    storage yaml: "matter_humidity_sensor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::HUMIDITY_SENSOR do
      cluster Matter::Cluster::RelativeHumidityMeasurement,
        measured_value: rand(MIN_HUMIDITY..MAX_HUMIDITY),
        min_measured_value: MIN_HUMIDITY,
        max_measured_value: MAX_HUMIDITY,
        tolerance: TOLERANCE,
        as: :humidity
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example Humidity")]
    end

    # A second endpoint exercises the standard Air Quality Sensor device type
    # and two derived concentration clusters over the same CASE session.
    endpoint 2, device_type: Matter::DeviceType::AIR_QUALITY_SENSOR do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::AirQuality, air_quality: Matter::Cluster::AirQuality::Level::Good
      cluster Matter::Cluster::CarbonDioxideConcentrationMeasurement,
        measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm,
        measured_value: 425.0_f32,
        min_measured_value: 0.0_f32,
        max_measured_value: 5000.0_f32
      cluster Matter::Cluster::CarbonMonoxideConcentrationMeasurement,
        level_value: Matter::Cluster::CarbonMonoxideConcentrationMeasurement::LevelValue::Low
    end

    on(:humidity, :humidity_changed) do |_old_value, new_value|
      notify "Humidity: #{format_humidity(new_value)}" if new_value
    end

    def console_notes : Array(String)
      ["Device Type: Humidity Sensor"]
    end

    def state_details : Nil
      puts "  Humidity: #{format_humidity(humidity.measured_value)}"
      puts "  Sample interval: #{SAMPLE_INTERVAL.total_seconds.to_i}s"
    end

    def status_details : Nil
      puts "  Humidity: #{format_humidity(humidity.measured_value)}"
    end

    def commands : Array(Tuple(String, String))
      [{"sample", "Sample the humidity now"}]
    end

    def handle_command(name : String, argument : String?) : Bool
      return false unless name == "sample"
      sample
      true
    end

    protected def on_started : Nil
      super
      every(SAMPLE_INTERVAL) { sample }
    end

    private def sample : Nil
      humidity.update_humidity(rand(MIN_HUMIDITY..MAX_HUMIDITY))
    end

    private def format_humidity(measured : UInt16?) : String
      return "unknown" unless measured
      "#{"%.2f" % Matter::Cluster::RelativeHumidityMeasurement.to_percent(measured)}%"
    end
  end
end

Examples.main("Matter Humidity Sensor Device") { MatterHumiditySensor::Device.new }
