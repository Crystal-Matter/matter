require "./support/console"
require "./support/main"
require "../src/matter/controller"
require "../src/matter/camera/signaling_sink"

# Test-only Camera signaling fixture. SDP and ICE are deterministic wire values;
# no WebRTC peer connection or media track exists.
module MatterCameraSignalingInterop
  CAMERA_ENDPOINT_ID =      1_u16
  EXAMPLE_PRODUCT_ID = 0x8142_u16

  alias CameraAv = Matter::Cluster::CameraAvStreamManagement
  alias Provider = Matter::Cluster::WebRtcTransportProvider
  alias Requestor = Matter::Cluster::WebRtcTransportRequestor
  alias PowerSource = Matter::Cluster::PowerSource
  alias TimeSync = Matter::Cluster::TimeSynchronization
  alias Status = Matter::InteractionModel::Status

  TEST_OFFER     = "v=0\r\no=crystal 1 1 IN IP4 127.0.0.1\r\ns=signaling-only\r\nt=0 0\r\n"
  TEST_ANSWER    = "v=0\r\no=crystal 2 2 IN IP4 127.0.0.1\r\ns=signaling-only\r\nt=0 0\r\n"
  TEST_CANDIDATE = "candidate:1 1 UDP 1 127.0.0.1 1234 typ host"

  class SignalingPeer < Provider::Peer
    property device : Device? = nil

    private def bound_device : Device
      @device || raise Matter::ConfigurationError.new("Camera signaling peer is not bound")
    end

    def solicit_offer(session : Provider::Session, request : Provider::SolicitOfferRequest) : Status
      bound_device.defer_signal(session) { |sink| sink.offer(session, TEST_OFFER) }
    end

    def accept_offer(session : Provider::Session, request : Provider::ProvideOfferRequest) : Status
      bound_device.defer_signal(session) { |sink| sink.answer(session, TEST_ANSWER) }
    end

    def accept_answer(session : Provider::Session, sdp : String) : Status
      Status.success
    end

    def add_ice_candidates(session : Provider::Session, candidates : Array(Provider::IceCandidate)) : Status
      bound_device.defer_signal(session) do |sink|
        sink.ice_candidates(session, [Provider::IceCandidate.new(TEST_CANDIDATE, "0", 0_u16)])
      end
    end

    def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
      bound_device.forward_host_end(session, reason)
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

    storage yaml: "matter_camera_signaling_interop_storage.yml"

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
    alias Sink = Matter::Camera::RequestorSignalingSink(Matter::Controller::ImClient)

    @provider : Provider? = nil
    @peer : SignalingPeer? = nil
    @client : Matter::Controller::Client? = nil
    @sink : Sink? = nil
    @destination : Sink::Destination? = nil
    @host_end_enabled = false

    private def camera_provider : Provider
      node.get_cluster!(CAMERA_ENDPOINT_ID, Provider)
    end

    private def outbound_client : Matter::Controller::Client
      @client || raise Matter::ConfigurationError.new("Camera signaling client is not initialized")
    end

    private def signaling_sink : Sink
      @sink || raise Matter::ConfigurationError.new("Camera signaling sink is not initialized")
    end

    protected def device_clusters : Array(Matter::Cluster::Base)
      clusters = super
      camera = clusters.find(&.is_a?(CameraAv)).as(CameraAv)
      peer = SignalingPeer.new
      @peer = peer
      provider = Provider.new(camera.endpoint_id, camera, peer)
      @provider = provider
      clusters << provider
      clusters
    end

    protected def before_start : Nil
      peer = @peer || raise Matter::ConfigurationError.new("Camera signaling peer is not initialized")
      peer.device = self
      camera = node.get_cluster!(CAMERA_ENDPOINT_ID, CameraAv)
      camera.on_video_allocate { |_request, _id| Status.success }
      camera.on_video_deallocate { |_id| Status.success }
      @client = Matter::Controller::Client.new(transport: message_handler.transport,
        delegate_peer_initiated: true)
      @sink = Sink.new(camera_provider, Matter::Controller::WebrtcRequestorClient.new(
        Matter::Controller::ImClient.new(outbound_client)),
        ->(fabric : UInt8, node_id : UInt64) {
          destination = @destination
          if destination && destination.session.fabric_index == fabric &&
             destination.session.peer_node_id.try(&.id) == node_id
            destination
          end
        })
      client = Matter::Controller::TrustedTimeClient.new
      time_sync = node.get_cluster!(TimeSync)
      time_sync.on_trusted_time_query = ->(fabric_index : UInt8, node_id : UInt64, endpoint : UInt16) : TimeSync::TrustedTimeSample? do
        fabric = fabric_table.get_fabric(fabric_index)
        fabric ? client.query(fabric, node_id, endpoint) : nil
      end
      super
    end

    def defer_signal(session : Provider::Session, &block : Sink -> Nil) : Status
      provider = camera_provider
      wire_id = provider.request_session_id
      secure = wire_id.try { |id| message_handler.registry.session(id.to_u16) }
      address = provider.request_peer_address || secure.try(&.tcp_peer)
      unless wire_id && address && secure
        puts "SIGNALING CONTEXT MISSING wire_id=#{wire_id.inspect} address=#{address.inspect} secure=#{!secure.nil?} " \
             "tcp_peer=#{secure.try(&.tcp_peer).inspect} active=#{provider.request_command_active?}"
        return Status.invalid_in_state
      end
      client = outbound_client
      client.register_session(secure, address) unless client.session?(secure.session_id)
      @destination = Sink::Destination.new(secure, address)
      sink = signaling_sink
      queued = provider.defer_signaling(session) { block.call(sink) }
      puts "SIGNALING DEFER queued=#{queued} session=#{session.id} fabric=#{session.fabric_index} peer=#{session.peer_node_id}"
      queued ? Status.success : Status.invalid_in_state
    end

    def forward_host_end(session : Provider::Session, reason : Provider::EndReason) : Nil
      signaling_sink.end_session(session, reason) if @host_end_enabled
    end

    protected def on_started : Nil
      if control_dir = ENV["MATTER_CAMERA_SIGNALING_CONTROL_DIR"]?
        spawn do
          loop do
            break unless File.directory?(control_dir)
            Dir.glob(File.join(control_dir, "end-*")).each do |path|
              id = File.basename(path).lchop("end-").to_u16?
              File.delete(path)
              next unless id
              if destination = @destination
                secure = destination.session
                if fabric = secure.fabric_index
                  if peer = secure.peer_node_id
                    @host_end_enabled = true
                    begin
                      camera_provider.end_host_session(fabric, peer.id, id, Provider::EndReason::UserHangup)
                    ensure
                      @host_end_enabled = false
                    end
                  end
                end
              end
            end
            sleep 100.milliseconds
          end
        end
      end
      super
    end

    protected def on_shutdown : Nil
      @client.try(&.close)
      super
    end

    def console_notes : Array(String)
      ["Test-only Camera signaling; deterministic SDP/ICE, no decoded media"]
    end
  end
end

Examples.main("Camera signaling interop") { MatterCameraSignalingInterop::Device.new(tcp_enabled: true) }
