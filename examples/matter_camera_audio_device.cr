require "./support/console"
require "./support/main"

# Synthetic ADO endpoint for wire interoperability. The callbacks admit and
# release logical test streams; production hosts must attach a real microphone,
# encoder and transport before advertising the feature.
module MatterCameraAudio
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x0551_u16

  alias CameraAv = Matter::Cluster::CameraAvStreamManagement

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Camera Audio",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_camera_audio_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster CameraAv,
        microphone_capabilities: CameraAv::AudioCapabilities.new(2_u8,
          [CameraAv::AudioCodec::Opus], [16_000_u32, 48_000_u32], [16_u8]),
        speaker_capabilities: CameraAv::AudioCapabilities.new(1_u8,
          [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]),
        two_way_talk_support: CameraAv::TwoWayTalkSupport::NotSupported,
        supported_stream_usages: [CameraAv::StreamUsage::LiveView, CameraAv::StreamUsage::Recording],
        max_content_buffer_size: 65_536_u32,
        max_network_bandwidth: 96_000_u32,
        feature_map: CameraAv::Feature::Audio | CameraAv::Feature::Privacy | CameraAv::Feature::Speaker
    end

    protected def before_start : Nil
      camera = node.get_cluster!(DEVICE_ENDPOINT_ID, CameraAv)
      camera.on_audio_allocate do |_request, _id|
        Matter::InteractionModel::Status.success
      end
      camera.on_audio_deallocate do |_id|
        Matter::InteractionModel::Status.success
      end
      camera.on_speaker_settings_changed do |_muted, _volume|
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Camera Audio") { MatterCameraAudio::Device.new }
