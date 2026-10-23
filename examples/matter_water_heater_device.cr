require "./support/console"
require "./support/main"

# Synthetic water heater: the host callbacks stand in for physical heater and
# mode controls. Both Matter clusters share the endpoint with Thermostat.
module MatterWaterHeater
  alias Mode = Matter::Cluster::WaterHeaterMode
  alias Management = Matter::Cluster::WaterHeaterManagement
  alias Thermostat = Matter::Cluster::Thermostat
  alias Status = Matter::InteractionModel::Status

  OFF_MODE    = 0_u8
  MANUAL_MODE = 1_u8

  MODES = [
    Mode::ModeOption.new("Off", OFF_MODE, [Mode::ModeTag.new(Mode::Tag::Off)]),
    Mode::ModeOption.new("Manual", MANUAL_MODE, [Mode::ModeTag.new(Mode::Tag::Manual)]),
  ]

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Water Heater",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_water_heater_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Thermostat, feature_map: Thermostat::Feature::Heating,
        occupied_heating_setpoint: 6000_i16
      cluster Mode, supported_modes: MODES, current_mode: OFF_MODE
      cluster Management,
        feature_map: Management::Feature::EnergyManagement | Management::Feature::TankPercent,
        heater_types: Management::HeatSource::ImmersionElement1 | Management::HeatSource::HeatPump,
        tank_volume: 100_u16, estimated_heat_required: 4_000_000_i64,
        tank_percentage: 40_u8
    end

    protected def before_start : Nil
      mode = node.get_cluster!(1_u16, Mode)
      heater = node.get_cluster!(1_u16, Management)
      thermostat = node.get_cluster!(1_u16, Thermostat)

      mode.on_change_to_mode do |_requested|
        Mode::ChangeToModeResponse.new(Mode::ModeStatus::Success)
      end
      heater.on_boost do |info|
        if (setpoint = info.temporary_setpoint) &&
           (setpoint < thermostat.min_heat_setpoint_limit || setpoint > thermostat.max_heat_setpoint_limit)
          Status.constraint_error
        else
          heater.report_heat_demand(Management::HeatSource::ImmersionElement1)
          Status.success
        end
      end
      heater.on_cancel_boost do
        heater.report_heat_demand(Management::HeatSource::None)
        Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Water Heater") { MatterWaterHeater::Device.new }
