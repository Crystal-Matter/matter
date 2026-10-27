require "./support/console"
require "./support/main"

# Synthetic wire-test fixture for the opt-in Wi-Fi Network Management cluster.
# It does not advertise the Network Infrastructure Manager device type, whose
# required Thread clusters and physical router behavior are not implemented.
module MatterWiFiManagement
  MANAGED_WIFI_ENDPOINT_ID = 1_u16
  WIFI_ENDPOINT_ID         = 2_u16

  class Device < Matter::Device
    include Examples::Console

    TEST_SSID       = "Crystal Test Wi-Fi"
    TEST_PASSPHRASE = "correct horse"
    TEST_SURROGATE  = 42_u64

    identity vendor: "Spider-Gazelle", product: "Synthetic Wi-Fi Management",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_wifi_management_storage.yml"

    endpoint MANAGED_WIFI_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::WiFiNetworkManagement
    end

    endpoint WIFI_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::WiFiNetworkManagement
    end

    protected def before_start : Nil
      node.endpoint!(MANAGED_WIFI_ENDPOINT_ID).get_cluster!(Matter::Cluster::WiFiNetworkManagement)
        .update_credentials(TEST_SSID.to_slice, TEST_PASSPHRASE.to_slice, TEST_SURROGATE)
      super
    end
  end
end

Examples.main("Synthetic Wi-Fi Management") { MatterWiFiManagement::Device.new }
