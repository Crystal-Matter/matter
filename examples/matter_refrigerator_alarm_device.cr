require "./support/console"
require "./support/main"

# Synthetic cabinet door alarm. A real appliance reports the door condition
# after its vendor-defined open duration has elapsed.
module MatterRefrigeratorAlarm
  alias Alarm = Matter::Cluster::RefrigeratorAlarm
  alias Mode = Matter::Cluster::RefrigeratorAndTemperatureControlledCabinetMode
  alias ModeBase = Matter::Cluster::ModeBase
  alias TemperatureControl = Matter::Cluster::TemperatureControl

  MODES = [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(0_u16)]),
    ModeBase::Option.new("Rapid Cool", 1_u8, [ModeBase::Tag.new(Mode::ModeTag::RapidCool.value)]),
  ]

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Refrigerator Alarm",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0057_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::REFRIGERATOR

    storage yaml: "matter_refrigerator_alarm_storage.yml"

    endpoint 1, device_type: [Matter::DeviceType::REFRIGERATOR,
                              Matter::DeviceType::TEMPERATURE_CONTROLLED_CABINET] do
      cluster Alarm
      cluster Mode, supported_modes: MODES, current_mode: 0_u8
      cluster TemperatureControl
    end

    protected def before_start : Nil
      node.get_cluster!(1_u16, TemperatureControl).on_set_temperature do |target, _level|
        target ? Matter::InteractionModel::Status.success : Matter::InteractionModel::Status.invalid_command
      end
      node.get_cluster!(1_u16, Alarm).report_alarms(Alarm::AlarmBitmap::DoorOpen)
      super
    end
  end
end

Examples.main("Synthetic Refrigerator Alarm") { MatterRefrigeratorAlarm::Device.new }
