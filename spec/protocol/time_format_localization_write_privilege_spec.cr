require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/time_format_localization"
require "../../src/matter/protocol/im_handler"

private alias FormatCluster = Matter::Cluster::TimeFormatLocalization
private alias FormatAcl = Matter::Cluster::AccessControl
private FORMAT_SUBJECT = 0x1234_u64

private def format_clusters(cluster : FormatCluster, privilege : FormatAcl::AccessControlEntryPrivilege)
  acl = FormatAcl.new(endpoint(0))
  acl.acl << FormatAcl::AccessControlEntry.new(privilege,
    FormatAcl::AccessControlEntryAuthMode::CASE, [FORMAT_SUBJECT], nil, 1_u8)
  {
    {0_u16, FormatAcl::CLUSTER_ID}     => acl.as(Matter::Cluster::Base),
    {1_u16, FormatCluster::CLUSTER_ID} => cluster.as(Matter::Cluster::Base),
  }
end

private def serialized_format_write(clusters, attribute : UInt32, value : UInt8) : UInt8
  request = Matter::InteractionModel::WriteRequestMessage.new(
    suppress_response: false, timed_request: false,
    write_requests: [Matter::InteractionModel::AttributeDataIB.new(
      path: Matter::InteractionModel::AttributePath.new(
        endpoint: 1_u16, cluster: FormatCluster::CLUSTER_ID, attribute: attribute),
      data: TLV::Serializable.serialize_value(value, nil))])
  parsed = Matter::Protocol::IMHandler.parse_write_request(request.to_slice)
    .as(Matter::InteractionModel::WriteRequestMessage)
  Matter::Protocol::IMHandler.write_attributes(parsed.write_requests, clusters,
    is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [FORMAT_SUBJECT])
    .first.status.status
end

describe "Matter 1.6 Time Format Localization write privilege" do
  it "requires Manage for HourFormat while allowing View reads" do
    cluster = FormatCluster.new(endpoint(1))
    operate_clusters = format_clusters(cluster, FormatAcl::AccessControlEntryPrivilege::Operate)

    serialized_format_write(operate_clusters, FormatCluster::ATTR_HOUR_FORMAT,
      FormatCluster::HourFormat::Hr12.value).should eq(
      Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    cluster.hour_format.should eq(FormatCluster::HourFormat::Hr24)

    view_clusters = format_clusters(cluster, FormatAcl::AccessControlEntryPrivilege::View)
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: FormatCluster::CLUSTER_ID,
      attribute: FormatCluster::ATTR_HOUR_FORMAT)
    Matter::Protocol::IMHandler.read_attributes([path], view_clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [FORMAT_SUBJECT])
      .first.attribute_data.should_not be_nil

    manage_clusters = format_clusters(cluster, FormatAcl::AccessControlEntryPrivilege::Manage)
    serialized_format_write(manage_clusters, FormatCluster::ATTR_HOUR_FORMAT,
      FormatCluster::HourFormat::Hr12.value).should eq(
      Matter::InteractionModel::StatusCode::Success.value)
    cluster.hour_format.should eq(FormatCluster::HourFormat::Hr12)
  end

  it "requires Manage for ActiveCalendarType only when CALFMT is advertised" do
    cluster = FormatCluster.new(endpoint(1),
      feature_map: FormatCluster::Feature::CalendarFormat,
      active_calendar_type: FormatCluster::CalendarType::Gregorian,
      supported_calendar_types: [FormatCluster::CalendarType::Gregorian,
                                 FormatCluster::CalendarType::Buddhist])
    operate_clusters = format_clusters(cluster, FormatAcl::AccessControlEntryPrivilege::Operate)
    serialized_format_write(operate_clusters, FormatCluster::ATTR_ACTIVE_CALENDAR_TYPE,
      FormatCluster::CalendarType::Buddhist.value).should eq(
      Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    cluster.active_calendar_type.should eq(FormatCluster::CalendarType::Gregorian)

    manage_clusters = format_clusters(cluster, FormatAcl::AccessControlEntryPrivilege::Manage)
    serialized_format_write(manage_clusters, FormatCluster::ATTR_ACTIVE_CALENDAR_TYPE,
      FormatCluster::CalendarType::Buddhist.value).should eq(
      Matter::InteractionModel::StatusCode::Success.value)
    cluster.active_calendar_type.should eq(FormatCluster::CalendarType::Buddhist)

    base = FormatCluster.new(endpoint(1))
    base.get_attribute_metadata(FormatCluster::ATTR_ACTIVE_CALENDAR_TYPE).should be_nil
    serialized_format_write(format_clusters(base, FormatAcl::AccessControlEntryPrivilege::Manage),
      FormatCluster::ATTR_ACTIVE_CALENDAR_TYPE, FormatCluster::CalendarType::Gregorian.value)
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute.value)
  end
end
