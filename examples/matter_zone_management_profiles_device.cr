require "./support/console"
require "./support/main"

# Synthetic sensor exposing both Matter 1.6 Zone Management optional profiles.
# A real host uses on_zone_change to apply focus/privacy geometry to its
# capture pipeline and calls report_motion with its detector's observations.
module MatterZoneManagementProfiles
  alias Zone = Matter::Cluster::ZoneManagement

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Zone Profiles",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0551_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_zone_management_profiles_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Zone, feature_map: Zone::Feature::TwoDCartesianZone |
                                 Zone::Feature::PerZoneSensitivity | Zone::Feature::UserDefined |
                                 Zone::Feature::FocusZones, as: :zone_management
    end

    protected def before_start : Nil
      zone_management.on_zone_change do |_previous, _current|
        Matter::InteractionModel::Status.success
      end
      zone_management.replay_zones_to_host!
      spawn do
        loop do
          sleep 1.second
          zone_management.triggers.each do |trigger|
            zone_management.report_motion(trigger.zone_id)
          end
        end
      end
      super
    end
  end
end

Examples.main("Crystal Zone Profiles") { MatterZoneManagementProfiles::Device.new }
