require "./support/console"
require "./support/main"

# Synthetic Mode Base derivations on an Aggregator endpoint. Real appliances
# would connect mode changes to physical cycle controls through the callback.
module MatterApplianceModes
  TEST_TRIGGER_EV_CONNECTED           = 0x0099_0000_0000_0002_u64
  TEST_TRIGGER_EV_DISCONNECTED        = 0x0099_0000_0000_0003_u64
  TEST_TRIGGER_CHARGE_DEMAND          = 0x0099_0000_0000_0004_u64
  TEST_TRIGGER_CHARGE_DEMAND_CLEAR    = 0x0099_0000_0000_0005_u64
  TEST_TRIGGER_DISCHARGE_DEMAND       = 0x0099_0000_0000_0080_u64
  TEST_TRIGGER_DISCHARGE_DEMAND_CLEAR = 0x0099_0000_0000_0081_u64
  AGGREGATOR_ENDPOINT_ID              =                     1_u16
  MICROWAVE_ENDPOINT_ID               =                     2_u16
  V2X_EVSE_ENDPOINT_ID                =                     3_u16
  SOC_EVSE_ENDPOINT_ID                =                     4_u16

  EXAMPLE_PRODUCT_ID = 0x5159_u16

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
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_appliance_modes_storage.yml"

    endpoint AGGREGATOR_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster DishwasherMode, supported_modes: DISHWASHER_MODES, current_mode: DISHWASHER_MODES.first.mode
      cluster LaundryWasherMode, supported_modes: LAUNDRY_MODES, current_mode: LAUNDRY_MODES.first.mode
      cluster MicrowaveOvenMode, supported_modes: MICROWAVE_MODES, current_mode: MICROWAVE_MODES.first.mode, as: :microwave_mode
      cluster MicrowaveOvenControl, mode_cluster: microwave_mode, max_cook_time: 3600_u32,
        add_more_time: true, as: :microwave_control
      cluster EnergyMode, supported_modes: ENERGY_MODES, current_mode: ENERGY_MODES.first.mode
      cluster EvseMode, supported_modes: EVSE_MODES, current_mode: EVSE_MODES.first.mode
      cluster Evse, circuit_capacity: 32_000_i64
    end

    endpoint MICROWAVE_ENDPOINT_ID, device_type: Matter::DeviceType::MICROWAVE_OVEN do
      cluster OperationalState, countdown_time: 0_u32
      cluster MicrowaveOvenMode, supported_modes: MICROWAVE_MODES, current_mode: MICROWAVE_MODES.first.mode,
        as: :device_microwave_mode
      cluster MicrowaveOvenControl, mode_cluster: device_microwave_mode, max_cook_time: 3600_u32,
        add_more_time: true
    end

    # Synthetic bidirectional EVSE for the opt-in V2X wire tests.
    endpoint V2X_EVSE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Evse, circuit_capacity: 32_000_i64,
        feature_map: Evse::Feature::ChargingPreferences | Evse::Feature::V2x
    end

    # Synthetic EV SoC telemetry for the opt-in feature's wire tests.
    endpoint SOC_EVSE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Evse, circuit_capacity: 32_000_i64,
        feature_map: Evse::Feature::ChargingPreferences | Evse::Feature::SocReporting
    end

    protected def before_start : Nil
      evse = node.get_cluster!(AGGREGATOR_ENDPOINT_ID, Evse)
      evse.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) do
        Status.success
      end
      evse.on_disable = -> { Status.success }
      v2x = node.get_cluster!(V2X_EVSE_ENDPOINT_ID, Evse)
      v2x.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) { Status.success }
      v2x.on_enable_discharging = ->(_until : UInt32?, _maximum : Int64) { Status.success }
      v2x.on_disable = -> { Status.success }
      soc = node.get_cluster!(SOC_EVSE_ENDPOINT_ID, Evse)
      soc.report_soc(72_u8, 60_000_000_i64)
      diagnostics = node.get_cluster!(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::GeneralDiagnostics)
      diagnostics.on_test_event_trigger = ->(trigger : UInt64) do
        if trigger == TEST_TRIGGER_EV_CONNECTED
          v2x.report_ev_connected(1_u32)
          true
        elsif trigger == TEST_TRIGGER_CHARGE_DEMAND
          v2x.report_transfer_started
          true
        elsif trigger == TEST_TRIGGER_CHARGE_DEMAND_CLEAR
          v2x.report_transfer_stopped(Evse::EnergyTransferStoppedReason::EvStopped, 1_000_i64)
          true
        elsif trigger == TEST_TRIGGER_DISCHARGE_DEMAND
          v2x.report_discharge_started
          true
        elsif trigger == TEST_TRIGGER_DISCHARGE_DEMAND_CLEAR
          v2x.report_discharge_stopped(Evse::EnergyTransferStoppedReason::EvStopped, 2_000_i64)
          true
        elsif trigger == TEST_TRIGGER_EV_DISCONNECTED
          v2x.report_ev_disconnected(20_u32)
          true
        else
          false
        end
      end
      control = node.get_cluster!(AGGREGATOR_ENDPOINT_ID, MicrowaveOvenControl)
      control.on_set_cooking_parameters do |_mode, _seconds, _power, _start|
        Status.success
      end
      control.on_add_more_time do |_seconds|
        Status.success
      end
      device_control = node.get_cluster!(MICROWAVE_ENDPOINT_ID, MicrowaveOvenControl)
      state = node.get_cluster!(MICROWAVE_ENDPOINT_ID, OperationalState)
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
