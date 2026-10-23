require "./support/console"
require "./support/main"

# Synthetic Mode Base derivations on an Aggregator endpoint. Real appliances
# would connect mode changes to physical cycle controls through the callback.
module MatterApplianceModes
  alias ModeBase = Matter::Cluster::ModeBase
  alias DishwasherMode = Matter::Cluster::DishwasherMode
  alias LaundryWasherMode = Matter::Cluster::LaundryWasherMode
  alias MicrowaveOvenMode = Matter::Cluster::MicrowaveOvenMode
  alias MicrowaveOvenControl = Matter::Cluster::MicrowaveOvenControl
  alias OperationalState = Matter::Cluster::OperationalState
  alias Status = Matter::InteractionModel::Status

  DISHWASHER_MODES = [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Heavy", 1_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Heavy.value)]),
  ]

  LAUNDRY_MODES = [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Delicate", 1_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Delicate.value)]),
  ]

  MICROWAVE_MODES = [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(MicrowaveOvenMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Defrost", 1_u8, [ModeBase::Tag.new(MicrowaveOvenMode::ModeTag::Defrost.value)]),
  ]

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Appliance Modes",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x5159_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_appliance_modes_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster DishwasherMode, supported_modes: DISHWASHER_MODES, current_mode: 0_u8
      cluster LaundryWasherMode, supported_modes: LAUNDRY_MODES, current_mode: 0_u8
      cluster MicrowaveOvenMode, supported_modes: MICROWAVE_MODES, current_mode: 0_u8, as: :microwave_mode
      cluster MicrowaveOvenControl, mode_cluster: microwave_mode, max_cook_time: 3600_u32,
        add_more_time: true, as: :microwave_control
    end

    endpoint 2, device_type: Matter::DeviceType::MICROWAVE_OVEN do
      cluster OperationalState, countdown_time: 0_u32
      cluster MicrowaveOvenMode, supported_modes: MICROWAVE_MODES, current_mode: 0_u8,
        as: :device_microwave_mode
      cluster MicrowaveOvenControl, mode_cluster: device_microwave_mode, max_cook_time: 3600_u32,
        add_more_time: true
    end

    protected def before_start : Nil
      control = node.get_cluster!(1_u16, MicrowaveOvenControl)
      control.on_set_cooking_parameters do |_mode, _seconds, _power, _start|
        Status.success
      end
      control.on_add_more_time do |_seconds|
        Status.success
      end
      device_control = node.get_cluster!(2_u16, MicrowaveOvenControl)
      state = node.get_cluster!(2_u16, OperationalState)
      device_control.on_set_cooking_parameters do |_mode, seconds, _power, _start|
        state.update_countdown(seconds)
        Status.success
      end
      device_control.on_add_more_time do |seconds|
        state.update_countdown((state.countdown_time || 0_u32) + seconds)
        Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Appliance Modes") { MatterApplianceModes::Device.new }
