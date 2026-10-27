require "./support/console"
require "./support/main"

# Matter Temperature Sensor Device Example
#
# - Presents as a Temperature Sensor (endpoint 1)
# - Endpoint 2 demonstrates unavailable capability bounds and absent Tolerance
# - Picks a random temperature in [15.0, 35.0] C every 10 seconds
module MatterTemperatureSensor
  class Device < Matter::Device
    include Examples::Console

    SAMPLE_INTERVAL = 10.seconds

    # Hundredths of a degree Celsius, as the cluster reports them.
    MIN_TEMPERATURE = 1500_i16
    MAX_TEMPERATURE = 3500_i16
    TOLERANCE       =   25_u16

    identity vendor: "Spider-Gazelle", product: "Crystal Temperature Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::TEMPERATURE_SENSOR,
      appearance: :satin

    storage yaml: "matter_temperature_sensor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::TEMPERATURE_SENSOR do
      cluster Matter::Cluster::TemperatureMeasurement,
        measured_value: rand(MIN_TEMPERATURE..MAX_TEMPERATURE),
        min_measured_value: MIN_TEMPERATURE,
        max_measured_value: MAX_TEMPERATURE,
        tolerance: TOLERANCE,
        as: :temperature
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example Temp")]
    end

    endpoint 2, device_type: Matter::DeviceType::TEMPERATURE_SENSOR do
      cluster Matter::Cluster::TemperatureMeasurement,
        measured_value: 2250_i16,
        min_measured_value: nil,
        max_measured_value: nil
      cluster Matter::Cluster::Identify, identify_type: :visible_light
    end

    on(:temperature, :temperature_changed) do |_old_value, new_value|
      next unless new_value
      notify "Temperature update: #{format_temperature(new_value)}",
        "Data version: #{temperature.data_version}"
    end

    def console_notes : Array(String)
      ["Device Type: Temperature Sensor"]
    end

    def state_details : Nil
      puts "  Temperature: #{format_temperature(temperature.measured_value)}"
      puts "  Configured range: #{format_temperature(MIN_TEMPERATURE)} .. #{format_temperature(MAX_TEMPERATURE)}"
      puts "  Sample interval: #{SAMPLE_INTERVAL.total_seconds.to_i}s"
      puts "  Data Version: #{temperature.data_version}"
    end

    def status_details : Nil
      puts "  Temperature: #{format_temperature(temperature.measured_value)}"
      puts "  Data Version: #{temperature.data_version}"
    end

    def commands : Array(Tuple(String, String))
      [{"sample", "Force an immediate temperature sample"}]
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
      temperature.update_temperature(rand(MIN_TEMPERATURE..MAX_TEMPERATURE))
    end

    private def format_temperature(centi_celsius : Int16?) : String
      return "unknown" unless centi_celsius
      "#{"%.2f" % Matter::Cluster::TemperatureMeasurement.to_celsius(centi_celsius)} C"
    end
  end
end

Examples.main("Matter Temperature Sensor Device") { MatterTemperatureSensor::Device.new }
