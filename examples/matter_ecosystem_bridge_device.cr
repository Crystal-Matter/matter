require "./support/console"
require "./support/main"

# Synthetic, explicitly opt-in bridge fixture for official chip-tool coverage
# of the Matter 1.6 Ecosystem Information cluster. No ordinary bridge example
# advertises private name or location metadata by default.
module MatterEcosystemBridge
  BRIDGED_LIGHT_ENDPOINT_ID = 1_u16

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Ecosystem Bridge",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_ecosystem_bridge_storage.yml"

    endpoint Matter::Node::ROOT_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR

    endpoint_template :synthetic_light,
      device_type: [Matter::DeviceType::ON_OFF_LIGHT, Matter::DeviceType::BRIDGED_NODE],
      parameters: {name: String, unique_id: String} do
      cluster Matter::Cluster::OnOff
      cluster Matter::Cluster::BridgedDeviceBasicInformation,
        product_name: name, unique_id: unique_id
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::EcosystemInformation
    end

    protected def before_start : Nil
      add_endpoint(:synthetic_light, name: "Synthetic Lamp", unique_id: "synthetic-lamp-1") unless node.has_endpoint?(BRIDGED_LIGHT_ENDPOINT_ID)
      super
    end

    protected def fabric_added(fabric : Matter::Fabric) : Nil
      index = fabric.fabric_index
      location_id = "synthetic-room-#{index}"
      device_types = [
        Matter::Cluster::EcosystemInformation::DeviceTypeStruct.new(
          Matter::DeviceType::ON_OFF_LIGHT, Matter::DeviceType.for(Matter::DeviceType::ON_OFF_LIGHT).revision),
        Matter::Cluster::EcosystemInformation::DeviceTypeStruct.new(
          Matter::DeviceType::BRIDGED_NODE, Matter::DeviceType.for(Matter::DeviceType::BRIDGED_NODE).revision),
      ]
      device = Matter::Cluster::EcosystemInformation::EcosystemDeviceStruct.new(
        device_name: "Synthetic lamp fabric #{index}",
        device_name_last_edit: 1_u64,
        bridged_endpoint: BRIDGED_LIGHT_ENDPOINT_ID,
        original_endpoint: nil,
        device_types: device_types,
        unique_location_ids: [location_id],
        unique_location_ids_last_edit: 1_u64,
        fabric_index: index
      )
      location = Matter::Cluster::EcosystemInformation::EcosystemLocationStruct.new(
        unique_location_id: location_id,
        location_descriptor: Matter::Cluster::EcosystemInformation::LocationDescriptorStruct.new(
          "Synthetic kitchen fabric #{index}", 0_i16, nil),
        location_descriptor_last_edit: 1_u64,
        fabric_index: index
      )
      node.endpoint!(BRIDGED_LIGHT_ENDPOINT_ID).get_cluster!(Matter::Cluster::EcosystemInformation).publish(index, [device], [location])
    end
  end
end

Examples.main("Synthetic Ecosystem Bridge") { MatterEcosystemBridge::Device.new }
