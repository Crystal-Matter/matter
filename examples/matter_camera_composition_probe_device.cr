require "./support/console"
require "./support/main"

# Test-only Camera composition probe. Its Provider deliberately declines media
# signaling; this fixture proves Descriptor and root roles, not a media path.
module MatterCameraCompositionProbe
  CAMERA_ENDPOINT_ID =      1_u16
  EXAMPLE_PRODUCT_ID = 0x8142_u16

  alias CameraAv = Matter::Cluster::CameraAvStreamManagement
  alias Provider = Matter::Cluster::WebRtcTransportProvider
  alias Requestor = Matter::Cluster::WebRtcTransportRequestor
  alias PowerSource = Matter::Cluster::PowerSource
  alias TimeSync = Matter::Cluster::TimeSynchronization
  alias Status = Matter::InteractionModel::Status

  class NoMediaPeer < Provider::Peer
    def solicit_offer(session : Provider::Session, request : Provider::SolicitOfferRequest) : Status
      Status.invalid_in_state
    end

    def accept_offer(session : Provider::Session, request : Provider::ProvideOfferRequest) : Status
      Status.invalid_in_state
    end

    def accept_answer(session : Provider::Session, sdp : String) : Status
      Status.invalid_in_state
    end

    def add_ice_candidates(session : Provider::Session, candidates : Array(Provider::IceCandidate)) : Status
      Status.invalid_in_state
    end

    def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
    end
  end

  class BaseDevice < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Camera Composition Probe",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_camera_composition_probe_storage.yml"

    endpoint 0_u16, device_type: Matter::DeviceType::POWER_SOURCE do
      cluster PowerSource, feature_map: PowerSource::Feature::Wired,
        description: "Mains", endpoint_list: [CAMERA_ENDPOINT_ID]
      cluster TimeSync, feature_map: TimeSync::Feature::TimeZone |
                                     TimeSync::Feature::NtpClient |
                                     TimeSync::Feature::TrustedTimeClient
      cluster Matter::Cluster::TlsCertificateManagement
      cluster Matter::Cluster::TlsClientManagement
      client_cluster TimeSync::CLUSTER_ID
    end

    endpoint CAMERA_ENDPOINT_ID, device_type: Matter::DeviceType::CAMERA do
      cluster CameraAv,
        supported_stream_usages: [CameraAv::StreamUsage::LiveView],
        max_content_buffer_size: 65_536_u32,
        max_network_bandwidth: 2_000_000_u32,
        microphone_capabilities: CameraAv::AudioCapabilities.new(1_u8,
          [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]),
        video_sensor_params: CameraAv::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
        min_viewport_resolution: CameraAv::VideoResolution.new(160_u16, 90_u16),
        rate_distortion_trade_off_points: [CameraAv::RateDistortionPoint.new(
          CameraAv::VideoCodec::H264, CameraAv::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
        snapshot_capabilities: [CameraAv::SnapshotCapability.new(
          CameraAv::VideoResolution.new(640_u16, 480_u16), 10_u16,
          CameraAv::ImageCodec::Jpeg, true, true)],
        max_concurrent_encoders: 1_u8,
        max_encoded_pixel_rate: 62_208_000_u32,
        feature_map: CameraAv::Feature::Audio | CameraAv::Feature::Video | CameraAv::Feature::Snapshot
      client_cluster Requestor::CLUSTER_ID
    end
  end

  class Device < BaseDevice
    protected def device_clusters : Array(Matter::Cluster::Base)
      clusters = super
      camera = clusters.find(&.is_a?(CameraAv)).as(CameraAv)
      clusters << Provider.new(camera.endpoint_id, camera, NoMediaPeer.new)
      clusters
    end

    def console_notes : Array(String)
      ["Test-only Camera composition; media signaling and delivery are unavailable"]
    end
  end
end

Examples.main("Camera composition probe") { MatterCameraCompositionProbe::Device.new }
