require "./support/console"
require "./support/main"

# Logical signaling fixture. The peer records commands but deliberately does
# not create a WebRTC connection or deliver media.
module MatterWebRtcSignaling
  alias CameraAv = Matter::Cluster::CameraAvStreamManagement
  alias Provider = Matter::Cluster::WebRtcTransportProvider
  alias Status = Matter::InteractionModel::Status

  class RecordingPeer < Provider::Peer
    def solicit_offer(session : Provider::Session, request : Provider::SolicitOfferRequest) : Status
      Status.invalid_in_state
    end

    def accept_offer(session : Provider::Session, request : Provider::ProvideOfferRequest) : Status
      Status.success
    end

    def accept_answer(session : Provider::Session, sdp : String) : Status
      Status.success
    end

    def add_ice_candidates(session : Provider::Session, candidates : Array(Provider::IceCandidate)) : Status
      Status.success
    end

    def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
    end
  end

  class CameraDevice < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "WebRTC Signaling Test",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0553_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_webrtc_signaling_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster CameraAv,
        microphone_capabilities: CameraAv::AudioCapabilities.new(1_u8,
          [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]),
        supported_stream_usages: [CameraAv::StreamUsage::LiveView],
        max_content_buffer_size: 65_536_u32,
        max_network_bandwidth: 96_000_u32,
        feature_map: CameraAv::Feature::Audio | CameraAv::Feature::Privacy
    end
  end

  class Device < CameraDevice
    protected def device_clusters : Array(Matter::Cluster::Base)
      clusters = super
      camera = clusters.find(&.is_a?(CameraAv)).as(CameraAv)
      clusters << Provider.new(camera.endpoint_id, camera, RecordingPeer.new)
      clusters
    end

    protected def before_start : Nil
      camera = node.get_cluster!(1_u16, CameraAv)
      camera.on_audio_allocate { |_request, _id| Status.success }
      camera.on_audio_deallocate { |_id| Status.success }
      super
    end
  end
end

Examples.main("WebRTC signaling fixture") { MatterWebRtcSignaling::Device.new }
