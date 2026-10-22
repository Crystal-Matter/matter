require "./support/console"
require "./support/main"

# Matter Ambient Light Sensor Device Example
#
# - Presents as a Light Sensor (endpoint 1)
# - Samples a simulated illuminance every 10 seconds
module MatterAmbientLightSensor
  class Device < Matter::Device
    include Examples::Console

    SAMPLE_INTERVAL = 10.seconds

    MIN_LUX =   25.0
    MAX_LUX = 1500.0

    identity vendor: "Spider-Gazelle", product: "Crystal Ambient Light Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::LIGHT_SENSOR

    storage yaml: "matter_ambient_light_sensor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::LIGHT_SENSOR do
      cluster Matter::Cluster::IlluminanceMeasurement,
        measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(rand(MIN_LUX..MAX_LUX)),
        min_measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(1.0),
        max_measured_value: Matter::Cluster::IlluminanceMeasurement.from_lux(2000.0),
        tolerance: 0_u16,
        light_sensor_type: Matter::Cluster::IlluminanceMeasurement::LightSensorType::Photodiode,
        as: :illuminance
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example Ambient Light Sensor")]
    end

    on(:illuminance, :illuminance_changed) do |_old_value, new_value|
      notify "Ambient light: #{format_lux(new_value)}" if new_value
    end

    def console_notes : Array(String)
      ["Device Type: Light Sensor"]
    end

    def state_details : Nil
      puts "  Ambient light: #{format_lux(illuminance.measured_value)}"
      puts "  Sample interval: #{SAMPLE_INTERVAL.total_seconds.to_i}s"
    end

    def status_details : Nil
      puts "  Ambient light: #{format_lux(illuminance.measured_value)}"
    end

    def commands : Array(Tuple(String, String))
      [{"sample", "Sample the ambient light now"}]
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
      illuminance.update_illuminance(Matter::Cluster::IlluminanceMeasurement.from_lux(rand(MIN_LUX..MAX_LUX)))
    end

    private def format_lux(measured : UInt16?) : String
      return "unknown" unless measured
      "#{"%.1f" % Matter::Cluster::IlluminanceMeasurement.to_lux(measured)} lx"
    end
  end
end

Examples.main("Matter Ambient Light Sensor Device") { MatterAmbientLightSensor::Device.new }
