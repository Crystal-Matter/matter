require "./support/console"
require "./support/main"

# Synthetic VDO endpoint for wire interoperability. Real hosts must attach a
# camera sensor, encoder and transport before advertising the feature.
module MatterCameraVideo
  alias CameraAv = Matter::Cluster::CameraAvStreamManagement

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Camera Video",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0552_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_camera_video_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster CameraAv,
        supported_stream_usages: [CameraAv::StreamUsage::LiveView, CameraAv::StreamUsage::Recording],
        max_content_buffer_size: 65_536_u32,
        max_network_bandwidth: 2_000_000_u32,
        video_sensor_params: CameraAv::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
        min_viewport_resolution: CameraAv::VideoResolution.new(160_u16, 90_u16),
        rate_distortion_trade_off_points: [CameraAv::RateDistortionPoint.new(CameraAv::VideoCodec::H264,
          CameraAv::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
        max_concurrent_encoders: 1_u8,
        max_encoded_pixel_rate: 62_208_000_u32,
        feature_map: CameraAv::Feature::Video | CameraAv::Feature::Privacy
    end

    protected def before_start : Nil
      camera = node.get_cluster!(1_u16, CameraAv)
      camera.on_video_allocate { |_request, _id| Matter::InteractionModel::Status.success }
      camera.on_video_deallocate { |_id| Matter::InteractionModel::Status.success }
      super
    end
  end
end

Examples.main("Synthetic Camera Video") { MatterCameraVideo::Device.new }
