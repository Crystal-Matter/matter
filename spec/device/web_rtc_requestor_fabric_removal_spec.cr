require "../spec_helper"
require "../../src/matter/device"

private alias RemovalRequestor = Matter::Cluster::WebRtcTransportRequestor
private alias RemovalStatus = Matter::InteractionModel::Status

private class RemovalRequestorPeer < RemovalRequestor::Peer
  getter offers = [] of UInt16
  getter endings = [] of RemovalRequestor::EndReason

  def offer(session : RemovalRequestor::Session,
            request : RemovalRequestor::OfferRequest) : RemovalStatus
    @offers << session.id
    RemovalStatus.success
  end

  def answer(session : RemovalRequestor::Session,
             request : RemovalRequestor::AnswerRequest) : RemovalStatus
    RemovalStatus.success
  end

  def ice_candidates(session : RemovalRequestor::Session,
                     request : RemovalRequestor::IceCandidatesRequest) : RemovalStatus
    RemovalStatus.success
  end

  def end_session(session : RemovalRequestor::Session,
                  request : RemovalRequestor::EndRequest) : RemovalStatus
    @endings << RemovalRequestor::EndReason.from_value(request.reason)
    RemovalStatus.success
  end
end

private class RemovalRequestorDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Requestor Removal Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8133_u16,
    discriminator: 3846_u16, pin: 20202099_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory

  getter peer = RemovalRequestorPeer.new

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {1_u16 => Matter::DeviceType::AGGREGATOR}
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    [RemovalRequestor.new(Matter::DataType::EndpointNumber.new(1_u16), @peer)] of Matter::Cluster::Base
  end
end

private class RemovalRequestorFailAclStorage < Matter::Storage::Memory
  property? fail_acl_write : Bool = false

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_acl_write && collection == Matter::Storage::Collections::CLUSTERS &&
       id == Matter::Cluster::Base.persistence_key(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID)
      raise Matter::StorageError.new("Injected ACL write failure")
    end
    super
  end
end

private def removal_requestor_fabric(index : UInt8, id : UInt64) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: id, fabric_index: index, node_id: 0x5678_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

describe "WebRTC Requestor fabric removal" do
  it "ends an old session before an ACL error permits its index and peer Node ID to be reused" do
    require_udp_sockets!
    storage = RemovalRequestorFailAclStorage.new
    device = RemovalRequestorDevice.new(storage: storage, port: 0)
    device.fabric_table.add_fabric(removal_requestor_fabric(1_u8, 0x1001_u64)).should be_true
    requestor = device.node.get_cluster!(1_u16, RemovalRequestor)
    session = RemovalRequestor::Session.new(id: 7_u16, peer_node_id: 100_u64,
      peer_endpoint_id: 1_u16, stream_usage: RemovalRequestor::StreamUsage::LiveView,
      metadata_enabled: false, fabric_index: 1_u8, video_streams: [1_u16])
    requestor.upsert_session(session).status.should eq(Matter::InteractionModel::StatusCode::Success)
    requestor.current_sessions(1_u8).as(Array(RemovalRequestor::Session)).size.should eq(1)

    storage.fail_acl_write = true
    expect_raises(Matter::StorageError, "Injected ACL write failure") do
      device.operational_credentials.credentials.remove_fabric(1_u8)
    end
    device.fabric_table.get_fabric(1_u8).should be_nil
    device.peer.endings.should eq([RemovalRequestor::EndReason::UnknownReason])

    storage.fail_acl_write = false
    device.fabric_table.add_fabric(removal_requestor_fabric(1_u8, 0x2001_u64)).should be_true
    requestor.current_sessions(1_u8).as(Array(RemovalRequestor::Session)).should be_empty
    requestor.request_peer_node_id = 100_u64
    offer = RemovalRequestor::OfferRequest.new(7_u16, "v=0")
    invoke(requestor, RemovalRequestor::CMD_OFFER, offer,
      is_case_session: true, fabric_index: 1_u8).as(RemovalStatus).status
      .should eq(Matter::InteractionModel::StatusCode::NotFound)
    device.peer.offers.should be_empty
  ensure
    storage.fail_acl_write = false if storage
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end
end
