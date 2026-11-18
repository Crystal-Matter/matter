require "../spec_helper"

private AUDIO_DOORBELL_DEVICE_TYPE_ID = 0x0141_u32
private AUDIO_DOORBELL_ENDPOINT       = Matter::DataType::EndpointNumber.new(1_u16)
private ROOT_ENDPOINT                 = Matter::DataType::EndpointNumber.new(0_u16)
private alias CameraAv = Matter::Cluster::CameraAvStreamManagement
private alias Provider = Matter::Cluster::WebRtcTransportProvider

private class AudioDoorbellNoMediaPeer < Provider::Peer
  def solicit_offer(session : Provider::Session, request : Provider::SolicitOfferRequest) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def accept_offer(session : Provider::Session, request : Provider::ProvideOfferRequest) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def accept_answer(session : Provider::Session, sdp : String) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def add_ice_candidates(session : Provider::Session, candidates : Array(Provider::IceCandidate)) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.invalid_in_state
  end

  def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
  end
end

private def audio_doorbell_endpoint(switch_feature : Matter::Cluster::Switch::Feature,
                                    av_feature : CameraAv::Feature) : Matter::Endpoint
  endpoint = Matter::Endpoint.new(AUDIO_DOORBELL_ENDPOINT, Matter::DeviceType.for(AUDIO_DOORBELL_DEVICE_TYPE_ID))
  endpoint.add_cluster(Matter::Cluster::Descriptor.new(AUDIO_DOORBELL_ENDPOINT))
  endpoint.add_cluster(Matter::Cluster::Identify.new(AUDIO_DOORBELL_ENDPOINT))
  endpoint.add_cluster(Matter::Cluster::Switch.new(AUDIO_DOORBELL_ENDPOINT, feature_map: switch_feature))
  av = CameraAv.new(AUDIO_DOORBELL_ENDPOINT,
    supported_stream_usages: [CameraAv::StreamUsage::LiveView],
    max_content_buffer_size: 65_000_u32,
    max_network_bandwidth: 2_000_000_u32,
    microphone_capabilities: CameraAv::AudioCapabilities.new(1_u8,
      [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]),
    video_sensor_params: CameraAv::VideoSensorParams.new(640_u16, 480_u16, 10_u16),
    min_viewport_resolution: CameraAv::VideoResolution.new(160_u16, 120_u16),
    rate_distortion_trade_off_points: [CameraAv::RateDistortionPoint.new(
      CameraAv::VideoCodec::H264, CameraAv::VideoResolution.new(320_u16, 240_u16), 200_000_u32)],
    snapshot_capabilities: [CameraAv::SnapshotCapability.new(
      CameraAv::VideoResolution.new(640_u16, 480_u16), 10_u16,
      CameraAv::ImageCodec::Jpeg, true, true)],
    max_concurrent_encoders: 1_u8,
    max_encoded_pixel_rate: 3_072_000_u32,
    feature_map: av_feature)
  endpoint.add_cluster(av)
  endpoint.add_cluster(Provider.new(AUDIO_DOORBELL_ENDPOINT, av, AudioDoorbellNoMediaPeer.new))
  endpoint.add_client_cluster(Matter::Cluster::WebRtcTransportRequestor::CLUSTER_ID)
  endpoint.add_client_cluster(Matter::Cluster::Chime::CLUSTER_ID)
  endpoint
end

describe "Matter 1.6 Audio Doorbell device composition" do
  it "declares revision 2 with mandatory server and client roles" do
    doorbell = Matter::DeviceType.for(AUDIO_DOORBELL_DEVICE_TYPE_ID)

    doorbell.name.should eq("Audio Doorbell")
    doorbell.revision.should eq(2_u16)
    doorbell.required_server_clusters.should contain(Matter::Cluster::Identify::CLUSTER_ID)
    doorbell.required_server_clusters.should contain(Matter::Cluster::Switch::CLUSTER_ID)
    doorbell.required_server_clusters.should contain(CameraAv::CLUSTER_ID)
    doorbell.required_server_clusters.should contain(Provider::CLUSTER_ID)
    doorbell.required_client_clusters.should contain(Matter::Cluster::WebRtcTransportRequestor::CLUSTER_ID)
    doorbell.required_client_clusters.should contain(Matter::Cluster::Chime::CLUSTER_ID)
    doorbell.required_server_features.has_key?(Matter::Cluster::Switch::CLUSTER_ID).should be_false
  end

  it "accepts a latching Switch profile with all mandatory roles" do
    endpoint = audio_doorbell_endpoint(Matter::Cluster::Switch::Feature::LatchingSwitch,
      CameraAv::Feature::Audio)

    endpoint.validate.should be_empty
  end

  it "rejects SNP-only AV and missing Root conditions" do
    node = Matter::Node.new
    node.add_endpoint(Matter::Endpoint.new(ROOT_ENDPOINT))
    endpoint = audio_doorbell_endpoint(Matter::Cluster::Switch::Feature::MomentarySwitch,
      CameraAv::Feature::Snapshot)
    node.add_endpoint(endpoint)

    errors = node.validate[AUDIO_DOORBELL_ENDPOINT.number].join
    errors.should contain("needs Audio")
    errors.should contain("disallows Snapshot")
    errors.should contain("Power Source")
    errors.should contain("TLS Certificate Management")
  end

  it "rejects VDO even when ADO is enabled" do
    node = Matter::Node.new
    node.add_endpoint(Matter::Endpoint.new(ROOT_ENDPOINT))
    node.add_endpoint(audio_doorbell_endpoint(Matter::Cluster::Switch::Feature::MomentarySwitch,
      CameraAv::Feature::Audio | CameraAv::Feature::Video))

    node.validate[AUDIO_DOORBELL_ENDPOINT.number].join.should contain("disallows Video")
  end
end
