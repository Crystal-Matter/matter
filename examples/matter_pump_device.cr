require "./support/console"
require "./support/main"

# Synthetic constant-speed pump. A hardware host uses on_apply_mode to reject
# requests it cannot fulfill, then reports the observed effective mode.
module MatterPump
  alias Pump = Matter::Cluster::PumpConfigurationControl

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Pump",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0200_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_pump_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::PUMP do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::OnOff
      cluster Pump, max_speed: 3_600_u16, min_const_speed: 400_u16,
        max_const_speed: 3_600_u16, as: :pump
    end

    protected def before_start : Nil
      pump.on_apply_mode do |_operation, _control|
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Crystal Pump") { MatterPump::Device.new }
