require "./support/console"
require "./support/main"

# Synthetic paired oven clusters. A real appliance connects mode selection and
# operation admission to its heating, door, and safety controllers.
module MatterOven
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x4849_u16

  alias ModeBase = Matter::Cluster::ModeBase
  alias OvenMode = Matter::Cluster::OvenMode
  alias OvenState = Matter::Cluster::OvenCavityOperationalState

  MODES = [
    ModeBase::Option.new("Bake", 0_u8, [ModeBase::Tag.new(OvenMode::ModeTag::Bake.value)]),
    ModeBase::Option.new("Roast", 1_u8, [ModeBase::Tag.new(OvenMode::ModeTag::Roast.value)]),
  ]

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Oven",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_oven_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster OvenMode, supported_modes: MODES, current_mode: MODES.first.mode
      cluster OvenState, supported_commands: [OvenState::Command::Stop, OvenState::Command::Start],
        phase_list: ["preheat", "cook"], current_phase: 0_u8, countdown_time: 120_u32
    end

    protected def before_start : Nil
      state = node.endpoint!(DEVICE_ENDPOINT_ID).get_cluster!(OvenState)
      state.on_command { |_command| OvenState::ErrorState.new(OvenState::NO_ERROR) }
      super
    end
  end
end

Examples.main("Synthetic Oven") { MatterOven::Device.new }
