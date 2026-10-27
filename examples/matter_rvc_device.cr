require "./support/console"
require "./support/main"

# Synthetic robotic vacuum. A real host connects these callbacks to its
# motors, docking sensors, cleaning hardware, and safety interlocks.
module MatterRvc
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x4850_u16

  alias ModeBase = Matter::Cluster::ModeBase
  alias RunMode = Matter::Cluster::RvcRunMode
  alias CleanMode = Matter::Cluster::RvcCleanMode
  alias RvcState = Matter::Cluster::RvcOperationalState
  alias ServiceArea = Matter::Cluster::ServiceArea

  RUN_MODES = [
    ModeBase::Option.new("Idle", 0_u8, [ModeBase::Tag.new(RunMode::ModeTag::Idle.value)]),
    ModeBase::Option.new("Cleaning", 1_u8, [ModeBase::Tag.new(RunMode::ModeTag::Cleaning.value)]),
    ModeBase::Option.new("Mapping", 2_u8, [ModeBase::Tag.new(RunMode::ModeTag::Mapping.value)]),
  ]
  CLEAN_MODES = [
    ModeBase::Option.new("Vacuum", 0_u8, [ModeBase::Tag.new(CleanMode::ModeTag::Vacuum.value)]),
    ModeBase::Option.new("Mop", 1_u8, [ModeBase::Tag.new(CleanMode::ModeTag::Mop.value)]),
  ]
  AREAS = [
    ServiceArea::Area.new(1_u32, nil, ServiceArea::AreaInfo.new(ServiceArea::LocationInfo.new("Kitchen"))),
    ServiceArea::Area.new(2_u32, nil, ServiceArea::AreaInfo.new(ServiceArea::LocationInfo.new("Hall"))),
  ]

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic RVC",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROBOTIC_VACUUM_CLEANER

    storage yaml: "matter_rvc_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::ROBOTIC_VACUUM_CLEANER do
      cluster Matter::Cluster::Identify, identify_type: :audible_beep
      cluster RunMode, supported_modes: RUN_MODES, current_mode: RUN_MODES.first.mode, as: :run_mode
      cluster CleanMode, run_mode: run_mode, supported_modes: CLEAN_MODES, current_mode: CLEAN_MODES.first.mode, as: :clean_mode
      cluster RvcState, run_mode: run_mode,
        supported_commands: [RvcState::Command::Pause, RvcState::Command::Resume],
        go_home: true, as: :rvc_state
      cluster ServiceArea, areas: AREAS, reports_current_area: true, current_area: AREAS.first.area_id,
        skip_enabled: true, as: :service_area
    end

    protected def before_start : Nil
      run = node.endpoint!(DEVICE_ENDPOINT_ID).get_cluster!(RunMode)
      clean = node.endpoint!(DEVICE_ENDPOINT_ID).get_cluster!(CleanMode)
      state = node.endpoint!(DEVICE_ENDPOINT_ID).get_cluster!(RvcState)
      areas = node.endpoint!(DEVICE_ENDPOINT_ID).get_cluster!(ServiceArea)
      run.on_change_to_mode = ->(_previous : UInt8, selected : UInt8) do
        state.report_state(selected == run.idle_mode ? RvcState::STOPPED : RvcState::RUNNING)
        ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::Success)
      end
      clean.on_change_to_mode = ->(_previous : UInt8, _selected : UInt8) do
        ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::Success)
      end
      state.on_command { |_command| RvcState::ErrorState.new(RvcState::NO_ERROR) }
      state.on_go_home { RvcState::ErrorState.new(RvcState::NO_ERROR) }
      areas.on_operating { state.operational_state != RvcState::STOPPED }
      areas.on_skip do |_area_id|
        state.report_state(RvcState::STOPPED)
        ServiceArea::SkipAreaResponse.new(ServiceArea::SkipAreaStatus::Success)
      end
      super
    end
  end
end

Examples.main("Synthetic RVC") { MatterRvc::Device.new }
