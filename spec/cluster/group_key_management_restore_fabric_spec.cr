require "../support/group_key_management_helpers"

private alias RestoreGKM = Matter::Cluster::GroupKeyManagement

private def restore_source : RestoreGKM
  cluster = RestoreGKM.new(endpoint(0), feature_map: RestoreGKM::Feature::Groupcast)
  [Matter::DataType::NO_FABRIC, Matter::Fabric::MIN_FABRIC_INDEX,
   Matter::Fabric::MAX_FABRIC_INDEX, UInt8::MAX].each do |fabric|
    cluster.handle_key_set_write(
      RestoreGKM::KeySetWriteRequest.new(Matter::Cluster.create_key_set(id: 417_u16)), fabric)
    cluster.add_group_key_map(257_u16, 417_u16, fabric)
    cluster.add_group(257_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric)
    cluster.replace_groupcast_membership(258_u16, [2_u16], 417_u16, fabric)
    cluster.request_fabric_index = fabric
    cluster.groupcast_adoption = [RestoreGKM::GroupcastAdoptionStruct.new(true)]
  end
  cluster
end

describe "GroupKeyManagement persisted fabric recovery" do
  it "drops reserved-index key, map, source-table, and adoption rows while retaining valid fabrics" do
    source = restore_source
    prior_version = source.data_version
    restored = RestoreGKM.new(endpoint(0), feature_map: RestoreGKM::Feature::Groupcast)
    dirty = 0
    restored.on_version_changed = -> { dirty += 1; nil }

    restored.restore_state(source.save_state || fail("Group Key Management state missing"))

    restored.fabric_indices.sort.should eq([Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX])
    [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |fabric|
      restored.get_key_set(417_u16, fabric).should be_nil
      restored.operational_group_key_map(fabric).should be_empty
      restored.operational_group_table(fabric).should be_empty
      restored.operational_legacy_group_table(fabric).should be_empty
      restored.groupcast_adoption(fabric).should be_empty
    end
    [Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX].each do |fabric|
      restored.get_key_set(417_u16, fabric).should_not be_nil
      restored.operational_group_key_map(fabric).size.should eq(2)
      restored.operational_group_table(fabric).size.should eq(2)
      restored.operational_legacy_group_table(fabric).size.should eq(1)
      restored.groupcast_adoption(fabric).size.should eq(1)
    end
    restored.data_version.should eq(prior_version &+ 1_u32)
    dirty.should eq(1)

    saved = restored.save_state || fail("sanitized state missing")
    ["group_key_map", "group_table", "legacy_group_table", "groupcast_group_table", "groupcast_adoption"].each do |field|
      rows = saved[field].as(Array(Matter::Storage::Type))
      rows.each do |row|
        fabric = row.as(Matter::Storage::Document)["fabric_index"].as(Int64)
        (Matter::Fabric::MIN_FABRIC_INDEX.to_i64..Matter::Fabric::MAX_FABRIC_INDEX.to_i64).includes?(fabric).should be_true
      end
    end
    recovered_again = RestoreGKM.new(endpoint(0), feature_map: RestoreGKM::Feature::Groupcast)
    recovered_again.restore_state(saved)
    recovered_again.data_version.should eq(restored.data_version)
    recovered_again.fabric_indices.sort.should eq(restored.fabric_indices.sort)
  end

  it "discards a map row that references a key set stored only on another fabric" do
    source = RestoreGKM.new(endpoint(0))
    source.handle_key_set_write(
      RestoreGKM::KeySetWriteRequest.new(Matter::Cluster.create_key_set(id: 417_u16)),
      Matter::Fabric::MAX_FABRIC_INDEX)
    source.request_fabric_index = Matter::Fabric::MIN_FABRIC_INDEX
    source.group_key_map = [RestoreGKM::GroupKeyMapStruct.new(257_u16, 417_u16)]
    prior_version = source.data_version

    restored = RestoreGKM.new(endpoint(0))
    restored.restore_state(source.save_state || fail("Group Key Management state missing"))

    restored.get_key_set(417_u16, Matter::Fabric::MAX_FABRIC_INDEX).should_not be_nil
    restored.operational_group_key_map(Matter::Fabric::MIN_FABRIC_INDEX).should be_empty
    restored.data_version.should eq(prior_version &+ 1_u32)
  end
end
