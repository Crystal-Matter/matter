require "./support/console"
require "./support/main"

# Synthetic region sensor on an Aggregator endpoint. A production Camera host
# must implement privacy masking and feed real activity into report_motion.
module MatterZoneManagement
  alias Zone = Matter::Cluster::ZoneManagement

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Zone Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0550_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_zone_management_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Zone, as: :zone_management
    end

    protected def before_start : Nil
      spawn do
        loop do
          sleep 1.second
          zone_management.triggers.each do |trigger|
            zone_management.report_motion(trigger.zone_id)
          end
        end
      end
      super
    end
  end
end

Examples.main("Crystal Zone Sensor") { MatterZoneManagement::Device.new }
