require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/protocol/im_handler"

private alias ScreenPrivilege = Matter::Cluster::AccessControl::AccessControlEntryPrivilege
private alias ScreenAuth = Matter::Cluster::AccessControl::AccessControlEntryAuthMode

describe "Content Control ScreenTime ACL context" do
  it "uses the caller's ACL privilege for PIN checks without carrying privilege to another invoke" do
    control = Matter::Cluster::ContentControl.new(endpoint(1),
      feature_map: Matter::Cluster::ContentControl::Feature::ScreenTime |
                   Matter::Cluster::ContentControl::Feature::PinManagement,
      screen_daily_time: 10_u32)
    acl = Matter::Cluster::AccessControl.new(endpoint(0))
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(ScreenPrivilege::Manage, ScreenAuth::CASE,
      [0x1111_u64], nil, 1_u8)
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(ScreenPrivilege::Operate, ScreenAuth::CASE,
      [0x2222_u64], nil, 1_u8)
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}] = acl
    clusters[{1_u16, Matter::Cluster::ContentControl::CLUSTER_ID}] = control
    pin = invoke_response(control, Matter::Cluster::ContentControl::CMD_RESET_PIN, nil,
      Matter::Cluster::ContentControl::ResetPinResponse).pin_code
    command = ->(provided_pin : String?, subject : UInt64) do
      payload = Matter::Cluster::ContentControl::AddBonusTimeRequest.new(provided_pin, 1_u32)
      path = Matter::InteractionModel::CommandPath.new(1_u16,
        Matter::Cluster::ContentControl::CLUSTER_ID,
        Matter::Cluster::ContentControl::CMD_ADD_BONUS_TIME)
      request = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Serializable.serialize_value(payload, nil))
      Matter::Protocol::IMHandler.invoke_commands([request], clusters,
        fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [subject]).first
    end

    command.call(nil, 0x1111_u64).command_status.as(Matter::InteractionModel::CommandStatusIB).status.status.should eq(0_u8)
    command.call(nil, 0x2222_u64).command_status.as(Matter::InteractionModel::CommandStatusIB).status.cluster_status.should eq(0x02_u8)
    command.call("wrong", 0x2222_u64).command_status.as(Matter::InteractionModel::CommandStatusIB).status.cluster_status.should eq(0x02_u8)
    command.call(pin, 0x2222_u64).command_status.as(Matter::InteractionModel::CommandStatusIB).status.status.should eq(0_u8)
    command.call("wrong", 0x1111_u64).command_status.as(Matter::InteractionModel::CommandStatusIB).status.status.should eq(0_u8)
    control.request_command_privilege.should be_nil
    read(control, Matter::Cluster::ContentControl::ATTR_REMAINING_SCREEN_TIME).should eq(13_u32)

    path = Matter::InteractionModel::CommandPath.new(1_u16,
      Matter::Cluster::ContentControl::CLUSTER_ID,
      Matter::Cluster::ContentControl::CMD_ADD_BONUS_TIME)
    no_pin = Matter::Cluster::ContentControl::AddBonusTimeRequest.new(nil, 1_u32)
    request = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Serializable.serialize_value(no_pin, nil))
    pase_result = Matter::Protocol::IMHandler.invoke_commands([request], clusters).first
    pase_result.command_status.as(Matter::InteractionModel::CommandStatusIB).status.cluster_status.should eq(0x02_u8)
    control.request_command_privilege.should be_nil
  end
end
