require "./support/console"
require "./support/main"

# Synthetic SNP endpoint for wire interoperability; host supplies a checked-in
# 320x240 JPEG so CaptureSnapshot returns a decodable still image.
module MatterCameraSnapshot
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x0553_u16

  alias CameraAv = Matter::Cluster::CameraAvStreamManagement
  alias PowerSource = Matter::Cluster::PowerSource
  alias TimeSync = Matter::Cluster::TimeSynchronization

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Camera Snapshot",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_camera_snapshot_storage.yml"

    endpoint 0_u16, device_type: Matter::DeviceType::POWER_SOURCE do
      cluster PowerSource, feature_map: PowerSource::Feature::Wired,
        description: "Mains", endpoint_list: [DEVICE_ENDPOINT_ID]
      cluster TimeSync, feature_map: TimeSync::Feature::TimeZone
    end

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::SNAPSHOT_CAMERA do
      cluster CameraAv,
        supported_stream_usages: [CameraAv::StreamUsage::LiveView],
        max_content_buffer_size: 65_000_u32,
        max_network_bandwidth: 2_000_000_u32,
        snapshot_capabilities: [CameraAv::SnapshotCapability.new(
          CameraAv::VideoResolution.new(640_u16, 480_u16), 10_u16,
          CameraAv::ImageCodec::Jpeg, true, true)],
        max_concurrent_encoders: 1_u8,
        max_encoded_pixel_rate: 3_072_000_u32,
        image_flip_horizontal_supported: true,
        image_flip_vertical_supported: true,
        status_light_enabled_supported: true,
        status_light_brightness_supported: true,
        feature_map: CameraAv::Feature::Snapshot | CameraAv::Feature::Privacy |
                     CameraAv::Feature::ImageControl
    end

    protected def before_start : Nil
      camera = node.get_cluster!(DEVICE_ENDPOINT_ID, CameraAv)
      snapshot = File.read(File.expand_path("assets/snapshot_320x240.jpg", __DIR__)).to_slice
      camera.on_snapshot_allocate { |_request, _id| Matter::InteractionModel::Status.success }
      camera.on_snapshot_deallocate { |_id| Matter::InteractionModel::Status.success }
      camera.on_snapshot_capture do |_stream, resolution|
        CameraAv::SnapshotImage.new(snapshot, CameraAv::ImageCodec::Jpeg, resolution)
      end
      camera.on_image_rotation_changed { |_angle| Matter::InteractionModel::Status.success }
      camera.on_image_flip_changed { |_horizontal, _vertical| Matter::InteractionModel::Status.success }
      camera.on_status_light_enabled_changed { |_enabled| Matter::InteractionModel::Status.success }
      camera.on_status_light_brightness_changed { |_brightness| Matter::InteractionModel::Status.success }
      super
    end
  end
end

Examples.main("Synthetic Camera Snapshot") { MatterCameraSnapshot::Device.new }
