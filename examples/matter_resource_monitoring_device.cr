require "./support/console"
require "./support/main"

# Synthetic appliance resources. A real host confirms replacement/refill in
# on_reset_condition before the server reports success to a controller.
module MatterResourceMonitoring
  alias Resource = Matter::Cluster::ResourceMonitoring
  alias Hepa = Matter::Cluster::HepaFilterMonitoring
  alias Carbon = Matter::Cluster::ActivatedCarbonFilterMonitoring
  alias WaterTank = Matter::Cluster::WaterTankLevelMonitoring

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Resource Monitor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_resource_monitoring_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Hepa,
        feature_map: Hepa::Feature::Condition | Hepa::Feature::Warning | Hepa::Feature::ReplacementProductList,
        condition: 10_u8,
        change_indication: Resource::ChangeIndication::Critical,
        in_place_indicator_supported: true,
        last_changed_time_supported: true,
        reset_condition_supported: true,
        replacement_product_list: [Resource::ReplacementProduct.new(Resource::ProductIdentifierType::Upc, "123456789012")]
    end

    endpoint 2, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Carbon,
        feature_map: Carbon::Feature::Condition | Carbon::Feature::Warning,
        condition: 90_u8,
        degradation_direction: Resource::DegradationDirection::Up,
        change_indication: Resource::ChangeIndication::Critical,
        reset_condition_supported: true
    end

    endpoint 3, device_type: Matter::DeviceType::AGGREGATOR do
      cluster WaterTank, change_indication: Resource::ChangeIndication::Critical
    end

    protected def before_start : Nil
      node.get_cluster!(1_u16, Hepa).on_reset_condition { Matter::InteractionModel::Status.success }
      node.get_cluster!(2_u16, Carbon).on_reset_condition { Matter::InteractionModel::Status.success }
      super
    end
  end
end

Examples.main("Synthetic Resource Monitoring") { MatterResourceMonitoring::Device.new }
