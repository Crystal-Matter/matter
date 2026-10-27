require "./support/console"
require "./support/main"

# Synthetic dishwasher alarm. A real appliance reports physical conditions
# with report_alarms whenever its sensors change.
module MatterDishwasherAlarm
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x005D_u16

  alias Alarm = Matter::Cluster::DishwasherAlarm
  alias OperationalState = Matter::Cluster::OperationalState
  alias OnOff = Matter::Cluster::OnOff

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Dishwasher Alarm",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::DISHWASHER

    storage yaml: "matter_dishwasher_alarm_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::DISHWASHER do
      cluster OperationalState
      cluster OnOff, feature_map: OnOff::Feature::DeadFrontBehavior
      cluster Alarm,
        supported: Alarm::AlarmBitmap::DoorError | Alarm::AlarmBitmap::DrainError,
        feature_map: Alarm::Feature::Reset,
        latch: Alarm::AlarmBitmap::DoorError
    end

    protected def before_start : Nil
      node.get_cluster!(DEVICE_ENDPOINT_ID, Alarm).report_alarms(Alarm::AlarmBitmap::DoorError)
      super
    end
  end
end

Examples.main("Synthetic Dishwasher Alarm") { MatterDishwasherAlarm::Device.new }
