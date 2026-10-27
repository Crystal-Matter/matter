require "./support/console"
require "./support/main"

# Dedicated official chip-tool fixture. TLS certificate custody is explicitly
# enabled here; ordinary example devices do not advertise this cluster.
module MatterTlsCertificateManagement
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal TLS Certificates",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_tls_certificate_management_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TlsCertificateManagement
    end

    def console_notes : Array(String)
      ["Opt-in TLS Certificate Management; private keys stored by device backend"]
    end
  end
end

Examples.main("Matter TLS Certificate Management") { MatterTlsCertificateManagement::Device.new(tcp_enabled: true) }
