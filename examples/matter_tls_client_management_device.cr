require "./support/console"
require "./support/main"

# Dedicated certificate-backed TLS endpoint interoperability fixture.
module MatterTlsClientManagement
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal TLS Client Endpoints",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_tls_client_management_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TlsCertificateManagement
      cluster Matter::Cluster::TlsClientManagement
    end

    def console_notes : Array(String)
      ["Opt-in TLS client endpoints with per-fabric certificate references"]
    end
  end
end

Examples.main("Matter TLS Client Management") { MatterTlsClientManagement::Device.new(tcp_enabled: true) }
