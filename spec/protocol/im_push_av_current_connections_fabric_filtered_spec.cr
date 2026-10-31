require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/push_av_stream_transport"
require "../../src/matter/protocol/im_handler"

private alias FabricPushAv = Matter::Cluster::PushAvStreamTransport
private alias FabricPushAvAcl = Matter::Cluster::AccessControl

private def read_push_av_connections(cluster : FabricPushAv, acl : FabricPushAvAcl,
                                     fabric_index : UInt8, fabric_filtered : Bool) : Array(FabricPushAv::Tlv::TransportConfiguration)
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: cluster.endpoint_id.number,
    cluster: FabricPushAv::CLUSTER_ID,
    attribute: FabricPushAv::ATTR_CURRENT_CONNECTIONS)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, FabricPushAvAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
    {cluster.endpoint_id.number, FabricPushAv::CLUSTER_ID}        => cluster.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: fabric_index, is_case_session: true, peer_subject_ids: [101_u64],
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  data = reports.first.attribute_data || fail "expected CurrentConnections attribute data"
  TLV::Serializable.deserialize_value(data.data, Array(FabricPushAv::Tlv::TransportConfiguration))
end

private def push_av_fabric_options : FabricPushAv::Tlv::TransportOptions
  cmaf = FabricPushAv::Tlv::CmafContainerOptions.new(FabricPushAv::CmafInterface::Interface1, 1000_u16, 500_u16)
  trigger = FabricPushAv::Tlv::TriggerOptions.new(FabricPushAv::TriggerType::Command, max_pre_roll_len: 0_u16)
  FabricPushAv::Tlv::TransportOptions.new(FabricPushAv::StreamUsage::Recording, 1_u16,
    "https://host.test/ingest", trigger, FabricPushAv::IngestMethod::CmafIngest,
    FabricPushAv::Tlv::ContainerOptions.new(FabricPushAv::ContainerFormat::Cmaf, cmaf),
    video_streams: [FabricPushAv::Tlv::VideoStream.new("main", 1_u16)])
end

describe "Push AV CurrentConnections fabric filtering" do
  it "returns both fabrics only on an unfiltered authenticated read, including after restore" do
    acl = FabricPushAvAcl.new(endpoint(0))
    [1_u8, 2_u8].each do |fabric_index|
      acl.acl << FabricPushAvAcl::AccessControlEntry.new(
        FabricPushAvAcl::AccessControlEntryPrivilege::Administer,
        FabricPushAvAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, fabric_index)
    end
    cluster = FabricPushAv.new(endpoint(1))
    cluster.request_is_case_session = true
    cluster.fabric_installed = ->(fabric : UInt8) { fabric.in?(1_u8..2_u8) }
    cluster.tls_endpoint_exists = ->(fabric : UInt8, id : UInt16) { fabric.in?(1_u8..2_u8) && id == 1_u16 }
    cluster.video_stream_exists = ->(id : UInt16) { id == 1_u16 }
    [1_u8, 2_u8].each do |fabric_index|
      cluster.request_fabric_index = fabric_index
      cluster.allocate_push_transport(FabricPushAv::Tlv::AllocateRequest.new(push_av_fabric_options))
        .should be_a(FabricPushAv::Tlv::AllocateResponse)
    end

    restored = FabricPushAv.new(endpoint(1))
    restored.fabric_installed = ->(fabric : UInt8) { fabric.in?(1_u8..2_u8) }
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    [cluster, restored].each do |push|
      [1_u8, 2_u8].each do |fabric_index|
        filtered = read_push_av_connections(push, acl, fabric_index, true)
        filtered.map(&.fabric_index).should eq([fabric_index])
        filtered.first.transport_options.should be_nil

        unfiltered = read_push_av_connections(push, acl, fabric_index, false)
        unfiltered.map(&.fabric_index).should eq([1_u8, 2_u8])
        unfiltered.map(&.connection_id).should eq([0_u16, 1_u16])
        unfiltered.each { |entry| entry.transport_options.should be_nil }
      end
    end

    cluster.request_fabric_index = nil
    cluster.request_fabric_filtered = false
    cluster.read_attribute(FabricPushAv::ATTR_CURRENT_CONNECTIONS)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
  end
end
