require "../support/group_key_management_helpers"

private alias AdoptionGKM = Matter::Cluster::GroupKeyManagement
private alias AdoptionStatus = Matter::InteractionModel::StatusCode

private def adoption_writer : AdoptionGKM
  AdoptionGKM.new(endpoint(0), feature_map: AdoptionGKM::Feature::Groupcast)
end

private def adoption_value(adopted : Bool = true) : TLV::Any
  TLV::Serializable.serialize_value([AdoptionGKM::GroupcastAdoptionStruct.new(adopted)], nil)
end

describe "GroupKeyManagement GroupcastAdoption fabric writes" do
  [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |invalid_fabric|
    it "rejects reserved fabric #{invalid_fabric} before write hooks or persistence changes" do
      cluster = adoption_writer
      cluster.request_is_case_session = true
      cluster.request_fabric_index = invalid_fabric
      callbacks = 0
      cluster.on_before_write = ->(_attribute : UInt32) { callbacks += 1; nil }
      cluster.on_before_direct_mutation = -> { callbacks += 1; nil }
      cluster.on_version_changed = -> { callbacks += 1; nil }
      before_state = cluster.save_state
      before_version = cluster.data_version

      cluster.write_attribute(AdoptionGKM::ATTR_GROUPCAST_ADOPTION, adoption_value).status.should eq(AdoptionStatus::UnsupportedAccess)

      cluster.save_state.should eq(before_state)
      cluster.data_version.should eq(before_version)
      callbacks.should eq(0)
      cluster.groupcast_adoption(invalid_fabric).should be_empty
    end
  end

  it "rejects a non-CASE write even when a fabric index is supplied" do
    cluster = adoption_writer
    cluster.request_fabric_index = Matter::Fabric::MIN_FABRIC_INDEX
    callbacks = 0
    cluster.on_before_write = ->(_attribute : UInt32) { callbacks += 1; nil }
    cluster.on_before_direct_mutation = -> { callbacks += 1; nil }
    cluster.on_version_changed = -> { callbacks += 1; nil }
    before_state = cluster.save_state
    before_version = cluster.data_version

    cluster.write_attribute(AdoptionGKM::ATTR_GROUPCAST_ADOPTION, adoption_value).status.should eq(AdoptionStatus::UnsupportedAccess)

    cluster.save_state.should eq(before_state)
    cluster.data_version.should eq(before_version)
    callbacks.should eq(0)
  end

  it "persists adoption only for the authorized fabric at both valid index bounds" do
    cluster = adoption_writer
    [Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX].each do |fabric|
      cluster.request_is_case_session = true
      cluster.request_fabric_index = fabric
      cluster.write_attribute(AdoptionGKM::ATTR_GROUPCAST_ADOPTION, adoption_value).status.should eq(AdoptionStatus::Success)
    end

    restored = adoption_writer
    restored.restore_state(cluster.save_state || fail("Group Key Management state missing"))
    restored.groupcast_adoption(Matter::Fabric::MIN_FABRIC_INDEX).map(&.fabric_index).should eq([Matter::Fabric::MIN_FABRIC_INDEX])
    restored.groupcast_adoption(Matter::Fabric::MAX_FABRIC_INDEX).map(&.fabric_index).should eq([Matter::Fabric::MAX_FABRIC_INDEX])
  end
end
