require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/im_handler"

private alias ValidationAcl = Matter::Cluster::AccessControl
private alias ValidationOnOff = Matter::Cluster::OnOff

private def validation_entry(restrictions : Array(ValidationAcl::AccessRestriction))
  ValidationAcl::AccessRestrictionEntry.new(1_u16, ValidationOnOff::CLUSTER_ID, restrictions)
end

describe "host Access Restriction List validation" do
  it "rejects reserved fabric, endpoint, cluster and element IDs" do
    acl = ValidationAcl.new(endpoint(0))
    valid = validation_entry([
      ValidationAcl::AccessRestriction.new(
        ValidationAcl::AccessRestrictionType::AttributeAccessForbidden,
        ValidationOnOff::ATTR_ON_OFF),
    ])
    {0_u8, UInt8::MAX}.each do |fabric_index|
      expect_raises(Matter::ConfigurationError) do
        acl.configure_access_restrictions(fabric_index, [valid])
      end
    end
    [
      ValidationAcl::AccessRestrictionEntry.new(UInt16::MAX, ValidationOnOff::CLUSTER_ID,
        valid.restrictions),
      ValidationAcl::AccessRestrictionEntry.new(1_u16, UInt32::MAX,
        valid.restrictions),
      validation_entry([
        ValidationAcl::AccessRestriction.new(
          ValidationAcl::AccessRestrictionType::AttributeAccessForbidden, UInt32::MAX),
      ]),
    ].each do |entry|
      expect_raises(Matter::ConfigurationError) do
        acl.configure_access_restrictions(1_u8, [entry])
      end
    end
  end

  it "rejects an empty restrictions list without replacing the fabric's existing policy" do
    acl = ValidationAcl.new(endpoint(0))
    existing = validation_entry([
      ValidationAcl::AccessRestriction.new(
        ValidationAcl::AccessRestrictionType::AttributeAccessForbidden,
        ValidationOnOff::ATTR_ON_OFF),
    ])
    acl.configure_access_restrictions(1_u8, [existing])

    expect_raises(Matter::ConfigurationError) do
      acl.configure_access_restrictions(1_u8, [
        validation_entry([
          ValidationAcl::AccessRestriction.new(
            ValidationAcl::AccessRestrictionType::CommandForbidden, nil),
        ]),
        validation_entry([] of ValidationAcl::AccessRestriction),
      ])
    end
    acl.attribute_read_restricted?(1_u8, 1_u16, ValidationOnOff::CLUSTER_ID,
      ValidationOnOff::ATTR_ON_OFF).should be_true
    acl.command_restricted?(1_u8, 1_u16, ValidationOnOff::CLUSTER_ID,
      ValidationOnOff::CMD_ON).should be_false
  end

  it "never restricts standard global attributes through a wildcard or explicit ID" do
    acl = ValidationAcl.new(endpoint(0))
    on_off = ValidationOnOff.new(endpoint(1))
    acl.acl << ValidationAcl::AccessControlEntry.new(
      ValidationAcl::AccessControlEntryPrivilege::Administer,
      ValidationAcl::AccessControlEntryAuthMode::CASE,
      [0x1234_u64], nil, 1_u8)
    clusters = {
      {0_u16, ValidationAcl::CLUSTER_ID}   => acl.as(Matter::Cluster::Base),
      {1_u16, ValidationOnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base),
    }
    [nil, Matter::Cluster::Base::GLOBAL_FEATURE_MAP].each do |restricted_id|
      acl.configure_access_restrictions(1_u8, [
        validation_entry([
          ValidationAcl::AccessRestriction.new(
            ValidationAcl::AccessRestrictionType::AttributeAccessForbidden, restricted_id),
        ]),
      ])
      {
        Matter::Cluster::Base::GLOBAL_GENERATED_COMMAND_LIST,
        Matter::Cluster::Base::GLOBAL_ACCEPTED_COMMAND_LIST,
        Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST,
        Matter::Cluster::Base::GLOBAL_FEATURE_MAP,
        Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION,
      }.each do |attribute_id|
        path = Matter::InteractionModel::AttributePath.new(
          endpoint: 1_u16, cluster: ValidationOnOff::CLUSTER_ID, attribute: attribute_id)
        report = Matter::Protocol::IMHandler.read_attributes([path], clusters,
          is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1234_u64]).first
        report.attribute_data.should_not be_nil
      end
      wildcard_path = Matter::InteractionModel::AttributePath.new(
        endpoint: 1_u16, cluster: ValidationOnOff::CLUSTER_ID, attribute: nil)
      reports = Matter::Protocol::IMHandler.read_attributes([wildcard_path], clusters,
        is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1234_u64])
      {
        Matter::Cluster::Base::GLOBAL_GENERATED_COMMAND_LIST,
        Matter::Cluster::Base::GLOBAL_ACCEPTED_COMMAND_LIST,
        Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST,
        Matter::Cluster::Base::GLOBAL_FEATURE_MAP,
        Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION,
      }.each do |attribute_id|
        reports.any? { |report| report.attribute_data.try(&.path.attribute) == attribute_id }
          .should be_true
      end
    end
  end
end
