require "../support/group_key_management_helpers"

private alias GKM = Matter::Cluster::GroupKeyManagement
private alias IMCode = Matter::InteractionModel::StatusCode

describe "GroupKeyManagement fabric-scoped wire commands" do
  commands = {
    GKM::CMD_KEY_SET_WRITE            => GKM::KeySetWriteRequest.new(Matter::Cluster.create_key_set(id: 2_u16)).to_tlv(nil),
    GKM::CMD_KEY_SET_READ             => GKM::KeySetReadRequest.new(1_u16).to_tlv(nil),
    GKM::CMD_KEY_SET_REMOVE           => GKM::KeySetRemoveRequest.new(1_u16).to_tlv(nil),
    GKM::CMD_KEY_SET_READ_ALL_INDICES => nil,
  } of UInt32 => TLV::Any?

  [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |invalid_fabric|
    commands.each do |command_id, fields|
      it "rejects command #{command_id} for reserved fabric #{invalid_fabric} before callbacks or state changes" do
        cluster = build(GKM, 0)
        cluster.handle_key_set_write(GKM::KeySetWriteRequest.new(Matter::Cluster.create_key_set(id: 1_u16)),
          Matter::Fabric::MIN_FABRIC_INDEX)
        callbacks = 0
        cluster.on_before_command = ->(_command : UInt32) { callbacks += 1; nil }
        cluster.on_before_direct_mutation = -> { callbacks += 1; nil }
        cluster.on_before_key_set_change = ->(_fabric : UInt8, _key_set : UInt16) { callbacks += 1; nil }
        cluster.on_version_changed = -> { callbacks += 1; nil }
        cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
          callbacks += 1
          nil
        end
        before_state = cluster.save_state
        before_version = cluster.data_version

        expect_status(cluster.invoke_command(command_id, fields,
          is_case_session: true, fabric_index: invalid_fabric), IMCode::UnsupportedAccess)

        cluster.save_state.should eq(before_state)
        cluster.data_version.should eq(before_version)
        callbacks.should eq(0)
      end
    end
  end

  [Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX].each do |valid_fabric|
    it "accepts all four commands for valid fabric #{valid_fabric}" do
      cluster = build(GKM, 0)
      key_set_id = 1_u16
      request = GKM::KeySetWriteRequest.new(Matter::Cluster.create_key_set(id: key_set_id))
      expect_status(invoke(cluster, GKM::CMD_KEY_SET_WRITE, request,
        is_case_session: true, fabric_index: valid_fabric), IMCode::Success)

      read = invoke(cluster, GKM::CMD_KEY_SET_READ, GKM::KeySetReadRequest.new(key_set_id),
        is_case_session: true, fabric_index: valid_fabric).as(Matter::Cluster::CommandResponse)
      GKM::KeySetReadResponse.from_tlv(read.response.as(TLV::Any)).group_key_set.group_key_set_id.should eq(key_set_id)
      indices = invoke(cluster, GKM::CMD_KEY_SET_READ_ALL_INDICES,
        is_case_session: true, fabric_index: valid_fabric).as(Matter::Cluster::CommandResponse)
      GKM::KeySetReadAllIndicesResponse.from_tlv(indices.response.as(TLV::Any)).group_key_set_i_ds.should eq([key_set_id])

      expect_status(invoke(cluster, GKM::CMD_KEY_SET_REMOVE, GKM::KeySetRemoveRequest.new(key_set_id),
        is_case_session: true, fabric_index: valid_fabric), IMCode::Success)
      cluster.handle_key_set_read_all_indices(valid_fabric).group_key_set_i_ds.should be_empty
    end
  end
end
