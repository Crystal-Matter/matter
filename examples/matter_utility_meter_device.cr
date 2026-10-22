require "./support/console"
require "./support/main"

# Synthetic electricity meter identity. A real host obtains these identifiers
# and contractual limits from its metering backend.
module MatterUtilityMeter
  alias Meter = Matter::Cluster::MeterIdentification

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Utility Meter",
      vendor_id: 0xFFF1_u16,
      product_id: 0x0511_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_utility_meter_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::ELECTRICAL_UTILITY_METER do
      cluster Meter,
        feature_map: Meter::Feature::PowerThreshold,
        meter_type: Meter::MeterType::Utility,
        point_of_delivery: "AU-NSW-POD-001",
        meter_serial_number: "MTR-2026-001",
        protocol_version: "DLMS/COSEM 1.0",
        power_threshold: Meter::PowerThreshold.new(
          power_threshold: 12_000_i64,
          apparent_power_threshold: 15_000_i64,
          power_threshold_source: Meter::PowerThresholdSource::Contract)
    end
  end
end

Examples.main("Synthetic Utility Meter") { MatterUtilityMeter::Device.new }
