require "../support/group_key_management_helpers"

private alias GKM = Matter::Cluster::GroupKeyManagement
private alias IMCode = Matter::InteractionModel::StatusCode

private def build_map_writer(fabric_index : UInt8) : GKM
  cluster = build(GKM, 0)
  cluster.handle_key_set_write(GKM::KeySetWriteRequest.new(Matter::Cluster.create_key_set(id: 417_u16)), fabric_index)
  cluster.request_fabric_index = fabric_index
  cluster.request_is_case_session = true
  cluster
end

describe "GroupKeyManagement fabric-scoped GroupKeyMap writes" do
  [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |invalid_fabric|
    it "rejects a list replacement for invalid fabric #{invalid_fabric} before mutation callbacks" do
      cluster = build_map_writer(invalid_fabric)
      value = TLV::Serializable.serialize_value([GKM::GroupKeyMapStruct.new(257_u16, 417_u16, invalid_fabric)], nil)
      callbacks = 0
      cluster.on_before_direct_mutation = -> { callbacks += 1; nil }
      cluster.on_version_changed = -> { callbacks += 1; nil }
      before_state = cluster.save_state
      before_version = cluster.data_version

      cluster.write_group_key_map(value, invalid_fabric).status.should eq(IMCode::UnsupportedAccess)

      cluster.save_state.should eq(before_state)
      cluster.data_version.should eq(before_version)
      callbacks.should eq(0)
    end

    it "rejects a DSL GroupKeyMap write for invalid fabric #{invalid_fabric} before hooks" do
      cluster = build(GKM, 0)
      cluster.request_fabric_index = invalid_fabric
      callbacks = 0
      cluster.on_before_write = ->(_attribute : UInt32) { callbacks += 1; nil }
      cluster.on_before_direct_mutation = -> { callbacks += 1; nil }
      cluster.on_version_changed = -> { callbacks += 1; nil }
      before_state = cluster.save_state
      before_version = cluster.data_version
      empty_map = TLV::Serializable.serialize_value([] of GKM::GroupKeyMapStruct, nil)

      cluster.write_attribute(GKM::ATTR_GROUP_KEY_MAP, empty_map).status.should eq(IMCode::UnsupportedAccess)

      cluster.save_state.should eq(before_state)
      cluster.data_version.should eq(before_version)
      callbacks.should eq(0)
    end
  end

  [true, false].each do |replacement|
    it "rejects an explicit foreign FabricIndex on #{replacement ? "replacement" : "append"}" do
      cluster = build_map_writer(Matter::Fabric::MIN_FABRIC_INDEX)
      foreign = GKM::GroupKeyMapStruct.new(257_u16, 417_u16, 2_u8)
      value = replacement ? TLV::Serializable.serialize_value([foreign], nil) : foreign.to_tlv(nil)
      callbacks = 0
      cluster.on_before_direct_mutation = -> { callbacks += 1; nil }
      cluster.on_version_changed = -> { callbacks += 1; nil }
      before_state = cluster.save_state
      before_version = cluster.data_version

      cluster.write_group_key_map(value, Matter::Fabric::MIN_FABRIC_INDEX).status.should eq(IMCode::UnsupportedAccess)

      cluster.save_state.should eq(before_state)
      cluster.data_version.should eq(before_version)
      callbacks.should eq(0)
    end
  end

  [Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX].each do |valid_fabric|
    it "accepts matching and omitted FabricIndex forms for fabric #{valid_fabric}" do
      cluster = build_map_writer(valid_fabric)
      matching = GKM::GroupKeyMapStruct.new(257_u16, 417_u16, valid_fabric)
      cluster.write_group_key_map(TLV::Serializable.serialize_value([matching], nil), valid_fabric).status.should eq(IMCode::Success)
      omitted = TLV::Any.new({
        1_u8 => TLV::Any.new(258_u16, 1_u8),
        2_u8 => TLV::Any.new(417_u16, 2_u8),
      } of TLV::TagId => TLV::Any)
      cluster.write_group_key_map(omitted, valid_fabric).status.should eq(IMCode::Success)
      cluster.group_key_map(valid_fabric).map(&.group_id).should eq([257_u16, 258_u16])
    end
  end
end
