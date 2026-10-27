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
  alias EnergyMode = Matter::Cluster::DeviceEnergyManagementMode
  alias EvseMode = Matter::Cluster::EnergyEvseMode
  alias Evse = Matter::Cluster::EnergyEvse

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

  ENERGY_MODES = [
    ModeBase::Option.new("No optimization", 0_u8,
      [ModeBase::Tag.new(EnergyMode::ModeTag::NoOptimization.value)]),
    ModeBase::Option.new("Grid optimization", 1_u8,
      [ModeBase::Tag.new(EnergyMode::ModeTag::GridOptimization.value)]),
  ]

  EVSE_MODES = [
    ModeBase::Option.new("Manual", 0_u8,
      [ModeBase::Tag.new(EvseMode::ModeTag::Manual.value)]),
    ModeBase::Option.new("Time of use", 1_u8,
      [ModeBase::Tag.new(EvseMode::ModeTag::TimeOfUse.value)]),
  ]

  class Device < Matter::Device
    include Examples::Console

    # The E2E service alone enables the diagnostic event triggers.
    protected def general_diagnostics_test_enable_key : Bytes?
      ENV["MATTER_DIAGNOSTICS_TEST_ENABLE_KEY"]?.try(&.hexbytes)
    end

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
      cluster EnergyMode, supported_modes: ENERGY_MODES, current_mode: 0_u8
      cluster EvseMode, supported_modes: EVSE_MODES, current_mode: 0_u8
      cluster Evse, circuit_capacity: 32_000_i64
    end

    endpoint 2, device_type: Matter::DeviceType::MICROWAVE_OVEN do
      cluster OperationalState, countdown_time: 0_u32
      cluster MicrowaveOvenMode, supported_modes: MICROWAVE_MODES, current_mode: 0_u8,
        as: :device_microwave_mode
      cluster MicrowaveOvenControl, mode_cluster: device_microwave_mode, max_cook_time: 3600_u32,
        add_more_time: true
    end

    # Synthetic bidirectional EVSE for the opt-in V2X wire tests.
    endpoint 3, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Evse, circuit_capacity: 32_000_i64,
        feature_map: Evse::Feature::ChargingPreferences | Evse::Feature::V2x
    end

    # Synthetic EV SoC telemetry for the opt-in feature's wire tests.
    endpoint 4, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Evse, circuit_capacity: 32_000_i64,
        feature_map: Evse::Feature::ChargingPreferences | Evse::Feature::SocReporting
    end

    protected def before_start : Nil
      evse = node.get_cluster!(1_u16, Evse)
      evse.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) do
        Status.success
      end
      evse.on_disable = -> { Status.success }
      v2x = node.get_cluster!(3_u16, Evse)
      v2x.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) { Status.success }
      v2x.on_enable_discharging = ->(_until : UInt32?, _maximum : Int64) { Status.success }
      v2x.on_disable = -> { Status.success }
      soc = node.get_cluster!(4_u16, Evse)
      soc.report_soc(72_u8, 60_000_000_i64)
      diagnostics = node.get_cluster!(0_u16, Matter::Cluster::GeneralDiagnostics)
      diagnostics.on_test_event_trigger = ->(trigger : UInt64) do
        if trigger == 0x0099_0000_0000_0002_u64 # EV plugged in
          v2x.report_ev_connected(1_u32)
          true
        elsif trigger == 0x0099_0000_0000_0004_u64 # Charge demand
          v2x.report_transfer_started
          true
        elsif trigger == 0x0099_0000_0000_0005_u64 # Charge demand clear
          v2x.report_transfer_stopped(Evse::EnergyTransferStoppedReason::EvStopped, 1_000_i64)
          true
        elsif trigger == 0x0099_0000_0000_0080_u64 # Synthetic discharge demand
          v2x.report_discharge_started
          true
        elsif trigger == 0x0099_0000_0000_0081_u64 # Synthetic discharge demand clear
          v2x.report_discharge_stopped(Evse::EnergyTransferStoppedReason::EvStopped, 2_000_i64)
          true
        elsif trigger == 0x0099_0000_0000_0003_u64 # EV unplugged
          v2x.report_ev_disconnected(20_u32)
          true
        else
          false
        end
      end
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
