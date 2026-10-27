require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private KEEP_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private class KeepRecordingPersistence < Matter::Protocol::Persistence::Base
  getter removed : Array(UInt32) = [] of UInt32

  def restore(registry : Matter::Protocol::SessionRegistry, fabric_table : Matter::FabricTable) : Nil
  end

  def session_established(registry : Matter::Protocol::SessionRegistry, session : Matter::Session::SecureContext) : Nil
  end

  def session_updated(registry : Matter::Protocol::SessionRegistry, session : Matter::Session::SecureContext) : Nil
  end

  def session_removed(registry : Matter::Protocol::SessionRegistry, session_id : UInt16) : Nil
  end

  def subscription_established(registry : Matter::Protocol::SessionRegistry, subscription : Matter::Protocol::ActiveSubscription) : Nil
  end

  def subscription_removed(registry : Matter::Protocol::SessionRegistry, subscription_id : UInt32) : Nil
    @removed << subscription_id
  end
end

private def keep_session(id : UInt16, fabric : UInt8, node : UInt64) : Matter::Session::SecureContext
  session = Matter::Spec::ProtocolMessages.case_session(id)
  session.fabric_index = fabric
  session.peer_node_id = Matter::DataType::NodeId.new(node)
  session
end

private def active_keep_subscription(id : UInt32, session : Matter::Session::SecureContext) : Matter::Protocol::ActiveSubscription
  Matter::Protocol::ActiveSubscription.new(
    subscription_id: id,
    min_interval: 0_u16,
    max_interval: 60_u16,
    peer: KEEP_PEER,
    session: session,
    attribute_paths: [] of Matter::InteractionModel::AttributePath,
    exchange_id: id.to_u16
  )
end

private def send_keep_request(handler : Matter::Protocol::MessageHandler,
                              session : Matter::Session::SecureContext,
                              keep : Bool) : Nil
  request = Matter::InteractionModel::SubscribeRequestMessage.new(
    keep_subscriptions: keep,
    min_interval_floor: 0_u16,
    max_interval_ceiling: 60_u16
  )
  handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
    session: session,
    message_type: Matter::InteractionModel::MessageType::SubscribeRequest.value,
    payload: request.to_slice,
    message_counter: 5_u32,
    exchange_id: 55_u16
  ), KEEP_PEER)
end

describe "SubscribeRequest KeepSubscriptions" do
  it "deletes matching persisted subscription documents" do
    storage = Matter::Storage::Memory.new
    persistence = Matter::Protocol::Persistence::StorageBackend.new(storage)
    registry = Matter::Protocol::SessionRegistry.new(
      mrp_cache: Matter::Protocol::MrpCache.new(Matter::Spec::CaptureTransport.new_for_spec),
      persistence: persistence
    )
    subscriber = keep_session(1_u16, 1_u8, 0x2222_u64)
    other_node = keep_session(3_u16, 1_u8, 0x3333_u64)
    registry.add_subscription(active_keep_subscription(10_u32, subscriber))
    registry.add_subscription(active_keep_subscription(11_u32, other_node))
    collection = Matter::Storage::Collections::SUBSCRIPTIONS
    storage.ids(collection).sort!.should eq(["10", "11"])

    registry.remove_subscriptions_for_subscriber(1_u8, 0x2222_u64)

    storage.ids(collection).should eq(["11"])
    registry.active_subscriptions.keys.should eq([11_u32])
  end

  it "removes active and pending subscriptions from the same fabric and CASE node when false" do
    persistence = KeepRecordingPersistence.new
    handler = Matter::Protocol::MessageHandler.new(
      transport: Matter::Spec::CaptureTransport.new_for_spec,
      setup_pin: 20202021_u32,
      discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new),
      persistence: persistence
    )
    subscriber = keep_session(1_u16, 1_u8, 0x2222_u64)
    resumed = keep_session(3_u16, 1_u8, 0x2222_u64)
    other_node = keep_session(5_u16, 1_u8, 0x3333_u64)
    other_fabric = keep_session(7_u16, 2_u8, 0x2222_u64)
    [subscriber, resumed, other_node, other_fabric].each { |session| handler.sessions[session.session_id] = session }
    handler.active_subscriptions[1_u32] = active_keep_subscription(1_u32, subscriber)
    handler.active_subscriptions[2_u32] = active_keep_subscription(2_u32, resumed)
    handler.active_subscriptions[3_u32] = active_keep_subscription(3_u32, other_node)
    handler.active_subscriptions[4_u32] = active_keep_subscription(4_u32, other_fabric)
    handler.subscriptions.await_subscription(44_u16,
      Matter::Protocol::SubscriptionManager::PendingSubscription.new(
        subscription_id: 5_u32,
        min_interval: 0_u16,
        max_interval: 60_u16,
        attribute_paths: [] of Matter::InteractionModel::AttributePath,
        peer: KEEP_PEER,
        session: resumed,
        remaining_chunks: [] of Bytes
      ))

    send_keep_request(handler, subscriber, false)

    handler.active_subscriptions.keys.sort!.should eq([3_u32, 4_u32])
    persistence.removed.sort!.should eq([1_u32, 2_u32])
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(resumed, 5_u32, 44_u16), KEEP_PEER)
    handler.active_subscriptions.has_key?(5_u32).should be_false
    handler.close
  end

  it "retains existing subscriptions when true" do
    handler = Matter::Protocol::MessageHandler.new(
      transport: Matter::Spec::CaptureTransport.new_for_spec,
      setup_pin: 20202021_u32,
      discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new)
    )
    subscriber = keep_session(1_u16, 1_u8, 0x2222_u64)
    handler.sessions[subscriber.session_id] = subscriber
    handler.active_subscriptions[1_u32] = active_keep_subscription(1_u32, subscriber)

    send_keep_request(handler, subscriber, true)

    handler.active_subscriptions.has_key?(1_u32).should be_true
    handler.close
  end

  it "rejects a subscription whose minimum interval exceeds its maximum" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(
      transport: transport,
      setup_pin: 20202021_u32,
      discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new)
    )
    subscriber = keep_session(1_u16, 1_u8, 0x2222_u64)
    handler.sessions[subscriber.session_id] = subscriber
    handler.active_subscriptions[1_u32] = active_keep_subscription(1_u32, subscriber)
    path = Matter::InteractionModel::AttributePath.new(endpoint: 0_u16,
      cluster: Matter::Cluster::BasicInformation::CLUSTER_ID,
      attribute: Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME)
    request = Matter::InteractionModel::SubscribeRequestMessage.new(
      attribute_requests: [path], keep_subscriptions: false,
      min_interval_floor: 20_u16, max_interval_ceiling: 10_u16)

    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
      subscriber, Matter::InteractionModel::MessageType::SubscribeRequest.value,
      request.to_slice, 5_u32, 55_u16), KEEP_PEER)

    handler.active_subscriptions.should be_empty
    transport.sent_packets.size.should eq(1)
    packet = transport.sent_packets.first[0]
    Matter::Spec::ProtocolMessages.decode_message_type(packet, subscriber).should eq(
      Matter::InteractionModel::MessageType::StatusResponse.value)
    encrypted = Matter::Codec::MessageCodec::Base.decode_packet(packet)
    header = packet[0, packet.size - encrypted.payload.size]
    nonce = Matter::Session::SecureMessage.build_nonce(
      subscriber.local_node_id.as(Matter::DataType::NodeId).id,
      encrypted.header.message_id,
      header[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
    plaintext = Matter::Crypto::StandardCrypto.new.decrypt(subscriber.encryption_key,
      encrypted.payload, nonce, header)
    response = Matter::Codec::MessageCodec::Base.decode_payload(
      Matter::Codec::MessageCodec::Packet.new(encrypted.header, plaintext))
    Matter::InteractionModel::StatusResponseMessage.from_slice(response.payload).status.should eq(
      Matter::InteractionModel::StatusCode::InvalidAction.value)
    handler.close
  end
end
