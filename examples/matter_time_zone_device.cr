require "./support/console"
require "./support/main"

# Synthetic root-node Time Synchronization server for official chip-tool E2E.
# It has no time-zone database; commissioners supply standard and DST offsets.
module MatterTimeZone
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Time Zone",
      vendor_id: 0xFFF1_u16,
      product_id: 0x1236_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_time_zone_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TimeSynchronization,
        feature_map: Matter::Cluster::TimeSynchronization::Feature::TimeZone |
                     Matter::Cluster::TimeSynchronization::Feature::NtpClient
    end

    def console_notes : Array(String)
      ["Synthetic Matter 1.6 TimeZone and NTPClient server for E2E only"]
    end
  end
end

Examples.main("Synthetic Time Zone") { MatterTimeZone::Device.new }
