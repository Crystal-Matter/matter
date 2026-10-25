require "./support/console"
require "./support/main"

# Synthetic SNP endpoint for wire interoperability; host supplies a checked-in
# 320x240 JPEG so CaptureSnapshot returns a decodable still image.
module MatterCameraSnapshot
  alias CameraAv = Matter::Cluster::CameraAvStreamManagement

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Camera Snapshot",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0553_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_camera_snapshot_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster CameraAv,
        supported_stream_usages: [CameraAv::StreamUsage::LiveView],
        max_content_buffer_size: 65_000_u32,
        max_network_bandwidth: 2_000_000_u32,
        snapshot_capabilities: [CameraAv::SnapshotCapability.new(
          CameraAv::VideoResolution.new(640_u16, 480_u16), 10_u16,
          CameraAv::ImageCodec::Jpeg, true, true)],
        max_concurrent_encoders: 1_u8,
        max_encoded_pixel_rate: 3_072_000_u32,
        feature_map: CameraAv::Feature::Snapshot | CameraAv::Feature::Privacy
    end

    protected def before_start : Nil
      camera = node.get_cluster!(1_u16, CameraAv)
      snapshot = File.read("examples/assets/snapshot_320x240.jpg").to_slice
      camera.on_snapshot_allocate { |_request, _id| Matter::InteractionModel::Status.success }
      camera.on_snapshot_deallocate { |_id| Matter::InteractionModel::Status.success }
      camera.on_snapshot_capture do |_stream, resolution|
        CameraAv::SnapshotImage.new(snapshot, CameraAv::ImageCodec::Jpeg, resolution)
      end
      super
    end
  end
end

Examples.main("Synthetic Camera Snapshot") { MatterCameraSnapshot::Device.new }
