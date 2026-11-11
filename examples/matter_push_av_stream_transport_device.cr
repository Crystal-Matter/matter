require "./support/console"
require "./support/main"

# Configuration-only Push AV fixture. Its test stream ID exercises the catalog;
# it has no camera sensor, encoder, or media uploader.
module MatterPushAvStreamTransport
  ROOT_ENDPOINT_ID        = 0_u16
  CATALOG_VIDEO_STREAM_ID = 1_u16

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Push AV Transport",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_push_av_stream_transport_storage.yml"

    endpoint ROOT_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TlsCertificateManagement
      cluster Matter::Cluster::TlsClientManagement
      cluster Matter::Cluster::PushAvStreamTransport
    end

    def console_notes : Array(String)
      ["Matter 1.6 Push AV configuration and fabric-scoped connection catalog"]
    end

    protected def before_start : Nil
      push = node.get_cluster!(ROOT_ENDPOINT_ID, Matter::Cluster::PushAvStreamTransport)
      push.video_stream_exists = ->(id : UInt16) { id == CATALOG_VIDEO_STREAM_ID }
      super
    end
  end
end

Examples.main("Matter Push AV Stream Transport") { MatterPushAvStreamTransport::Device.new(tcp_enabled: true) }
