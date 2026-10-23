require "./support/console"
require "./support/main"

# Synthetic Mode Base derivations on an Aggregator endpoint. Real appliances
# would connect mode changes to physical cycle controls through the callback.
module MatterApplianceModes
  alias ModeBase = Matter::Cluster::ModeBase
  alias DishwasherMode = Matter::Cluster::DishwasherMode
  alias LaundryWasherMode = Matter::Cluster::LaundryWasherMode

  DISHWASHER_MODES = [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Heavy", 1_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Heavy.value)]),
  ]

  LAUNDRY_MODES = [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Delicate", 1_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Delicate.value)]),
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
    end
  end
end

Examples.main("Synthetic Appliance Modes") { MatterApplianceModes::Device.new }
