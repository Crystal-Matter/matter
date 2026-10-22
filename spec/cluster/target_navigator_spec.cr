require "../spec_helper"
require "../../src/matter/cluster/target_navigator"

private alias TargetNavigator = Matter::Cluster::TargetNavigator
private alias IMCode = Matter::InteractionModel::StatusCode

private def navigator_fixture(current_target : UInt8? = 1_u8) : TargetNavigator
  build(TargetNavigator,
    target_list: [TargetNavigator::TargetInfo.new(1_u8, "Home"),
                  TargetNavigator::TargetInfo.new(2_u8, "Settings")],
    current_target: current_target)
end

describe TargetNavigator do
  it "advertises revision two, mandatory list, optional current target, and a typed response" do
    cluster = navigator_fixture
    cluster.cluster_id.id.should eq(0x0505_u32)
    read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(2_u16)
    read_tlv(cluster, TargetNavigator::ATTR_TARGET_LIST).as_list.size.should eq(2)
    read(cluster, TargetNavigator::ATTR_CURRENT_TARGET).should eq(1_u8)
    accepted_command_ids(cluster).should eq([TargetNavigator::CMD_NAVIGATE_TARGET])
    generated_command_ids(cluster).should eq([TargetNavigator::CMD_NAVIGATE_TARGET_RESPONSE])
    cluster.get_event_metadata(TargetNavigator::EVENT_TARGET_UPDATED).should_not be_nil
    cluster.get_command_metadata(TargetNavigator::CMD_NAVIGATE_TARGET).as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Operate)

    absent = navigator_fixture(nil)
    expect_status(read_status(absent, TargetNavigator::ATTR_CURRENT_TARGET), IMCode::UnsupportedAttribute)
    attribute_ids(absent).should_not contain(TargetNavigator::ATTR_CURRENT_TARGET)
  end

  it "validates unique bounded target identifiers and current target" do
    expect_raises(ArgumentError) { TargetNavigator::TargetInfo.new(255_u8, "Unavailable") }
    expect_raises(ArgumentError, /duplicate/) do
      build(TargetNavigator, target_list: [TargetNavigator::TargetInfo.new(1_u8, "A"),
                                           TargetNavigator::TargetInfo.new(1_u8, "B")])
    end
    expect_raises(ArgumentError, /current/) do
      build(TargetNavigator, target_list: [TargetNavigator::TargetInfo.new(1_u8, "A")], current_target: 2_u8)
    end
  end

  it "returns a TargetNotFound or NotAllowed response without changing current target" do
    cluster = navigator_fixture
    not_found = invoke_response(cluster, TargetNavigator::CMD_NAVIGATE_TARGET,
      TargetNavigator::NavigateTargetRequest.new(7_u8), TargetNavigator::NavigateTargetResponse)
    not_found.status.should eq(TargetNavigator::Status::TargetNotFound)

    denied = invoke_response(cluster, TargetNavigator::CMD_NAVIGATE_TARGET,
      TargetNavigator::NavigateTargetRequest.new(2_u8), TargetNavigator::NavigateTargetResponse)
    denied.status.should eq(TargetNavigator::Status::NotAllowed)
    cluster.current_target.should eq(1_u8)
  end

  it "passes optional Data to the host and updates CurrentTarget only on success" do
    cluster = navigator_fixture
    calls = [] of Tuple(UInt8, String?)
    cluster.on_navigate do |target, data|
      calls << {target.identifier, data}
      TargetNavigator::NavigationResult.new(TargetNavigator::Status::Success, "ready")
    end
    response = invoke_response(cluster, TargetNavigator::CMD_NAVIGATE_TARGET,
      TargetNavigator::NavigateTargetRequest.new(2_u8, "open"), TargetNavigator::NavigateTargetResponse)
    response.status.should eq(TargetNavigator::Status::Success)
    response.data.should eq("ready")
    calls.should eq([{2_u8, "open"}])
    cluster.current_target.should eq(2_u8)
    response.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    TargetNavigator::NavigateTargetRequest.new(2_u8).to_tlv(nil).as_structure.keys.should eq([0_u8])
  end

  it "reports host rejection without changing CurrentTarget" do
    cluster = navigator_fixture
    cluster.on_navigate do |_target, _data|
      TargetNavigator::NavigationResult.new(TargetNavigator::Status::NotAllowed)
    end
    response = invoke_response(cluster, TargetNavigator::CMD_NAVIGATE_TARGET,
      TargetNavigator::NavigateTargetRequest.new(2_u8), TargetNavigator::NavigateTargetResponse)
    response.status.should eq(TargetNavigator::Status::NotAllowed)
    response.data.should be_nil
    cluster.current_target.should eq(1_u8)
  end

  it "publishes changed targets and the optional revision-two TargetUpdated event" do
    cluster = navigator_fixture
    payloads = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(TargetNavigator::EVENT_TARGET_UPDATED)
      payloads << data
      nil
    end
    cluster.update_targets([TargetNavigator::TargetInfo.new(3_u8, "Search")], data: Bytes[0x41])
    cluster.current_target.should eq(255_u8)
    targets = read_tlv(cluster, TargetNavigator::ATTR_TARGET_LIST).as_list
    targets.size.should eq(1)
    event = TargetNavigator::TargetUpdatedEvent.from_tlv(payloads.last)
    event.target_list.as(Array(TargetNavigator::TargetInfo)).first.identifier.should eq(3_u8)
    event.current_target.should eq(255_u8)
    event.data.should eq(Bytes[0x41])
    expect_raises(ArgumentError) { cluster.update_targets([TargetNavigator::TargetInfo.new(3_u8, "A"), TargetNavigator::TargetInfo.new(3_u8, "B")]) }
    read_tlv(cluster, TargetNavigator::ATTR_TARGET_LIST).as_list.size.should eq(1)
  end
end
