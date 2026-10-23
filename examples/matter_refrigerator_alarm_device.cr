require "./support/console"
require "./support/main"

# Synthetic cabinet door alarm. A real appliance reports the door condition
# after its vendor-defined open duration has elapsed.
module MatterRefrigeratorAlarm
  alias Alarm = Matter::Cluster::RefrigeratorAlarm

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Refrigerator Alarm",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0057_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_refrigerator_alarm_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Alarm
    end

    protected def before_start : Nil
      node.get_cluster!(1_u16, Alarm).report_alarms(Alarm::AlarmBitmap::DoorOpen)
      super
    end
  end
end

Examples.main("Synthetic Refrigerator Alarm") { MatterRefrigeratorAlarm::Device.new }
