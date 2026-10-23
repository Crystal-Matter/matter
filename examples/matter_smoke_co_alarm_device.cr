require "./support/console"
require "./support/main"

# Synthetic combined detector. Real hardware must report sensor conditions,
# mounting, power-source faults, and expiry using the cluster host API.
module MatterSmokeCOAlarm
  alias Alarm = Matter::Cluster::SmokeCOAlarm

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Smoke CO Alarm",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x005C_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_smoke_co_alarm_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Alarm, feature_map: Alarm::Feature::SmokeAlarm | Alarm::Feature::CoAlarm,
        self_test_supported: true
    end

    protected def before_start : Nil
      alarm = node.get_cluster!(1_u16, Alarm)
      alarm.on_self_test do
        spawn do
          sleep 15.seconds
          alarm.complete_self_test
        end
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Smoke CO Alarm") { MatterSmokeCOAlarm::Device.new }
