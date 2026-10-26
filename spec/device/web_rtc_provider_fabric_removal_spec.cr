require "../spec_helper"
require "../../src/matter/device"

private alias RemovalCameraAv = Matter::Cluster::CameraAvStreamManagement
private alias RemovalProvider = Matter::Cluster::WebRtcTransportProvider
private alias RemovalStatus = Matter::InteractionModel::Status

private class RemovalWebRtcPeer < RemovalProvider::Peer
  getter endings = [] of RemovalProvider::EndReason

  def solicit_offer(session : RemovalProvider::Session,
                    request : RemovalProvider::SolicitOfferRequest) : RemovalStatus
    RemovalStatus.success
  end

  def accept_offer(session : RemovalProvider::Session,
                   request : RemovalProvider::ProvideOfferRequest) : RemovalStatus
    RemovalStatus.success
  end

  def accept_answer(session : RemovalProvider::Session, sdp : String) : RemovalStatus
    RemovalStatus.success
  end

  def add_ice_candidates(session : RemovalProvider::Session,
                         candidates : Array(RemovalProvider::IceCandidate)) : RemovalStatus
    RemovalStatus.success
  end

  def end_session(session : RemovalProvider::Session, reason : RemovalProvider::EndReason) : Nil
    @endings << reason
  end
end

private class RemovalWebRtcDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "WebRTC Removal Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8132_u16,
    discriminator: 3845_u16, pin: 20202098_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory

  getter peer = RemovalWebRtcPeer.new

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {1_u16 => Matter::DeviceType::AGGREGATOR}
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    endpoint = Matter::DataType::EndpointNumber.new(1_u16)
    camera = RemovalCameraAv.new(endpoint,
      microphone_capabilities: RemovalCameraAv::AudioCapabilities.new(1_u8,
        [RemovalCameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]),
      supported_stream_usages: [RemovalCameraAv::StreamUsage::LiveView],
      max_content_buffer_size: 65_536_u32,
      max_network_bandwidth: 128_000_u32)
    [camera, RemovalProvider.new(endpoint, camera, @peer)] of Matter::Cluster::Base
  end
end

private class RemovalFailAclStorage < Matter::Storage::Memory
  property? fail_acl_write : Bool = false

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_acl_write && collection == Matter::Storage::Collections::CLUSTERS &&
       id == Matter::Cluster::Base.persistence_key(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID)
      raise Matter::StorageError.new("Injected ACL write failure")
    end
    super
  end
end

private def removal_fabric(index : UInt8, id : UInt64) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: id, fabric_index: index, node_id: 0x5678_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

describe "WebRTC Provider fabric removal" do
  it "ends an old session and reserves its index after an ACL failure" do
    require_udp_sockets!
    storage = RemovalFailAclStorage.new
    device = RemovalWebRtcDevice.new(storage: storage, port: 0)
    device.fabric_table.add_fabric(removal_fabric(1_u8, 0x1001_u64)).should be_true
    camera = device.node.get_cluster!(1_u16, RemovalCameraAv)
    provider = device.node.get_cluster!(1_u16, RemovalProvider)
    camera.on_audio_allocate { |_request, _id| RemovalStatus.success }
    allocation = camera.audio_stream_allocate(RemovalCameraAv::AudioStreamAllocateRequest.new(
      RemovalCameraAv::StreamUsage::LiveView, RemovalCameraAv::AudioCodec::Opus,
      1_u8, 48_000_u32, 64_000_u32, 16_u8)).as(RemovalCameraAv::AudioStreamAllocateResponse)
    offer = RemovalProvider::ProvideOfferRequest.new(nil, "v=0",
      RemovalCameraAv::StreamUsage::LiveView, 22_u16,
      audio_streams: [allocation.audio_stream_id])
    provider.request_peer_node_id = 100_u64
    response = invoke(provider, RemovalProvider::CMD_PROVIDE_OFFER, offer,
      is_case_session: true, fabric_index: 1_u8).as(Matter::Cluster::CommandResponse)
    session_id = RemovalProvider::ProvideOfferResponse.from_tlv(response.response.as(TLV::Any)).web_rtc_session_id
    provider.current_sessions(1_u8).as(Array(RemovalProvider::Session)).size.should eq(1)

    storage.fail_acl_write = true
    expect_raises(Matter::StorageError, "Could not persist erased Access Control") do
      device.operational_credentials.credentials.remove_fabric(1_u8)
    end
    device.fabric_table.get_fabric(1_u8).should_not be_nil
    device.fabric_table.quarantined?(1_u8).should be_true
    device.peer.endings.should eq([RemovalProvider::EndReason::UnknownReason])
    provider.current_sessions(1_u8).as(Array(RemovalProvider::Session)).should be_empty

    storage.fail_acl_write = false
    device.fabric_table.add_fabric(removal_fabric(1_u8, 0x2001_u64)).should be_false
    provider.request_peer_node_id = 100_u64
    finish = RemovalProvider::EndSessionRequest.new(session_id, RemovalProvider::EndReason::UserHangup)
    invoke(provider, RemovalProvider::CMD_END_SESSION, finish,
      is_case_session: true, fabric_index: 1_u8).as(RemovalStatus).status
      .should eq(Matter::InteractionModel::StatusCode::NotFound)
  ensure
    storage.fail_acl_write = false if storage
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end
end
