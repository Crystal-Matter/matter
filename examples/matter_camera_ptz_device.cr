require "./support/console"
require "./support/main"

# Synthetic actuator and video source for commissioned PTZ wire tests.
module MatterCameraPtz
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x0554_u16

  alias Settings = Matter::Cluster::CameraAvSettingsUserLevelManagement
  alias Video = Matter::Cluster::CameraAvStreamManagement
  alias Status = Matter::InteractionModel::Status

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic PTZ Camera",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_camera_ptz_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Video,
        supported_stream_usages: [Video::StreamUsage::LiveView],
        max_content_buffer_size: 65_536_u32,
        max_network_bandwidth: 2_000_000_u32,
        video_sensor_params: Video::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
        min_viewport_resolution: Video::VideoResolution.new(160_u16, 90_u16),
        rate_distortion_trade_off_points: [Video::RateDistortionPoint.new(Video::VideoCodec::H264,
          Video::VideoResolution.new(1280_u16, 720_u16), 200_000_u32)],
        max_concurrent_encoders: 1_u8,
        max_encoded_pixel_rate: 62_208_000_u32,
        feature_map: Video::Feature::Video,
        as: :video
      cluster Settings,
        pan_min: -90_i16, pan_max: 90_i16,
        tilt_min: -45_i16, tilt_max: 45_i16,
        zoom_max: 20_u8,
        video_stream_management: video,
        feature_map: Settings::Feature::MechanicalPan | Settings::Feature::MechanicalTilt |
                     Settings::Feature::MechanicalZoom | Settings::Feature::DigitalPtz
    end

    protected def before_start : Nil
      video = node.get_cluster!(DEVICE_ENDPOINT_ID, Video)
      settings = node.get_cluster!(DEVICE_ENDPOINT_ID, Settings)
      video.on_video_allocate { |_request, _id| Status.success }
      video.on_video_deallocate { |_id| Status.success }
      settings.on_mptz_move do |target|
        settings.report_mptz_position(target)
        Status.success
      end
      settings.on_dptz_set_viewport { |_id, _viewport| Status.success }
      request = Video::VideoStreamAllocateRequest.new(Video::StreamUsage::LiveView, Video::VideoCodec::H264,
        15_u16, 30_u16, Video::VideoResolution.new(320_u16, 180_u16),
        Video::VideoResolution.new(1280_u16, 720_u16), 200_000_u32, 1_000_000_u32, 30_u16)
      response = video.video_stream_allocate(request).as(Video::VideoStreamAllocateResponse)
      status = settings.register_dptz_stream(response.video_stream_id)
      raise Matter::ConfigurationError.new("Could not register synthetic PTZ stream") unless status.success?
      super
    end
  end
end

Examples.main("Synthetic PTZ Camera") { MatterCameraPtz::Device.new }
