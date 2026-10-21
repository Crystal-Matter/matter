require "../spec_helper"
require "../../src/matter/interaction_model/tlv_messages"
require "../../src/matter/protocol/im_handler"

private def find_attribute_data_any(
  reports : Array(Matter::InteractionModel::AttributeReportIB),
  endpoint : UInt16,
  cluster : UInt32,
  attribute : UInt32,
) : TLV::Any?
  reports.each do |report|
    data_ib = report.attribute_data
    next unless data_ib

    path = data_ib.path
    next unless path.endpoint == endpoint
    next unless path.cluster == cluster
    next unless path.attribute == attribute

    return data_ib.data
  end

  nil
end

private def find_attribute_status(
  reports : Array(Matter::InteractionModel::AttributeReportIB),
  endpoint : UInt16,
  cluster : UInt32,
  attribute : UInt32,
) : Matter::InteractionModel::AttributeStatusIB?
  reports.each do |report|
    status_ib = report.attribute_status
    next unless status_ib

    path = status_ib.path
    next unless path.endpoint == endpoint
    next unless path.cluster == cluster
    next unless path.attribute == attribute

    return status_ib
  end

  nil
end

private class BrokenTlvCluster < Matter::Cluster::Base
  CLUSTER_ID  = 0x1234_u32
  ATTR_GOOD   = 0x0000_u32
  ATTR_BROKEN = 0x0001_u32

  def initialize(endpoint_id : Matter::DataType::EndpointNumber)
    super(endpoint_id, Matter::DataType::ClusterId.new(CLUSTER_ID))
  end

  def name : String
    "BrokenTlvCluster"
  end

  def attributes : Array(Matter::Cluster::AttributeMetadata)
    [
      Matter::Cluster::AttributeMetadata.new(
        id: Matter::DataType::AttributeId.new(ATTR_GOOD),
        name: "Good",
        type: :uint8,
      ),
      Matter::Cluster::AttributeMetadata.new(
        id: Matter::DataType::AttributeId.new(ATTR_BROKEN),
        name: "Broken",
        type: :uint8,
      ),
    ]
  end

  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    case attribute_id
    when ATTR_GOOD
      TLV::Any.new(7_u8)
    when ATTR_BROKEN
      # A cluster decoding malformed stored data fails before returning a typed value.
      TLV::Any.from_slice(Bytes[0x24_u8])
    else
      super(attribute_id, fabric_index)
    end
  end
end

private class RaisingReadCluster < Matter::Cluster::Base
  CLUSTER_ID = 0x1235_u32
  ATTR_RAISE = 0x0000_u32

  def initialize(endpoint_id : Matter::DataType::EndpointNumber)
    super(endpoint_id, Matter::DataType::ClusterId.new(CLUSTER_ID))
  end

  def name : String
    "RaisingReadCluster"
  end

  def attributes : Array(Matter::Cluster::AttributeMetadata)
    [
      Matter::Cluster::AttributeMetadata.new(
        id: Matter::DataType::AttributeId.new(ATTR_RAISE),
        name: "RaisesOnRead",
        type: :uint8,
      ),
    ]
  end

  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    case attribute_id
    when ATTR_RAISE
      # Simulate a cluster implementation that raises while decoding stored TLV.
      TLV::Any.from_slice(Bytes[0x24_u8])
      TLV::Any.new(1_u8)
    else
      super(attribute_id, fabric_index)
    end
  end
end

describe "SubscribeRequestMessage with wildcard paths" do
  # This test validates parsing of SubscribeRequest from iOS/iPhone which uses
  # Boolean `true` to indicate wildcard for path fields (like event_id)
  # instead of simply omitting the field.
  #
  # The Matter spec allows Boolean true as a wildcard indicator for path fields.

  it "parses SubscribeRequest with wildcard event path from iPhone" do
    # Real bytes captured from iPhone commissioning:
    # 15290024010025025802360317181836041729041818280724ff0c18
    #
    # Decoded structure:
    # - tag 0: keep_subscriptions = true (BooleanTrue)
    # - tag 1: min_interval_floor = 0
    # - tag 2: max_interval_ceiling = 600 (0x0258)
    # - tag 3: attribute_requests = [empty AttributePath (wildcard)]
    # - tag 4: event_requests = [EventPath with tag 4 (is_urgent) = true]
    # - tag 7: is_fabric_filtered = false
    # - tag 0xFF: interaction_model_revision = 12
    bytes = Bytes[
      0x15,                   # Structure start
      0x29, 0x00,             # tag 0, BooleanTrue (keep_subscriptions = true)
      0x24, 0x01, 0x00,       # tag 1, UInt8 = 0 (min_interval_floor)
      0x25, 0x02, 0x58, 0x02, # tag 2, UInt16 = 600 (max_interval_ceiling)
      0x36, 0x03,             # tag 3, Array start (attribute_requests)
      0x17,                   # List start (empty AttributePath - wildcard)
      0x18,                   # End list
      0x18,                   # End array
      0x36, 0x04,             # tag 4, Array start (event_requests)
      0x17,                   # List start (EventPath)
      0x29, 0x04,             # tag 4, BooleanTrue (is_urgent = true)
      0x18,                   # End list
      0x18,                   # End array
      0x28, 0x07,             # tag 7, BooleanFalse (is_fabric_filtered = false)
      0x24, 0xff, 0x0c,       # tag 255, UInt8 = 12 (interaction_model_revision)
      0x18,                   # End structure
    ]

    msg = Matter::InteractionModel::SubscribeRequestMessage.from_slice(bytes)

    msg.keep_subscriptions?.should be_true
    msg.min_interval_floor.should eq(0_u16)
    msg.max_interval_ceiling.should eq(600_u16)
    msg.is_fabric_filtered?.should be_false
    msg.interaction_model_revision.should eq(12_u8)

    # Verify attribute_requests
    attr_requests = msg.attribute_requests.as(Array(Matter::InteractionModel::AttributePath))
    attr_requests.size.should eq(1)

    # Empty path = wildcard
    attr_path = attr_requests[0]
    attr_path.endpoint.should be_nil
    attr_path.cluster.should be_nil
    attr_path.attribute.should be_nil
    attr_path.wildcard?.should be_true

    # Verify event_requests
    event_requests = msg.event_requests.as(Array(Matter::InteractionModel::EventPath))
    event_requests.size.should eq(1)

    # EventPath with only is_urgent set
    event_path = event_requests[0]
    event_path.endpoint.should be_nil
    event_path.cluster.should be_nil
    event_path.event.should be_nil
    event_path.is_urgent?.should be_true
    event_path.wildcard?.should be_true
  end

  it "parses EventPath with explicit event ID" do
    # EventPath with a specific event ID (not wildcard)
    # List with: tag 1 = endpoint 0, tag 2 = cluster 0x0028, tag 3 = event 0
    bytes = Bytes[
      0x17,                   # List start
      0x24, 0x01, 0x00,       # tag 1, UInt8 = 0 (endpoint)
      0x25, 0x02, 0x28, 0x00, # tag 2, UInt16 = 0x0028 (cluster)
      0x24, 0x03, 0x00,       # tag 3, UInt8 = 0 (event)
      0x18,                   # End list
    ]

    path = Matter::InteractionModel::EventPath.from_slice(bytes)

    path.endpoint.should eq(0_u16)
    path.cluster.should eq(0x0028_u32)
    path.event.should eq(0_u32)
    path.wildcard?.should be_false
  end

  it "parses AttributePath with wildcard boolean for attribute field" do
    # AttributePath with attribute = true (wildcard)
    # Some controllers may send this format
    bytes = Bytes[
      0x17,                   # List start
      0x24, 0x02, 0x00,       # tag 2, UInt8 = 0 (endpoint)
      0x25, 0x03, 0x06, 0x00, # tag 3, UInt16 = 0x0006 (cluster)
      0x29, 0x04,             # tag 4, BooleanTrue (attribute = wildcard)
      0x18,                   # End list
    ]

    path = Matter::InteractionModel::AttributePath.from_slice(bytes)

    path.endpoint.should eq(0_u16)
    path.cluster.should eq(0x0006_u32)
    path.attribute.should be_nil # Wildcard true should be treated as nil
    path.wildcard?.should be_true
  end

  describe "IMHandler.read_attributes with wildcard paths" do
    it "handles empty attribute requests array" do
      clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
      reports = Matter::Protocol::IMHandler.read_attributes(
        [] of Matter::InteractionModel::AttributePath,
        clusters
      )
      reports.should be_empty
    end

    it "handles nil attribute requests" do
      clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
      reports = Matter::Protocol::IMHandler.read_attributes(
        nil,
        clusters
      )
      reports.should be_empty
    end

    it "handles wildcard path with no matching clusters" do
      clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base

      # Wildcard path (all nil = match everything)
      wildcard_path = Matter::InteractionModel::AttributePath.new
      wildcard_path.wildcard?.should be_true

      reports = Matter::Protocol::IMHandler.read_attributes(
        [wildcard_path],
        clusters
      )
      reports.should be_empty
    end

    it "handles wildcard path expansion with OnOff cluster" do
      endpoint = endpoint(1)
      on_off = Matter::Cluster::OnOff.new(endpoint)

      clusters = {
        {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base),
      }

      # Wildcard path targeting all attributes on endpoint 1
      wildcard_path = Matter::InteractionModel::AttributePath.new(
        endpoint: 1_u16,
        cluster: Matter::Cluster::OnOff::CLUSTER_ID
      )

      reports = Matter::Protocol::IMHandler.read_attributes(
        [wildcard_path],
        clusters
      )

      # Should have reports for all OnOff attributes plus global attributes
      reports.size.should be > 0

      # All reports should have data (not status errors)
      reports.each do |report|
        # Either attribute_data or attribute_status should be present
        if data = report.attribute_data
          data.data.should_not be_nil
        end
      end
    end

    it "handles captured commissioning payload through wildcard attribute expansion" do
      payload = "15290024010025025802360317181836041729041818280724ff0c18".hexbytes
      request = Matter::Protocol::IMHandler.parse_subscribe_request(payload)
      request.should_not be_nil
      subscribe_request = request.as(Matter::InteractionModel::SubscribeRequestMessage)
      subscribe_request.data_version_filters.should be_nil

      endpoint0 = endpoint(0)
      endpoint1 = endpoint(1)

      admin = Matter::Cluster::AdministratorCommissioning.new(endpoint0)
      fan = Matter::Cluster::FanControl.new(
        endpoint1,
        fan_mode: Matter::Cluster::FanControl::FanMode::High,
        fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh,
        percent_setting: nil,
        percent_current: 75_u8
      )

      clusters = {
        {0_u16, Matter::Cluster::AdministratorCommissioning::CLUSTER_ID} => admin.as(Matter::Cluster::Base),
        {1_u16, Matter::Cluster::FanControl::CLUSTER_ID}                 => fan.as(Matter::Cluster::Base),
      }

      reports = Matter::Protocol::IMHandler.read_attributes(
        subscribe_request.attribute_requests,
        clusters
      )
      reports.should_not be_empty

      fan_mode = find_attribute_data_any(
        reports,
        1_u16,
        Matter::Cluster::FanControl::CLUSTER_ID,
        Matter::Cluster::FanControl::ATTR_FAN_MODE
      )
      fan_mode.should_not be_nil
      fan_mode.as(TLV::Any).as_u8.should eq(Matter::Cluster::FanControl::FanMode::High.value.to_u8)

      fan_mode_sequence = find_attribute_data_any(
        reports,
        1_u16,
        Matter::Cluster::FanControl::CLUSTER_ID,
        Matter::Cluster::FanControl::ATTR_FAN_MODE_SEQUENCE
      )
      fan_mode_sequence.should_not be_nil
      fan_mode_sequence.as(TLV::Any).as_u8.should eq(Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh.value.to_u8)

      fan_percent_setting = find_attribute_data_any(
        reports,
        1_u16,
        Matter::Cluster::FanControl::CLUSTER_ID,
        Matter::Cluster::FanControl::ATTR_PERCENT_SETTING
      )
      fan_percent_setting.should_not be_nil
      fan_percent_setting.as(TLV::Any).value.should be_nil

      fan_percent_current = find_attribute_data_any(
        reports,
        1_u16,
        Matter::Cluster::FanControl::CLUSTER_ID,
        Matter::Cluster::FanControl::ATTR_PERCENT_CURRENT
      )
      fan_percent_current.should_not be_nil
      fan_percent_current.as(TLV::Any).as_u8.should eq(75_u8)

      admin_fabric_index = find_attribute_data_any(
        reports,
        0_u16,
        Matter::Cluster::AdministratorCommissioning::CLUSTER_ID,
        Matter::Cluster::AdministratorCommissioning::ATTR_ADMIN_FABRIC_INDEX
      )
      admin_fabric_index.should_not be_nil
      admin_fabric_index.as(TLV::Any).value.should be_nil

      admin_vendor_id = find_attribute_data_any(
        reports,
        0_u16,
        Matter::Cluster::AdministratorCommissioning::CLUSTER_ID,
        Matter::Cluster::AdministratorCommissioning::ATTR_ADMIN_VENDOR_ID
      )
      admin_vendor_id.should_not be_nil
      admin_vendor_id.as(TLV::Any).value.should be_nil
    end

    it "handles malformed attribute TLV from wildcard subscribe request without raising" do
      payload = "152900240100250258023603171818360417290418182807360815370024010024023e1824010018153700240100240228182401001815370024010024021f182401071815370024010024021d1824010018153700240100240231182401001815370024010124021d18240100181537002401002402371824010018153700240100240230182401001815370024010224021d18240100181537002401022402061824010e1815370024010024023318240100181537002401022402401824010018153700240101240240182401001815370024010024023f182401001815370024010024023c182401001815370024010125020202182401001815370024010124020318240100181537002401022402031824010018153700240101240206182401041815370024010024022a1824010018153700240100240246182401001815370024010024023218240100181824ff0c18".hexbytes

      request = Matter::Protocol::IMHandler.parse_subscribe_request(payload)
      request.should_not be_nil
      subscribe_request = request.as(Matter::InteractionModel::SubscribeRequestMessage)
      subscribe_request.data_version_filters.as(Array(Matter::InteractionModel::DataVersionFilterIB)).size.should eq(22)

      endpoint1 = endpoint(1)
      broken_cluster = BrokenTlvCluster.new(endpoint1)
      clusters = {
        {1_u16, BrokenTlvCluster::CLUSTER_ID} => broken_cluster.as(Matter::Cluster::Base),
      }

      reports = Matter::Protocol::IMHandler.read_attributes(
        subscribe_request.attribute_requests,
        clusters
      )

      good_data = find_attribute_data_any(
        reports,
        1_u16,
        BrokenTlvCluster::CLUSTER_ID,
        BrokenTlvCluster::ATTR_GOOD
      )
      good_data.should_not be_nil
      good_data.as(TLV::Any).as_u8.should eq(7_u8)

      broken_status = find_attribute_status(
        reports,
        1_u16,
        BrokenTlvCluster::CLUSTER_ID,
        BrokenTlvCluster::ATTR_BROKEN
      )
      broken_status.should_not be_nil
      broken_status.as(Matter::InteractionModel::AttributeStatusIB).status.status.should eq(
        Matter::InteractionModel::StatusCode::Failure.value
      )
    end

    it "handles exceptions raised inside cluster read_attribute during wildcard subscribe" do
      payload = "152900240100250258023603171818360417290418182807360815370024010024023e1824010018153700240100240228182401001815370024010024021f182401071815370024010024021d1824010018153700240100240231182401001815370024010124021d18240100181537002401002402301824010018153700240100240237182401001815370024010224021d18240100181537002401022402061824011a1815370024010024023318240100181537002401022402401824010018153700240101240240182401001815370024010024023f182401001815370024010024023c182401001815370024010125020202182401001815370024010124020318240100181537002401022402031824010018153700240101240206182401041815370024010024022a1824010018153700240100240246182401001815370024010024023218240100181824ff0c18".hexbytes

      request = Matter::Protocol::IMHandler.parse_subscribe_request(payload)
      request.should_not be_nil
      subscribe_request = request.as(Matter::InteractionModel::SubscribeRequestMessage)

      endpoint1 = endpoint(1)
      raising_cluster = RaisingReadCluster.new(endpoint1)
      clusters = {
        {1_u16, RaisingReadCluster::CLUSTER_ID} => raising_cluster.as(Matter::Cluster::Base),
      }

      reports = Matter::Protocol::IMHandler.read_attributes(
        subscribe_request.attribute_requests,
        clusters
      )

      raised_status = find_attribute_status(
        reports,
        1_u16,
        RaisingReadCluster::CLUSTER_ID,
        RaisingReadCluster::ATTR_RAISE
      )
      raised_status.should_not be_nil
      raised_status.as(Matter::InteractionModel::AttributeStatusIB).status.status.should eq(
        Matter::InteractionModel::StatusCode::Failure.value
      )
    end
  end
end
