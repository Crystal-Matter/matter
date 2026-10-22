require "./support/console"
require "./support/main"

module MatterSoilSensor
  class Device < Matter::Device
    include Examples::Console

    SOIL_MIN        =  10_i64
    SOIL_MAX        =  90_i64
    ACCURACY_MAX    = 500_u16 # 5.00 percent
    INITIAL_READING =   42_u8

    SOIL_ACCURACY_RANGE = Matter::Cluster::ElectricalMeasurement::AccuracyRange.new(
      SOIL_MIN, SOIL_MAX, percent_max: ACCURACY_MAX)
    SOIL_ACCURACY = Matter::Cluster::ElectricalMeasurement::Accuracy.new(
      Matter::Cluster::ElectricalMeasurement::MeasurementType::SoilMoisture,
      true, SOIL_MIN, SOIL_MAX, [SOIL_ACCURACY_RANGE])

    identity vendor: "Spider-Gazelle", product: "Crystal Soil Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::SOIL_SENSOR

    storage yaml: "matter_soil_sensor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::SOIL_SENSOR do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::SoilMeasurement,
        accuracy: SOIL_ACCURACY,
        measured_value: INITIAL_READING,
        as: :soil
    end

    def console_notes : Array(String)
      ["Device Type: Soil Sensor"]
    end

    def state_details : Nil
      puts "  Soil moisture: #{soil.soil_moisture_measured_value}%"
    end

    def status_details : Nil
      state_details
    end

    def commands : Array(Tuple(String, String))
      [{"sample", "Set a soil moisture sample (10..90 percent)"}]
    end

    def handle_command(name : String, argument : String?) : Bool
      return false unless name == "sample"
      sample = argument.try(&.to_u8?)
      return true unless sample
      soil.update_soil_moisture(sample)
      true
    rescue ArgumentError
      notify "Soil moisture sample must be between #{SOIL_MIN} and #{SOIL_MAX} percent"
      true
    end
  end
end

Examples.main("Matter Soil Sensor Device") { MatterSoilSensor::Device.new }
