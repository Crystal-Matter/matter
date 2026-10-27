require "./support/console"
require "./support/main"

# Matter 1.6 Pressure Sensor exercising the Extended Pressure Measurement feature.
module MatterPressureSensor
  class Device < Matter::Device
    include Examples::Console

    MIN_PRESSURE       =   800_i16
    MAX_PRESSURE       =  1200_i16
    PRESSURE_TOLERANCE =    10_u16
    MIN_SCALED         =  8000_i16
    MAX_SCALED         = 12000_i16
    SCALED_TOLERANCE   =   100_u16
    PRESSURE_SCALE     =     -1_i8

    identity vendor: "Spider-Gazelle", product: "Crystal Pressure Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::PRESSURE_SENSOR,
      appearance: :satin

    storage yaml: "matter_pressure_sensor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::PRESSURE_SENSOR do
      cluster Matter::Cluster::PressureMeasurement,
        feature_map: Matter::Cluster::PressureMeasurement::Feature::Extended,
        measured_value: 1013_i16,
        min_measured_value: MIN_PRESSURE,
        max_measured_value: MAX_PRESSURE,
        tolerance: PRESSURE_TOLERANCE,
        scaled_value: 10130_i16,
        min_scaled_value: MIN_SCALED,
        max_scaled_value: MAX_SCALED,
        scaled_tolerance: SCALED_TOLERANCE,
        scale: PRESSURE_SCALE,
        as: :pressure
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example Pressure")]
    end

    def console_notes : Array(String)
      ["Device Type: Pressure Sensor"]
    end

    def state_details : Nil
      puts "  Pressure: #{pressure.measured_value} (0.1 kPa)"
      puts "  Scaled pressure: #{pressure.scaled_value} (10^Scale Pa)"
    end
  end
end

Examples.main("Matter Pressure Sensor Device") { MatterPressureSensor::Device.new }
