require "./support/console"
require "./support/main"

# Synthetic wire fixture: Aggregator endpoints advertise only Wake On LAN
# metadata. A real media product must supply a wake-capable network interface
# and its other device-type clusters before claiming a media device type.
module MatterWakeOnLan
  class Device < Matter::Device
    include Examples::Console

    MAC_ADDRESS        = "12345678ABCD"
    LINK_LOCAL_ADDRESS = Bytes[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

    identity vendor: "Spider-Gazelle", product: "Synthetic Wake On LAN",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_wake_on_lan_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::WakeOnLan, mac_address: MAC_ADDRESS,
        link_local_address: LINK_LOCAL_ADDRESS
    end

    endpoint 2, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::WakeOnLan
    end
  end
end

Examples.main("Synthetic Wake On LAN") { MatterWakeOnLan::Device.new }
