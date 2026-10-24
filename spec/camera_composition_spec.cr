require "./spec_helper"
require "../src/matter/camera_composition"

private CAMERA_ENDPOINT = Matter::DataType::EndpointNumber.new(1_u16)
private ROOT_ENDPOINT   = Matter::DataType::EndpointNumber.new(0_u16)
private alias CameraAv = Matter::Cluster::CameraAvStreamManagement
private alias WebRtcProvider = Matter::Cluster::WebRtcTransportProvider

private class NoMediaPeer < WebRtcProvider::Peer
  def solicit_offer(session : WebRtcProvider::Session,
                    request : WebRtcProvider::SolicitOfferRequest) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def accept_offer(session : WebRtcProvider::Session,
                   request : WebRtcProvider::ProvideOfferRequest) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def accept_answer(session : WebRtcProvider::Session, sdp : String) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def add_ice_candidates(session : WebRtcProvider::Session,
                         candidates : Array(WebRtcProvider::IceCandidate)) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def end_session(session : WebRtcProvider::Session, reason : WebRtcProvider::EndReason) : Nil
  end
end

describe Matter::CameraComposition do
  it "rejects a camera endpoint without AV/Provider servers or the Requestor client" do
    node = Matter::Node.new
    node.add_endpoint(Matter::Endpoint.new(ROOT_ENDPOINT))
    node.add_endpoint(Matter::Endpoint.new(CAMERA_ENDPOINT))

    errors = Matter::CameraComposition.validate(node, CAMERA_ENDPOINT.number)
    errors.join.should contain("Camera AV Stream Management")
    errors.join.should contain("WebRTC Transport Provider")
    errors.join.should contain("WebRTC Transport Requestor client")
    errors.join.should contain("Power Source")
    errors.join.should contain("Time Synchronization")
    errors.join.should contain("TLS Certificate Management")
    errors.join.should contain("TLS Client Management")
  end

  it "rejects the present Time Synchronization server without Camera-required features" do
    node = Matter::Node.new
    root = Matter::Endpoint.new(ROOT_ENDPOINT)
    root.add_cluster(Matter::Cluster::TimeSynchronization.new(ROOT_ENDPOINT,
      feature_map: Matter::Cluster::TimeSynchronization::Feature::TimeZone))
    root.add_client_cluster(Matter::CameraComposition::TIME_SYNC_CLUSTER_ID)
    node.add_endpoint(root)
    node.add_endpoint(Matter::Endpoint.new(CAMERA_ENDPOINT))

    errors = Matter::CameraComposition.validate(node, CAMERA_ENDPOINT.number)
    errors.join.should contain("NTPClient")
    errors.join.should contain("TimeSyncClient")
    errors.join.should_not contain("TimeZone")
    errors.join.should_not contain("Time Synchronization client")
  end

  it "rejects an AV server exposing Audio without mandatory Video and Snapshot" do
    node = Matter::Node.new
    node.add_endpoint(Matter::Endpoint.new(ROOT_ENDPOINT))
    camera = Matter::Endpoint.new(CAMERA_ENDPOINT)
    camera.add_cluster(CameraAv.new(CAMERA_ENDPOINT,
      supported_stream_usages: [CameraAv::StreamUsage::LiveView],
      max_content_buffer_size: 65_536_u32,
      max_network_bandwidth: 128_000_u32,
      microphone_capabilities: CameraAv::AudioCapabilities.new(1_u8,
        [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]),
      feature_map: CameraAv::Feature::Audio))
    node.add_endpoint(camera)

    errors = Matter::CameraComposition.validate(node, CAMERA_ENDPOINT.number)
    errors.join.should contain("needs Video")
    errors.join.should contain("needs Snapshot")
    errors.join.should_not contain("needs Audio")
  end

  it "composes all three AV features and Provider/Requestor roles but still reports Root blockers" do
    node = Matter::Node.new
    node.add_endpoint(Matter::Endpoint.new(ROOT_ENDPOINT))
    camera = Matter::Endpoint.new(CAMERA_ENDPOINT)
    av = CameraAv.new(CAMERA_ENDPOINT,
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
      feature_map: CameraAv::Feature::Audio | CameraAv::Feature::Video | CameraAv::Feature::Snapshot)
    camera.add_cluster(av)
    camera.add_cluster(WebRtcProvider.new(CAMERA_ENDPOINT, av, NoMediaPeer.new))
    camera.add_client_cluster(Matter::CameraComposition::REQUESTOR_CLUSTER_ID)
    node.add_endpoint(camera)

    errors = Matter::CameraComposition.validate(node, CAMERA_ENDPOINT.number)
    errors.join.should_not contain("Camera AV Stream Management")
    errors.join.should_not contain("WebRTC Transport Provider")
    errors.join.should_not contain("WebRTC Transport Requestor")
    errors.join.should contain("Power Source")
    errors.join.should contain("Time Synchronization")
  end
end
