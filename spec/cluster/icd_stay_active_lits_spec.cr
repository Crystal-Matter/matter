require "../spec_helper"
require "../../src/matter/cluster/icd_management"

private alias LitsIcd = Matter::Cluster::IcdManagement

describe "ICD StayActiveRequest conformance" do
  it "advertises and handles StayActiveRequest only with LITS" do
    sit = LitsIcd.new
    sit.get_command_metadata(LitsIcd::CMD_STAY_ACTIVE_REQUEST).should be_nil
    accepted_command_ids(sit).should_not contain(LitsIcd::CMD_STAY_ACTIVE_REQUEST)
    sit.invoke_command(LitsIcd::CMD_STAY_ACTIVE_REQUEST,
      LitsIcd::StayActiveRequest.new(5_000_u32).to_tlv(nil), is_case_session: true)
      .as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedCommand)

    long_idle = LitsIcd.new(feature_map: LitsIcd::Feature::CheckInProtocolSupport |
                                        LitsIcd::Feature::UserActiveModeTrigger |
                                        LitsIcd::Feature::LongIdleTimeSupport,
      idle_mode_duration: 60_u32, active_mode_duration: 3_000_u32,
      active_mode_threshold: 5_000_u16)
    long_idle.get_command_metadata(LitsIcd::CMD_STAY_ACTIVE_REQUEST).should_not be_nil
    accepted_command_ids(long_idle).should contain(LitsIcd::CMD_STAY_ACTIVE_REQUEST)
    response = long_idle.invoke_command(LitsIcd::CMD_STAY_ACTIVE_REQUEST,
      LitsIcd::StayActiveRequest.new(5_000_u32).to_tlv(nil), is_case_session: true)
      .as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(LitsIcd::CMD_STAY_ACTIVE_RESPONSE)
  end
end
