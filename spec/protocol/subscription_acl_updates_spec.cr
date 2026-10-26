require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/camera_av_stream_management"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/message_handler"

private alias SubscriptionAcl = Matter::Cluster::AccessControl
private alias SubscriptionCamera = Matter::Cluster::CameraAvStreamManagement
private alias SubscriptionIM = Matter::Protocol::IMHandler

private class FabricAwareSubscriptionOnOff < Matter::Cluster::OnOff
  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    return TLV::Any.new(!request_fabric_filtered?) if attribute_id == ATTR_ON_OFF
    super
  end
end

private record SubscriptionAclFixture,
  handler : Matter::Protocol::MessageHandler,
  transport : Matter::Spec::CaptureTransport,
  session : Matter::Session::SecureContext,
  acl : SubscriptionAcl,
  camera : SubscriptionCamera

private def subscription_acl_fixture(privilege : SubscriptionAcl::AccessControlEntryPrivilege) : SubscriptionAclFixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  session.peer_subject_ids = [session.peer_node_id.as(Matter::DataType::NodeId).id]
  handler.sessions[session.session_id] = session

  acl = SubscriptionAcl.new(endpoint(0))
  acl.acl << SubscriptionAcl::AccessControlEntry.new(
    privilege,
    SubscriptionAcl::AccessControlEntryAuthMode::CASE,
    [session.peer_node_id.as(Matter::DataType::NodeId).id], nil, 1_u8)
  handler.node.clusters[{0_u16, SubscriptionAcl::CLUSTER_ID}] = acl

  camera = build(SubscriptionCamera,
    supported_stream_usages: [SubscriptionCamera::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 2_000_000_u32,
    video_sensor_params: SubscriptionCamera::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
    min_viewport_resolution: SubscriptionCamera::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [SubscriptionCamera::RateDistortionPoint.new(
      SubscriptionCamera::VideoCodec::H264,
      SubscriptionCamera::VideoResolution.new(1280_u16, 720_u16), 200_000_u32)],
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: SubscriptionCamera::Feature::Video)
  handler.node.clusters[{1_u16, SubscriptionCamera::CLUSTER_ID}] = camera
  SubscriptionAclFixture.new(handler, transport, session, acl, camera)
end

private def subscription_acl_set_privilege(fixture : SubscriptionAclFixture,
                                           privilege : SubscriptionAcl::AccessControlEntryPrivilege) : Nil
  fixture.acl.acl.clear
  fixture.acl.acl << SubscriptionAcl::AccessControlEntry.new(
    privilege,
    SubscriptionAcl::AccessControlEntryAuthMode::CASE,
    [fixture.session.peer_node_id.as(Matter::DataType::NodeId).id], nil, 1_u8)
end

private def subscription_acl_activate(fixture : SubscriptionAclFixture,
                                      attributes : Array(Matter::InteractionModel::AttributePath),
                                      events : Array(Matter::InteractionModel::EventPath)) : Nil
  fixture.handler.active_subscriptions[1_u32] = Matter::Protocol::ActiveSubscription.new(
    subscription_id: 1_u32, min_interval: 0_u16, max_interval: 60_u16,
    peer: Socket::IPAddress.new("127.0.0.1", 5540), session: fixture.session,
    attribute_paths: attributes, exchange_id: 11_u16, event_paths: events,
    last_event_number: fixture.handler.node.event_journal.latest_event_number)
  fixture.transport.sent_packets.clear
end

private def subscription_acl_viewport_path(wildcard : Bool = false) : Matter::InteractionModel::AttributePath
  Matter::InteractionModel::AttributePath.new(
    endpoint: wildcard ? nil : 1_u16,
    cluster: SubscriptionCamera::CLUSTER_ID,
    attribute: wildcard ? nil : SubscriptionCamera::ATTR_VIEWPORT)
end

private def subscription_acl_report(bytes : Bytes, session : Matter::Session::SecureContext) : Matter::InteractionModel::ReportDataMessage
  packet = Matter::Codec::MessageCodec::Base.decode_packet(bytes)
  header = bytes[0, bytes.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    packet.header.message_id,
    header[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(
    session.encryption_key, packet.payload, nonce, header)
  payload = Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload
  Matter::InteractionModel::ReportDataMessage.from_slice(payload)
end

describe "active subscription ACL updates" do
  it "preserves an unfiltered SubscribeRequest through activation, update and restart" do
    fixture = subscription_acl_fixture(SubscriptionAcl::AccessControlEntryPrivilege::View)
    sensor = FabricAwareSubscriptionOnOff.new(endpoint(2))
    fixture.handler.node.clusters[{2_u16, FabricAwareSubscriptionOnOff::CLUSTER_ID}] = sensor
    path = Matter::InteractionModel::AttributePath.new(endpoint: 2_u16,
      cluster: FabricAwareSubscriptionOnOff::CLUSTER_ID,
      attribute: FabricAwareSubscriptionOnOff::ATTR_ON_OFF)
    request = Matter::InteractionModel::SubscribeRequestMessage.new(
      attribute_requests: [path], min_interval_floor: 0_u16,
      max_interval_ceiling: 60_u16, is_fabric_filtered: false)
    fixture.handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
      fixture.session, Matter::InteractionModel::MessageType::SubscribeRequest.value,
      request.to_slice, 3_u32, 31_u16), Socket::IPAddress.new("127.0.0.1", 5540))
    first = subscription_acl_report(fixture.transport.sent_packets.first[0], fixture.session)
    first.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as_bool.should be_true

    fixture.handler.handle_message(Matter::Spec::ProtocolMessages.status_response(
      fixture.session, 4_u32, 31_u16), Socket::IPAddress.new("127.0.0.1", 5540))
    fixture.handler.active_subscriptions.size.should eq(1)
    active = fixture.handler.active_subscriptions.values.first
    active.fabric_filtered?.should be_false
    record = Matter::Protocol::ActiveSubscription::SubscriptionRecord.from_document(active.to_record.to_document)
    Matter::Protocol::ActiveSubscription.from_record(record, fixture.session).fabric_filtered?.should be_false
    fixture.transport.sent_packets.clear

    fixture.handler.subscriptions.notify(2_u16, FabricAwareSubscriptionOnOff::CLUSTER_ID,
      FabricAwareSubscriptionOnOff::ATTR_ON_OFF)
    update = subscription_acl_report(fixture.transport.sent_packets.first[0], fixture.session)
    update.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as_bool.should be_true
    fixture.handler.close
  end

  it "does not disclose a Manage viewport after View-only priming, including a wildcard path" do
    fixture = subscription_acl_fixture(SubscriptionAcl::AccessControlEntryPrivilege::View)
    [false, true].each do |wildcard|
      path = subscription_acl_viewport_path(wildcard)
      priming = SubscriptionIM.read_attributes([path], fixture.handler.node.clusters,
        fabric_index: 1_u8, is_case_session: true, peer_subject_ids: fixture.session.peer_subject_ids)
      priming.any? { |report| report.attribute_data.try(&.path.attribute) == SubscriptionCamera::ATTR_VIEWPORT }
        .should be_false

      subscription_acl_activate(fixture, [path], [] of Matter::InteractionModel::EventPath)
      fixture.camera.viewport = SubscriptionCamera::Viewport.new(0_u16, 0_u16, 1280_u16, 720_u16)
      fixture.handler.subscriptions.notify(1_u16, SubscriptionCamera::CLUSTER_ID,
        SubscriptionCamera::ATTR_VIEWPORT)
      fixture.transport.sent_packets.should be_empty
    end
    fixture.handler.close
  end

  it "stops viewport updates when Manage privilege is revoked after priming" do
    fixture = subscription_acl_fixture(SubscriptionAcl::AccessControlEntryPrivilege::Manage)
    path = subscription_acl_viewport_path
    priming = SubscriptionIM.read_attributes([path], fixture.handler.node.clusters,
      fabric_index: 1_u8, is_case_session: true, peer_subject_ids: fixture.session.peer_subject_ids)
    priming.first.attribute_data.should_not be_nil
    subscription_acl_activate(fixture, [path], [] of Matter::InteractionModel::EventPath)
    subscription_acl_set_privilege(fixture, SubscriptionAcl::AccessControlEntryPrivilege::View)

    fixture.camera.viewport = SubscriptionCamera::Viewport.new(0_u16, 0_u16, 1280_u16, 720_u16)
    fixture.handler.subscriptions.notify(1_u16, SubscriptionCamera::CLUSTER_ID,
      SubscriptionCamera::ATTR_VIEWPORT)
    fixture.transport.sent_packets.should be_empty
    fixture.handler.close
  end

  it "does not disclose Admin events after View-only priming or ACL revocation" do
    fixture = subscription_acl_fixture(SubscriptionAcl::AccessControlEntryPrivilege::View)
    path = Matter::InteractionModel::EventPath.new(
      endpoint: 0_u16, cluster: SubscriptionAcl::CLUSTER_ID,
      event: SubscriptionAcl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED)
    priming = SubscriptionIM.read_events([path], fixture.handler.node.event_journal,
      fixture.handler.node.clusters, fabric_index: 1_u8, is_case_session: true,
      peer_subject_ids: fixture.session.peer_subject_ids)
    priming.first.event_status.as(Matter::InteractionModel::EventStatusIB).status.status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)

    subscription_acl_activate(fixture, [] of Matter::InteractionModel::AttributePath, [path])
    fixture.handler.node.event_journal.record(0_u16, SubscriptionAcl::CLUSTER_ID,
      SubscriptionAcl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED, :info, TLV::Any.new("other fabric"),
      fabric_index: 2_u8)
    fixture.handler.subscriptions.notify_events
    fixture.transport.sent_packets.should be_empty

    fixture.handler.node.event_journal.record(0_u16, SubscriptionAcl::CLUSTER_ID,
      SubscriptionAcl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED, :info, TLV::Any.new("secret"),
      fabric_index: 1_u8)
    fixture.handler.subscriptions.notify_events
    fixture.transport.sent_packets.should be_empty

    subscription_acl_set_privilege(fixture, SubscriptionAcl::AccessControlEntryPrivilege::Administer)
    # An event suppressed while access was denied must not replay on a later grant.
    fixture.handler.subscriptions.notify_events
    fixture.transport.sent_packets.should be_empty
    fixture.handler.node.event_journal.record(0_u16, SubscriptionAcl::CLUSTER_ID,
      SubscriptionAcl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED, :info, TLV::Any.new("newly allowed"),
      fabric_index: 1_u8)
    priming = SubscriptionIM.read_events([path], fixture.handler.node.event_journal,
      fixture.handler.node.clusters, fabric_index: 1_u8, is_case_session: true,
      peer_subject_ids: fixture.session.peer_subject_ids)
    priming.any? { |report| !report.event_data.nil? }.should be_true
    subscription_acl_activate(fixture, [] of Matter::InteractionModel::AttributePath, [path])
    subscription_acl_set_privilege(fixture, SubscriptionAcl::AccessControlEntryPrivilege::View)
    fixture.handler.node.event_journal.record(0_u16, SubscriptionAcl::CLUSTER_ID,
      SubscriptionAcl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED, :info, TLV::Any.new("revoked"),
      fabric_index: 1_u8)
    fixture.handler.subscriptions.notify_events
    fixture.transport.sent_packets.should be_empty
    fixture.handler.close
  end
end
