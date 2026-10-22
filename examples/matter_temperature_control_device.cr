require "./support/console"
require "./support/main"

# Synthetic host-backed fixture for the two Matter 1.6 Temperature Control
# feature choices. A real appliance replaces these callbacks with its own
# physical controls and can refuse a command while a cycle is running.
module MatterTemperatureControl
  alias Control = Matter::Cluster::TemperatureControl
  alias Status = Matter::InteractionModel::Status

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Temperature Control",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_temperature_control_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Control,
        feature_map: Control::Feature::TemperatureNumber | Control::Feature::TemperatureStep,
        min_temperature: 1500_i16,
        max_temperature: 3500_i16,
        temperature_setpoint: 2000_i16,
        step: 50_i16
    end

    endpoint 2, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Control,
        feature_map: Control::Feature::TemperatureLevel,
        supported_temperature_levels: ["Cold", "Warm", "Hot"],
        selected_temperature_level: 1_u8
    end

    protected def before_start : Nil
      numeric = node.get_cluster!(1_u16, Control)
      numeric.on_set_temperature do |temperature, _level|
        # Refuse the hot extreme to demonstrate a real host acceptance gate.
        temperature == 3500_i16 ? Status.invalid_in_state : Status.success
      end
      levels = node.get_cluster!(2_u16, Control)
      levels.on_set_temperature do |_temperature, _level|
        Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Temperature Control") { MatterTemperatureControl::Device.new }
