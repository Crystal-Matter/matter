require "./support/console"
require "./support/main"

# A synthetic host-backed temperature alarm. A real sensor calls
# update_temperature whenever its physical reading changes.
module MatterTemperatureAlarm
  alias Alarm = Matter::Cluster::TemperatureAlarm
  alias Status = Matter::InteractionModel::Status

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Temperature Alarm",
      vendor_id: Matter::Fabric::DEFAULT_VENDOR_ID,
      product_id: 0x0064_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_temperature_alarm_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Alarm,
        feature_map: Alarm::Feature::OverTemperature |
                     Alarm::Feature::UnderTemperature |
                     Alarm::Feature::OverCriticalAdjustable |
                     Alarm::Feature::Reset,
        critical_over_temperature_threshold: 5000_i16,
        critical_under_temperature_threshold: -1000_i16,
        latch: Alarm::AlarmBitmap::CriticalOverTemperature
    end

    protected def before_start : Nil
      alarm = node.get_cluster!(1_u16, Alarm)
      alarm.on_set_thresholds { |_request| Status.success }
      alarm.update_temperature(4500_i16)
      super
    end
  end
end

Examples.main("Synthetic Temperature Alarm") { MatterTemperatureAlarm::Device.new }
