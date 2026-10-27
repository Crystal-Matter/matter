require "./support/console"
require "./support/main"

# Configuration-only Push AV fixture. It does not advertise a media source or
# start uploads; host integrations provide those callbacks explicitly.
module MatterPushAvStreamTransport
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Push AV Transport",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_push_av_stream_transport_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TlsCertificateManagement
      cluster Matter::Cluster::TlsClientManagement
      cluster Matter::Cluster::PushAvStreamTransport
    end

    def console_notes : Array(String)
      ["Matter 1.6 Push AV configuration and fabric-scoped connection catalog"]
    end
  end
end

Examples.main("Matter Push AV Stream Transport") { MatterPushAvStreamTransport::Device.new(tcp_enabled: true) }
