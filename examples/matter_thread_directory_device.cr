require "./support/console"
require "./support/main"

# Synthetic directory endpoint used only to exercise the Matter 1.6 cluster
# with official chip-tool. It is not a Thread Border Router or a production
# Network Infrastructure Manager.
module MatterThreadDirectory
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Thread Directory",
      vendor_id: 0xFFF1_u16,
      product_id: 0x1235_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_thread_directory_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::ThreadNetworkDirectory
    end

    def console_notes : Array(String)
      ["Synthetic cross-fabric Thread Network Directory for E2E only"]
    end
  end
end

Examples.main("Synthetic Thread Network Directory") { MatterThreadDirectory::Device.new }
