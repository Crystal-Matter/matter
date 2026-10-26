require "../spec_helper"
require "../../src/matter/protocol/im_handler"

private ENDPOINT   = 1_u16
private LOCK_EVENT = Matter::Cluster::DoorLock::EVENT_LOCK_OPERATION
private ALARM      = Matter::Cluster::DoorLock::EVENT_DOOR_LOCK_ALARM

private record EventFixture,
  node : Matter::Node,
  lock : Matter::Cluster::DoorLock

# A node with a door lock on endpoint 1 and nothing journaled yet.
private def event_fixture : EventFixture
  node = Matter::Node.new
  endpoint = Matter::Endpoint.new(endpoint(ENDPOINT))
  lock = build(Matter::Cluster::DoorLock, ENDPOINT)
  endpoint.add_cluster(lock)
  node.add_endpoint(endpoint)
  EventFixture.new(node, lock)
end

private def read(
  fixture : EventFixture,
  paths : Array(Matter::InteractionModel::EventPath)?,
  filters : Array(Matter::InteractionModel::EventFilterIB)? = nil,
  fabric_index : UInt8? = nil,
  after : UInt64? = nil,
  local_node_id : UInt64? = nil,
) : Array(Matter::InteractionModel::EventReportIB)
  Matter::Protocol::IMHandler.read_events(
    paths,
    fixture.node.event_journal,
    fixture.node.clusters,
    filters,
    fabric_index,
    after: after,
    local_node_id: local_node_id
  )
end

private def wildcard : Array(Matter::InteractionModel::EventPath)
  [Matter::InteractionModel::EventPath.new]
end

private def statuses(reports : Array(Matter::InteractionModel::EventReportIB)) : Array(UInt8)
  reports.compact_map(&.event_status).map(&.status.status)
end

private def event_numbers(reports : Array(Matter::InteractionModel::EventReportIB)) : Array(UInt64)
  reports.compact_map(&.event_data).map(&.event_number)
end

describe "Matter::Protocol::IMHandler.read_events" do
  it "returns nothing when no event paths were requested" do
    fixture = event_fixture
    fixture.lock.lock(pin: fixture.lock.default_pin_code)

    read(fixture, nil).should be_empty
    read(fixture, [] of Matter::InteractionModel::EventPath).should be_empty
  end

  it "reports journaled events for a wildcard path, in event number order" do
    fixture = event_fixture
    fixture.lock.unlock(pin: fixture.lock.default_pin_code)
    fixture.lock.lock(pin: fixture.lock.default_pin_code)

    reports = read(fixture, wildcard)
    event_numbers(reports).should eq([1_u64, 2_u64])
    first = reports.compact_map(&.event_data).first
    first.path.cluster.should eq(Matter::Cluster::DoorLock::CLUSTER_ID)
    first.priority.critical?.should be_true
  end

  it "reports only the requested concrete path" do
    fixture = event_fixture
    fixture.lock.lock(pin: fixture.lock.default_pin_code)

    reports = read(fixture, [Matter::InteractionModel::EventPath.new(
      endpoint: ENDPOINT, cluster: Matter::Cluster::DoorLock::CLUSTER_ID, event: LOCK_EVENT)])
    event_numbers(reports).size.should eq(1)

    # A declared but never emitted event reports nothing and no status
    quiet = read(fixture, [Matter::InteractionModel::EventPath.new(
      endpoint: ENDPOINT, cluster: Matter::Cluster::DoorLock::CLUSTER_ID, event: ALARM)])
    quiet.should be_empty
  end

  it "answers a concrete path on a missing cluster with UnsupportedCluster" do
    fixture = event_fixture

    reports = read(fixture, [Matter::InteractionModel::EventPath.new(
      endpoint: ENDPOINT, cluster: 0x1234_u32, event: 0_u32)])
    statuses(reports).should eq([Matter::InteractionModel::StatusCode::UnsupportedCluster.value])
  end

  it "answers a concrete path for an undeclared event with UnsupportedEvent" do
    fixture = event_fixture

    reports = read(fixture, [Matter::InteractionModel::EventPath.new(
      endpoint: ENDPOINT, cluster: Matter::Cluster::DoorLock::CLUSTER_ID, event: 0x99_u32)])
    statuses(reports).should eq([Matter::InteractionModel::StatusCode::UnsupportedEvent.value])
  end

  it "stays silent for a wildcard path that matches nothing" do
    fixture = event_fixture

    read(fixture, [Matter::InteractionModel::EventPath.new(cluster: 0x1234_u32)]).should be_empty
  end

  it "hides a fabric scoped event from another fabric" do
    fixture = event_fixture
    fixture.node.event_journal.record(
      ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, LOCK_EVENT, :critical, TLV::Any.new(1_u32, nil), fabric_index: 1_u8)
    fixture.node.event_journal.record(
      ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, ALARM, :critical, TLV::Any.new(2_u32, nil))

    event_numbers(read(fixture, wildcard, fabric_index: 1_u8)).should eq([1_u64, 2_u64])
    event_numbers(read(fixture, wildcard, fabric_index: 2_u8)).should eq([2_u64])
  end

  it "honours the highest event minimum across the event filters" do
    fixture = event_fixture
    3.times { fixture.lock.lock(pin: fixture.lock.default_pin_code) }

    filters = [
      Matter::InteractionModel::EventFilterIB.new(event_min: 2_u64),
      Matter::InteractionModel::EventFilterIB.new(event_min: 3_u64, node: 7_u64),
    ]
    event_numbers(read(fixture, wildcard, filters, local_node_id: 7_u64)).should eq([3_u64])
  end

  it "ignores filters for other nodes while applying matching and unspecified filters" do
    fixture = event_fixture
    3.times { fixture.lock.lock(pin: fixture.lock.default_pin_code) }

    foreign = Matter::InteractionModel::EventFilterIB.new(event_min: 99_u64, node: 8_u64)
    unspecified = Matter::InteractionModel::EventFilterIB.new(event_min: 2_u64)
    matching = Matter::InteractionModel::EventFilterIB.new(event_min: 3_u64, node: 7_u64)

    event_numbers(read(fixture, wildcard, [foreign], local_node_id: 7_u64)).should eq([1_u64, 2_u64, 3_u64])
    event_numbers(read(fixture, wildcard, [foreign, unspecified], local_node_id: 7_u64)).should eq([2_u64, 3_u64])
    event_numbers(read(fixture, wildcard, [foreign, unspecified, matching], local_node_id: 7_u64)).should eq([3_u64])
    event_numbers(read(fixture, wildcard, [matching], local_node_id: 7_u64, after: 2_u64)).should eq([3_u64])
    unspecified_node = Matter::InteractionModel::EventFilterIB.new(event_min: 2_u64,
      node: Matter::DataType::NodeId::UNSPECIFIED)
    event_numbers(read(fixture, wildcard, [foreign, unspecified_node])).should eq([2_u64, 3_u64])
  end

  it "skips what a subscription has already reported" do
    fixture = event_fixture
    2.times { fixture.lock.lock(pin: fixture.lock.default_pin_code) }

    event_numbers(read(fixture, wildcard, after: 1_u64)).should eq([2_u64])
  end

  it "drops events whose cluster no longer declares them" do
    fixture = event_fixture
    fixture.node.event_journal.record(
      9_u16, Matter::Cluster::DoorLock::CLUSTER_ID, LOCK_EVENT, :critical, TLV::Any.new(1_u32, nil))

    read(fixture, wildcard).should be_empty
  end
end

describe "Matter::Protocol::IMHandler.encode_chunked_report_data" do
  it "shares one chunk budget between attribute and event reports" do
    attribute = Matter::InteractionModel::AttributeReportIB.new(
      attribute_data: Matter::InteractionModel::AttributeDataIB.new(
        path: Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 6_u32, attribute: 0_u32),
        data: TLV::Any.new(true, nil),
        data_version: 1_u32
      )
    )
    event = Matter::InteractionModel::EventReportIB.new(
      event_data: Matter::InteractionModel::EventDataIB.new(
        path: Matter::InteractionModel::EventPath.new(endpoint: 1_u16, cluster: 6_u32, event: 0_u32),
        event_number: 1_u64,
        priority: Matter::InteractionModel::EventPriority::Info,
        data: TLV::Any.new(Bytes.new(400, 7_u8), nil)
      )
    )

    # Four events of ~400 bytes cannot share a single 1100 byte payload
    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data([attribute], nil, [event, event, event, event])
    chunks.size.should be > 1
    chunks.each { |bytes, _| bytes.size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE + 500 }
    chunks.last[1].should be_true

    decoded = chunks.map { |bytes, _| Matter::InteractionModel::ReportDataMessage.from_slice(bytes) }
    decoded.sum { |message| (message.attribute_reports || [] of Matter::InteractionModel::AttributeReportIB).size }.should eq(1)
    decoded.sum { |message| (message.event_reports || [] of Matter::InteractionModel::EventReportIB).size }.should eq(4)
    decoded[0...-1].each(&.more_chunked_messages.should(be_true))
    decoded.last.more_chunked_messages.should be_nil
  end

  it "still produces one empty chunk when there is nothing to report" do
    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data([] of Matter::InteractionModel::AttributeReportIB)

    chunks.size.should eq(1)
    chunks.first[1].should be_true
    message = Matter::InteractionModel::ReportDataMessage.from_slice(chunks.first[0])
    message.attribute_reports.should be_nil
    message.event_reports.should be_nil
  end
end
