require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private DEVICE_LOAD_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private def device_load_fabric : Matter::Fabric
  root_key = Bytes.new(65, 1_u8)
  root_key[0] = 4_u8
  Matter::Fabric.new(0x100_u64, 1_u8, 1_u64, root_key,
    Bytes.new(200, 1_u8), Matter::Crypto::Key.generate_key_pair, Bytes.new(16, 1_u8))
end

private def device_load_subscription(id : UInt32, session : Matter::Session::SecureContext)
  Matter::Protocol::ActiveSubscription.new(
    subscription_id: id,
    min_interval: 0_u16,
    max_interval: 60_u16,
    peer: DEVICE_LOAD_PEER,
    session: session,
    attribute_paths: [] of Matter::InteractionModel::AttributePath,
    exchange_id: id.to_u16
  )
end

describe "GeneralDiagnostics DeviceLoadStatus runtime" do
  it "counts authenticated group IM ingress but not failed authentication or replay" do
    fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    fabric = device_load_fabric
    fabric_table.add_fabric(fabric).should be_true
    handler = Matter::Protocol::MessageHandler.new(
      Matter::Spec::CaptureTransport.new_for_spec, 20202021_u32, 3840_u16, fabric_table
    )
    root = handler.node.endpoint!(0_u16)
    gkm = Matter::Cluster::GroupKeyManagement.new(endpoint(0))
    root.add_cluster(gkm)
    handler.node.add_endpoint(root)
    epoch = Bytes.new(16, 0x11_u8)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(5_u16,
        epoch_key0: epoch, epoch_start_time0: 1_u64)), 1_u8)
    gkm.add_group_key_map(0x1234_u16, 5_u16, 1_u8)
    operational = Matter::Session::GroupSecurePacket.derive_operational_key(epoch, fabric.compressed_fabric_id)
    key = Matter::Session::GroupSecurePacket::Key.new(1_u8, 0x1234_u16, operational)
    codec = Matter::Session::GroupSecurePacket.new([key])
    header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
      Matter::Protocol::IMHandler::MSG_WRITE_REQUEST, true, false)
    wire = codec.encode(key, 0x2222_u64, 100_u32, header, Bytes.empty)

    handler.handle_group_packet(wire, DEVICE_LOAD_PEER)
    handler.device_load_status(1_u8).total_interaction_model_messages_received.should eq(1_u32)
    handler.handle_group_packet(wire, DEVICE_LOAD_PEER)
    tampered = wire.dup
    tampered[tampered.size - 1] ^= 0x01_u8
    handler.handle_group_packet(tampered, DEVICE_LOAD_PEER)
    handler.device_load_status(1_u8).total_interaction_model_messages_received.should eq(1_u32)
    handler.close
  end

  it "counts a restored active subscription and a renewal without counting replacement twice" do
    handler = Matter::Protocol::MessageHandler.new(
      Matter::Spec::CaptureTransport.new_for_spec,
      20202021_u32,
      3840_u16,
      Matter::FabricTable.new(Matter::Storage::Memory.new)
    )
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    handler.registry.restore_subscription(device_load_subscription(1_u32, session))
    handler.registry.restore_subscription(device_load_subscription(1_u32, session))
    handler.device_load_status(1_u8).total_subscriptions_established.should eq(1_u32)

    handler.registry.renew_subscription(1_u32, device_load_subscription(2_u32, session))
    status = handler.device_load_status(1_u8)
    status.current_subscriptions.should eq(1_u16)
    status.total_subscriptions_established.should eq(2_u32)
    handler.close
  end

  it "counts only active subscriptions and scopes one count to the accessing fabric" do
    handler = Matter::Protocol::MessageHandler.new(
      Matter::Spec::CaptureTransport.new_for_spec,
      20202021_u32,
      3840_u16,
      Matter::FabricTable.new(Matter::Storage::Memory.new)
    )
    first = Matter::Spec::ProtocolMessages.case_session(1_u16)
    second = Matter::Spec::ProtocolMessages.case_session(3_u16)
    second.fabric_index = 2_u8

    handler.subscriptions.await_subscription(42_u16,
      Matter::Protocol::SubscriptionManager::PendingSubscription.new(
        subscription_id: 3_u32,
        min_interval: 0_u16,
        max_interval: 60_u16,
        attribute_paths: [] of Matter::InteractionModel::AttributePath,
        peer: DEVICE_LOAD_PEER,
        session: first,
        remaining_chunks: [] of Bytes
      ))

    handler.registry.add_subscription(device_load_subscription(1_u32, first))
    handler.registry.add_subscription(device_load_subscription(2_u32, second))
    status = handler.device_load_status(1_u8)
    status.current_subscriptions.should eq(2_u16)
    status.current_subscriptions_for_fabric.should eq(1_u16)
    status.total_subscriptions_established.should eq(2_u32)
    handler.device_load_status(2_u8).current_subscriptions_for_fabric.should eq(1_u16)
    handler.device_load_status(nil).current_subscriptions_for_fabric.should eq(0_u16)

    handler.registry.remove_subscriptions_for_subscriber(1_u8, first.peer_node_id.as(Matter::DataType::NodeId).id)
    status = handler.device_load_status(1_u8)
    status.current_subscriptions.should eq(1_u16)
    status.current_subscriptions_for_fabric.should eq(0_u16)
    status.total_subscriptions_established.should eq(2_u32)
    handler.close
  end

  it "counts accepted IM ingress and actual IM response, but not Secure Channel ACKs" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(
      transport, 20202021_u32, 3840_u16,
      Matter::FabricTable.new(Matter::Storage::Memory.new)
    )
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    handler.sessions[session.session_id] = session
    request = Matter::InteractionModel::ReadRequestMessage.new(
      attribute_requests: [Matter::InteractionModel::AttributePath.new(
        endpoint: 0_u16,
        cluster: Matter::Cluster::BasicInformation::CLUSTER_ID,
        attribute: Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME,
      )]
    )
    message = Matter::Spec::ProtocolMessages.from_peer(
      session: session,
      message_type: Matter::InteractionModel::MessageType::ReadRequest.value,
      payload: request.to_slice,
      message_counter: 5_u32,
      exchange_id: 55_u16,
    )
    handler.handle_message(message, DEVICE_LOAD_PEER)

    status = handler.device_load_status(1_u8)
    status.total_interaction_model_messages_received.should eq(1_u32)
    status.total_interaction_model_messages_sent.should eq(1_u32)
    handler.handle_message(message, DEVICE_LOAD_PEER)
    handler.device_load_status(1_u8).total_interaction_model_messages_received.should eq(1_u32)
    handler.device_load_status(1_u8).total_interaction_model_messages_sent.should eq(1_u32)
    handler.handle_message(Matter::Spec::ProtocolMessages.standalone_ack(session, 6_u32, 55_u16), DEVICE_LOAD_PEER)
    handler.device_load_status(1_u8).total_interaction_model_messages_received.should eq(1_u32)
    handler.device_load_status(1_u8).total_interaction_model_messages_sent.should eq(1_u32)
    handler.close
  end
end
