require "./support/console"
require "./support/main"

# Synthetic combined detector. Real hardware must report sensor conditions,
# mounting, power-source faults, and expiry using the cluster host API.
module MatterSmokeCOAlarm
  SMOKE_CO_ENDPOINT_ID       = 1_u16
  EXTERNAL_POWER_ENDPOINT_ID = 2_u16
  BACKUP_BATTERY_ENDPOINT_ID = 3_u16

  EXAMPLE_PRODUCT_ID = 0x005C_u16

  alias Alarm = Matter::Cluster::SmokeCOAlarm
  alias Power = Matter::Cluster::PowerSource

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Smoke CO Alarm",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::SMOKE_CO_ALARM

    storage yaml: "matter_smoke_co_alarm_storage.yml"

    endpoint SMOKE_CO_ENDPOINT_ID, device_type: Matter::DeviceType::SMOKE_CO_ALARM do
      cluster Matter::Cluster::Identify
      cluster Alarm, feature_map: Alarm::Feature::SmokeAlarm | Alarm::Feature::CoAlarm,
        self_test_supported: true
    end

    endpoint EXTERNAL_POWER_ENDPOINT_ID, device_type: Matter::DeviceType::POWER_SOURCE do
      cluster Power, feature_map: Power::Feature::Wired,
        description: "Synthetic external power", wired_present: true,
        endpoint_list: [SMOKE_CO_ENDPOINT_ID]
    end

    endpoint BACKUP_BATTERY_ENDPOINT_ID, device_type: Matter::DeviceType::POWER_SOURCE do
      cluster Power, feature_map: Power::Feature::Battery | Power::Feature::Rechargeable | Power::Feature::Replaceable,
        description: "Synthetic backup battery", endpoint_list: [SMOKE_CO_ENDPOINT_ID],
        bat_charge_level: Power::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Power::BatReplaceability::UserReplaceable,
        bat_replacement_description: "Synthetic rechargeable pack", bat_quantity: 1_u8,
        bat_charge_state: Power::BatChargeState::IsAtFullCharge,
        bat_functional_while_charging: true
    end

    protected def before_start : Nil
      alarm = node.get_cluster!(SMOKE_CO_ENDPOINT_ID, Alarm)
      alarm.on_self_test do
        spawn do
          sleep 15.seconds
          alarm.complete_self_test
        end
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Smoke CO Alarm") { MatterSmokeCOAlarm::Device.new }
