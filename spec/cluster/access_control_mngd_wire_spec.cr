require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/im_handler"

private alias MngdAcl = Matter::Cluster::AccessControl
private alias MngdOnOff = Matter::Cluster::OnOff
private MNGD_SUBJECT = 0x1234_u64

private def mngd_entry
  MngdAcl::AccessRestrictionEntry.new(1_u16, MngdOnOff::CLUSTER_ID, [
    MngdAcl::AccessRestriction.new(MngdAcl::AccessRestrictionType::AttributeAccessForbidden,
      MngdOnOff::ATTR_ON_OFF),
  ])
end

private def mngd_read(acl : MngdAcl, fabric : UInt8, attribute : UInt32)
  path = Matter::InteractionModel::AttributePath.new(endpoint: 0_u16,
    cluster: MngdAcl::CLUSTER_ID, attribute: attribute)
  Matter::Protocol::IMHandler.read_attributes([path],
    { {0_u16, MngdAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base) },
    is_case_session: true, fabric_index: fabric, peer_subject_ids: [MNGD_SUBJECT]).first
end

private def mngd_invoke(acl : MngdAcl, fabric : UInt8, request_data : TLV::Any)
  path = Matter::InteractionModel::CommandPath.new(0_u16, MngdAcl::CLUSTER_ID,
    MngdAcl::CMD_REVIEW_FABRIC_RESTRICTIONS)
  request = Matter::InteractionModel::CommandDataIBTlv.new(path, request_data)
  Matter::Protocol::IMHandler.invoke_commands([request],
    { {0_u16, MngdAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base) },
    is_case_session: true, fabric_index: fabric, peer_subject_ids: [MNGD_SUBJECT]).first
end

describe "Access Control MNGD wire schema" do
  it "keeps MNGD absent from the default feature map and gated metadata" do
    acl = MngdAcl.new(endpoint(0))
    acl.feature_map.value.should eq(MngdAcl::Feature::Extension.value)
    acl.get_attribute_metadata(MngdAcl::ATTR_COMMISSIONING_ARL).should be_nil
    acl.get_attribute_metadata(MngdAcl::ATTR_ARL).should be_nil
    acl.get_command_metadata(MngdAcl::CMD_REVIEW_FABRIC_RESTRICTIONS).should be_nil
    acl.get_event_metadata(MngdAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE).should be_nil
    attributes = TLV::Serializable.deserialize_value(
      acl.read_attribute(Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST).as(TLV::Any), Array(UInt32))
    attributes.should_not contain(MngdAcl::ATTR_COMMISSIONING_ARL)
    attributes.should_not contain(MngdAcl::ATTR_ARL)
  end

  it "encodes nullable restriction IDs and the fabric index with Matter 1.6 TLV tags" do
    entry = MngdAcl::AccessRestrictionEntry.new(1_u16, MngdOnOff::CLUSTER_ID, [
      MngdAcl::AccessRestriction.new(MngdAcl::AccessRestrictionType::CommandForbidden, nil),
    ], 2_u8)
    decoded = MngdAcl::AccessRestrictionEntry.from_tlv(entry.to_tlv(nil))
    decoded.endpoint.should eq(1_u16)
    decoded.cluster.should eq(MngdOnOff::CLUSTER_ID)
    decoded.restrictions.first.id.should be_nil
    decoded.fabric_index.should eq(2_u8)
    request = MngdAcl::ReviewFabricRestrictionsRequest.new([
      MngdAcl::CommissioningAccessRestrictionEntry.new(1_u16, MngdOnOff::CLUSTER_ID,
        entry.restrictions),
    ])
    MngdAcl::ReviewFabricRestrictionsRequest.from_tlv(request.to_tlv(nil)).arl.size.should eq(1)
    response = MngdAcl::ReviewFabricRestrictionsResponse.new(42_u64)
    MngdAcl::ReviewFabricRestrictionsResponse.from_tlv(response.to_tlv(nil)).token.should eq(42_u64)
    acl = MngdAcl.new(endpoint(0))
    expect_raises(Matter::ConfigurationError) do
      acl.configure_access_restrictions(1_u8, [entry])
    end
  end

  it "exposes read-only View attributes, fabric-scoped ARL and Administer-only review" do
    acl = MngdAcl.new(endpoint(0), MngdAcl::Feature::ManagedDevice)
    acl.configure_commissioning_access_restrictions([
      MngdAcl::CommissioningAccessRestrictionEntry.new(1_u16, MngdOnOff::CLUSTER_ID,
        mngd_entry.restrictions),
    ])
    expect_raises(Matter::ConfigurationError) do
      acl.configure_commissioning_access_restrictions([] of MngdAcl::CommissioningAccessRestrictionEntry)
    end
    acl.configure_access_restrictions(1_u8, [mngd_entry])
    [1_u8, 2_u8].each do |fabric|
      acl.acl << MngdAcl::AccessControlEntry.new(
        MngdAcl::AccessControlEntryPrivilege::View,
        MngdAcl::AccessControlEntryAuthMode::CASE,
        [MNGD_SUBJECT], nil, fabric)
    end
    acl.get_attribute_metadata(MngdAcl::ATTR_COMMISSIONING_ARL).try(&.access)
      .should eq(Matter::InteractionModel::EntryPrivilege::View)
    acl.get_attribute_metadata(MngdAcl::ATTR_COMMISSIONING_ARL).try(&.fixed?).should be_true
    acl.get_attribute_metadata(MngdAcl::ATTR_COMMISSIONING_ARL).try(&.writable?).should be_false
    acl.get_attribute_metadata(MngdAcl::ATTR_ARL).try(&.fabric_scoped?).should be_true
    acl.get_attribute_metadata(MngdAcl::ATTR_ARL).try(&.writable?).should be_false
    acl.get_command_metadata(MngdAcl::CMD_REVIEW_FABRIC_RESTRICTIONS).try(&.access)
      .should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    acl.get_command_metadata(MngdAcl::CMD_REVIEW_FABRIC_RESTRICTIONS).try(&.response_id)
      .should eq(MngdAcl::CMD_REVIEW_FABRIC_RESTRICTIONS_RESPONSE)
    acl.get_event_metadata(MngdAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE).try(&.access)
      .should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    attributes = TLV::Serializable.deserialize_value(
      acl.read_attribute(Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST).as(TLV::Any), Array(UInt32))
    attributes.should contain(MngdAcl::ATTR_COMMISSIONING_ARL)
    attributes.should contain(MngdAcl::ATTR_ARL)

    carl = mngd_read(acl, 2_u8, MngdAcl::ATTR_COMMISSIONING_ARL)
    carl_data = carl.attribute_data || fail("Missing CommissioningARL data")
    TLV::Serializable.deserialize_value(carl_data.data,
      Array(MngdAcl::CommissioningAccessRestrictionEntry)).size.should eq(1)
    own = mngd_read(acl, 1_u8, MngdAcl::ATTR_ARL)
    own_data = own.attribute_data || fail("Missing ARL data")
    entries = TLV::Serializable.deserialize_value(own_data.data,
      Array(MngdAcl::AccessRestrictionEntry))
    entries.map(&.fabric_index).should eq([1_u8])
    other = mngd_read(acl, 2_u8, MngdAcl::ATTR_ARL)
    other_data = other.attribute_data || fail("Missing other-fabric ARL data")
    TLV::Serializable.deserialize_value(other_data.data,
      Array(MngdAcl::AccessRestrictionEntry)).should be_empty

    request = MngdAcl::ReviewFabricRestrictionsRequest.new([] of MngdAcl::CommissioningAccessRestrictionEntry)
    denied = mngd_invoke(acl, 1_u8, request.to_tlv(nil))
    denied.command_status.try(&.status.status).should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
  end

  it "rejects malformed or empty nested restrictions without invoking the host" do
    acl = MngdAcl.new(endpoint(0), MngdAcl::Feature::ManagedDevice)
    acl.acl << MngdAcl::AccessControlEntry.new(
      MngdAcl::AccessControlEntryPrivilege::Administer,
      MngdAcl::AccessControlEntryAuthMode::CASE,
      [MNGD_SUBJECT], nil, 1_u8)
    requested = [] of MngdAcl::RestrictionReviewRequest
    acl.on_restriction_review_requested { |request| requested << request }
    acl.on_restriction_review_updated { |_, _| }

    malformed = TLV::Serializable.serialize_value(7_u8, nil)
    mngd_invoke(acl, 1_u8, malformed).command_status.try(&.status.status)
      .should eq(Matter::InteractionModel::StatusCode::InvalidCommand.value)
    invalid = MngdAcl::ReviewFabricRestrictionsRequest.new([
      MngdAcl::CommissioningAccessRestrictionEntry.new(1_u16, MngdOnOff::CLUSTER_ID,
        [] of MngdAcl::AccessRestriction),
    ])
    mngd_invoke(acl, 1_u8, invalid.to_tlv(nil)).command_status.try(&.status.status)
      .should eq(Matter::InteractionModel::StatusCode::ConstraintError.value)
    requested.should be_empty
  end

  it "returns a review token and emits a fabric-sensitive correlated update" do
    acl = MngdAcl.new(endpoint(0), MngdAcl::Feature::ManagedDevice)
    acl.acl << MngdAcl::AccessControlEntry.new(
      MngdAcl::AccessControlEntryPrivilege::Administer,
      MngdAcl::AccessControlEntryAuthMode::CASE,
      [MNGD_SUBJECT], nil, 1_u8)
    requests = [] of MngdAcl::RestrictionReviewRequest
    events = [] of Tuple(UInt32, UInt8?, TLV::Any)
    acl.on_restriction_review_requested { |request| requests << request }
    acl.on_restriction_review_updated { |_, _| }
    acl.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, payload : TLV::Any, fabric : UInt8?) { events << {id, fabric, payload}; nil }

    request = MngdAcl::ReviewFabricRestrictionsRequest.new([] of MngdAcl::CommissioningAccessRestrictionEntry)
    response = mngd_invoke(acl, 1_u8, request.to_tlv(nil))
    fields = response.command_data.try(&.command_fields) || fail("Missing review response")
    token = MngdAcl::ReviewFabricRestrictionsResponse.from_tlv(fields).token
    requests.map(&.token).should eq([token])
    acl.complete_restriction_review(1_u8, token).should be_true
    events.map(&.[0]).should eq([MngdAcl::EVENT_FABRIC_RESTRICTION_REVIEW_UPDATE])
    events.map(&.[1]).should eq([1_u8])
    MngdAcl::FabricRestrictionReviewUpdate.from_tlv(events.first[2]).token.should eq(token)
  end
end
