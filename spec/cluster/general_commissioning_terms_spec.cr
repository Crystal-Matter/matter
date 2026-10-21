require "../support/general_commissioning_helpers"

alias TCCluster = Matter::Cluster::GeneralCommissioning
alias TCErrorCode = Matter::Commissioning::ErrorCode

private def tc_cluster : Matter::Cluster::GeneralCommissioning
  Matter::Cluster::GeneralCommissioning.new(
    feature_map: Matter::Cluster::GeneralCommissioning::Feature::TermsAndConditions,
    tc_min_required_version: 2_u16,
    tc_required_acknowledgements: 0b0110_u16
  )
end

private def set_tc(cluster : Matter::Cluster::GeneralCommissioning, version : UInt16, acknowledgements : UInt16)
  request = Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(version, acknowledgements)
  result = cluster.invoke_command(
    Matter::Cluster::GeneralCommissioning::CMD_SET_TC_ACKNOWLEDGEMENTS,
    request.to_tlv(nil),
    is_case_session: true,
    fabric_index: 1_u8
  ).as(Matter::Cluster::CommandResponse)
  result.command_id.should eq(0x07_u32)
  Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsResponse.from_tlv(result.response.as(TLV::Any)).error_code
end

private def complete_tc(cluster : Matter::Cluster::GeneralCommissioning)
  cluster.commissioning_complete(1_u8, true).error_code
end

private def arm_tc(cluster : Matter::Cluster::GeneralCommissioning)
  cluster.arm_failsafe(
    Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64),
    1_u8, false
  ).error_code.should eq(TCErrorCode::OK)
end

describe Matter::Cluster::GeneralCommissioning do
  it "uses Matter 1.6 CommissioningError wire values" do
    TCErrorCode::RequiredTCNotAccepted.value.should eq(5_u8)
    TCErrorCode::TCAcknowledgementsNotReceived.value.should eq(6_u8)
    TCErrorCode::TCMinVersionNotMet.value.should eq(7_u8)
  end

  it "exposes T&C attributes and command only with feature bit 0" do
    disabled = TCCluster.new
    disabled.feature_map.should eq(TCCluster::Feature::None)
    disabled.get_attribute_metadata(TCCluster::ATTR_TC_ACCEPTED_VERSION).should be_nil
    disabled.get_command_metadata(TCCluster::CMD_SET_TC_ACKNOWLEDGEMENTS).should be_nil
    disabled.invoke_command(TCCluster::CMD_SET_TC_ACKNOWLEDGEMENTS,
      TCCluster::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16).to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedCommand)

    enabled = tc_cluster
    enabled.feature_map.should eq(TCCluster::Feature::TermsAndConditions)
    enabled.get_attribute_metadata(TCCluster::ATTR_TC_ACCEPTED_VERSION).should_not be_nil
    enabled.get_attribute_metadata(TCCluster::ATTR_TC_UPDATE_DEADLINE).should_not be_nil
    command = enabled.get_command_metadata(TCCluster::CMD_SET_TC_ACKNOWLEDGEMENTS)
    command.should_not be_nil
    command.as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    read(enabled, TCCluster::ATTR_TC_MIN_REQUIRED_VERSION).should eq(2_u16)
    read(enabled, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED).should be_true
    read(enabled, TCCluster::ATTR_TC_UPDATE_DEADLINE).should be_nil
  end

  it "round trips the SetTCAcknowledgements tag-zero and tag-one fields" do
    request = TCCluster::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16)
    parsed = TCCluster::SetTCAcknowledgementsRequest.from_tlv(request.to_tlv(nil))
    parsed.tc_version.should eq(2_u16)
    parsed.tc_user_response.should eq(0b0110_u16)
  end

  it "validates the minimum version and every required acknowledgement bit" do
    cluster = tc_cluster
    set_tc(cluster, 1_u16, 0b0110_u16).should eq(TCErrorCode::TCMinVersionNotMet)
    set_tc(cluster, 2_u16, 0b0010_u16).should eq(TCErrorCode::RequiredTCNotAccepted)
    read(cluster, TCCluster::ATTR_TC_ACCEPTED_VERSION).should eq(0_u16)
    set_tc(cluster, 3_u16, 0b1110_u16).should eq(TCErrorCode::OK)
    read(cluster, TCCluster::ATTR_TC_ACCEPTED_VERSION).should eq(3_u16)
    read(cluster, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS).should eq(0b1110_u16)
    read(cluster, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED).should be_false
  end

  it "distinguishes absent requirements from an explicit zero-version requirement" do
    no_requirements = TCCluster.new(feature_map: TCCluster::Feature::TermsAndConditions)
    no_requirements.tc_acknowledgements_required?.should be_false

    zero_requirement = TCCluster.new(feature_map: TCCluster::Feature::TermsAndConditions,
      tc_min_required_version: 0_u16, tc_required_acknowledgements: 0_u16)
    zero_requirement.tc_acknowledgements_required?.should be_true
    set_tc(zero_requirement, 0_u16, 0_u16).should eq(TCErrorCode::OK)
    zero_requirement.tc_acknowledgements_required?.should be_false
  end

  it "requires acknowledgement before CommissioningComplete" do
    cluster = tc_cluster
    arm_tc(cluster)
    complete_tc(cluster).should eq(TCErrorCode::TCAcknowledgementsNotReceived)
    set_tc(cluster, 2_u16, 0b0110_u16).should eq(TCErrorCode::OK)
    complete_tc(cluster).should eq(TCErrorCode::OK)
    cluster.failsafe_armed?.should be_false
  end

  it "reverts temporal acknowledgement on fail-safe expiry and restart" do
    cluster = tc_cluster
    arm_tc(cluster)
    set_tc(cluster, 2_u16, 0b0110_u16).should eq(TCErrorCode::OK)
    read(cluster, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED).should be_false
    document = cluster.save_state.as(Matter::Storage::Document)

    restarted = tc_cluster
    restarted.restore_state(document)
    read(restarted, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED).should be_true

    cluster.failsafe.expire
    read(cluster, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED).should be_true
    read(cluster, TCCluster::ATTR_TC_ACCEPTED_VERSION).should eq(0_u16)
  end

  it "persists accepted acknowledgement after successful completion" do
    cluster = tc_cluster
    arm_tc(cluster)
    set_tc(cluster, 2_u16, 0b0110_u16).should eq(TCErrorCode::OK)
    complete_tc(cluster).should eq(TCErrorCode::OK)

    restarted = tc_cluster
    restarted.restore_state(cluster.save_state.as(Matter::Storage::Document))
    read(restarted, TCCluster::ATTR_TC_ACCEPTED_VERSION).should eq(2_u16)
    read(restarted, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS).should eq(0b0110_u16)
    read(restarted, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED).should be_false
  end

  it "commits SetTCAcknowledgements immediately without an armed fail-safe" do
    cluster = tc_cluster
    set_tc(cluster, 2_u16, 0b0110_u16).should eq(TCErrorCode::OK)

    restarted = tc_cluster
    restarted.restore_state(cluster.save_state.as(Matter::Storage::Document))
    read(restarted, TCCluster::ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED).should be_false
  end

  it "requires a new acknowledgement when version or required bits increase" do
    accepted = tc_cluster
    set_tc(accepted, 2_u16, 0b0110_u16).should eq(TCErrorCode::OK)
    document = accepted.save_state.as(Matter::Storage::Document)

    newer_version = TCCluster.new(feature_map: TCCluster::Feature::TermsAndConditions,
      tc_min_required_version: 3_u16, tc_required_acknowledgements: 0b0110_u16)
    newer_version.restore_state(document)
    newer_version.tc_acknowledgements_required?.should be_true
    arm_tc(newer_version)
    complete_tc(newer_version).should eq(TCErrorCode::TCMinVersionNotMet)

    more_bits = TCCluster.new(feature_map: TCCluster::Feature::TermsAndConditions,
      tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b1110_u16)
    more_bits.restore_state(document)
    more_bits.tc_acknowledgements_required?.should be_true
    arm_tc(more_bits)
    complete_tc(more_bits).should eq(TCErrorCode::RequiredTCNotAccepted)
  end
end
