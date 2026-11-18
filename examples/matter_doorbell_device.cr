require "./support/console"
require "./support/main"

# Synthetic standalone Doorbell: emits one press after commissioning. Hosts
# supply the physical button and choose how to contact a Chime client.
module MatterDoorbell
  DEVICE_ENDPOINT_ID      =      1_u16
  DOORBELL_DEVICE_TYPE_ID = 0x0148_u32
  EXAMPLE_PRODUCT_ID      = 0x0148_u16

  alias Switch = Matter::Cluster::Switch
  alias Chime = Matter::Cluster::Chime

  class Device < Matter::Device
    include Examples::Console

    @pressed = false

    identity vendor: "Spider-Gazelle", product: "Synthetic Standalone Doorbell",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_doorbell_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: DOORBELL_DEVICE_TYPE_ID do
      cluster Matter::Cluster::Identify
      cluster Switch, feature_map: Switch::Feature::MomentarySwitch
      client_cluster Chime::CLUSTER_ID
    end

    protected def on_started : Nil
      super
      every(1.second) do
        unless @pressed || fabric_table.empty?
          node.get_cluster!(DEVICE_ENDPOINT_ID, Switch).initial_press(1_u8)
          @pressed = true
        end
      end
    end
  end
end

Examples.main("Synthetic Standalone Doorbell") { MatterDoorbell::Device.new }
