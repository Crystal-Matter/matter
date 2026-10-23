require "../spec_helper"

private alias AudioOutput = Matter::Cluster::AudioOutput
private alias IMCode = Matter::InteractionModel::StatusCode

private def audio_outputs
  [
    AudioOutput::OutputInfo.new(0_u8, AudioOutput::OutputType::Internal, "Speakers"),
    AudioOutput::OutputInfo.new(2_u8, AudioOutput::OutputType::Hdmi, "Soundbar"),
  ]
end

private def audio_request(cluster : AudioOutput, index : UInt8)
  invoke(cluster, AudioOutput::CMD_SELECT_OUTPUT, AudioOutput::SelectOutputRequest.new(index))
end

private def rename_request(cluster : AudioOutput, index : UInt8, name : String)
  invoke(cluster, AudioOutput::CMD_RENAME_OUTPUT, AudioOutput::RenameOutputRequest.new(index, name))
end

describe AudioOutput do
  it "declares revision-one attributes, commands, feature gating and privileges" do
    cluster = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8)
    cluster.cluster_id.id.should eq(0x050B_u32)
    cluster.cluster_revision.should eq(1_u16)
    attribute_ids(cluster).should contain(AudioOutput::ATTR_OUTPUT_LIST)
    attribute_ids(cluster).should contain(AudioOutput::ATTR_CURRENT_OUTPUT)
    accepted_command_ids(cluster).should eq([AudioOutput::CMD_SELECT_OUTPUT])
    cluster.get_command_metadata(AudioOutput::CMD_SELECT_OUTPUT).as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    expect_status(rename_request(cluster, 0_u8, "TV"), IMCode::UnsupportedCommand)

    named = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    named.feature_map.value.should eq(1_u32)
    accepted_command_ids(named).should eq([AudioOutput::CMD_SELECT_OUTPUT, AudioOutput::CMD_RENAME_OUTPUT])
    named.get_command_metadata(AudioOutput::CMD_RENAME_OUTPUT).as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    generated_command_ids(named).should be_empty
  end

  it "encodes output records and requests with canonical TLV tags" do
    output = audio_outputs.last
    output.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    AudioOutput::OutputInfo.from_tlv(output.to_tlv(nil)).should eq(output)
    AudioOutput::OutputInfo.new(2_u8, AudioOutput::OutputType::Hdmi, "Renamed", true)
      .to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    AudioOutput::SelectOutputRequest.new(2_u8).to_tlv(nil).as_structure.keys.should eq([0_u8])
    AudioOutput::RenameOutputRequest.new(2_u8, "Bar").to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
  end

  it "selects only declared outputs and lets the host decline a change" do
    cluster = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8)
    expect_status(audio_request(cluster, 2_u8), IMCode::InvalidInState)
    seen = [] of UInt8
    cluster.on_select_output do |output|
      seen << output.index
      output.index != 2_u8
    end
    seen.clear
    expect_status(audio_request(cluster, 9_u8), IMCode::NotFound)
    seen.should be_empty
    expect_status(audio_request(cluster, 2_u8), IMCode::InvalidInState)
    cluster.current_output.should eq(0_u8)
    cluster.on_select_output { |output| seen << output.index; true }
    seen.clear
    expect_success(audio_request(cluster, 2_u8))
    cluster.current_output.should eq(2_u8)
    read(cluster, AudioOutput::ATTR_CURRENT_OUTPUT).should eq(2_u8)
    seen.should eq([2_u8])
  end

  it "renames an output only with NameUpdates, enforcing 32-byte UTF-8 name limit" do
    cluster = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    expect_status(rename_request(cluster, 9_u8, "Unknown"), IMCode::NotFound)
    expect_status(rename_request(cluster, 2_u8, "é" * 17), IMCode::ConstraintError)
    cluster.output_list.last.name.should eq("Soundbar")
    expect_success(rename_request(cluster, 2_u8, ""))
    cluster.output_list.last.name.should eq("")
    expect_success(rename_request(cluster, 2_u8, "Living Room"))
    cluster.output_list.last.name.should eq("Living Room")
  end

  it "rejects invalid catalogue and selection at construction" do
    expect_raises(ArgumentError) { build(AudioOutput, output_list: [] of AudioOutput::OutputInfo, current_output: 0_u8) }
    expect_raises(ArgumentError) { build(AudioOutput, output_list: audio_outputs, current_output: 1_u8) }
    expect_raises(ArgumentError) { build(AudioOutput, output_list: audio_outputs + [audio_outputs.first], current_output: 0_u8) }
    expect_raises(ArgumentError) { AudioOutput::OutputInfo.new(3_u8, AudioOutput::OutputType::Other, "X" * 33) }
  end

  it "preserves index invariants when the host updates attributes" do
    cluster = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8)
    expect_raises(ArgumentError) { cluster.current_output = 9_u8 }
    expect_raises(ArgumentError) { cluster.output_list = [] of AudioOutput::OutputInfo }
    expect_raises(ArgumentError) { cluster.output_list = [audio_outputs.last] }
    cluster.current_output.should eq(0_u8)
    cluster.output_list.should eq(audio_outputs)
  end

  it "persists selected output and renamed names across restart" do
    cluster = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    cluster.on_select_output { |_output| true }
    expect_success(audio_request(cluster, 2_u8))
    expect_success(rename_request(cluster, 2_u8, "Amplifier"))
    saved = cluster.save_state.as(Matter::Storage::Document)
    restored = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    restored.restore_state(saved)
    restored.current_output.should eq(2_u8)
    restored.output_list.last.name.should eq("Amplifier")
  end

  it "reconciles saved names with the host's current physical catalogue" do
    cluster = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    cluster.on_select_output { |_output| true }
    expect_success(audio_request(cluster, 2_u8))
    expect_success(rename_request(cluster, 0_u8, "My TV"))
    saved = cluster.save_state.as(Matter::Storage::Document)

    changed = [AudioOutput::OutputInfo.new(0_u8, AudioOutput::OutputType::Bt, "Bluetooth")]
    restored = build(AudioOutput, output_list: changed, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    restored.restore_state(saved)
    restored.current_output.should eq(0_u8)
    restored.output_list.size.should eq(1)
    restored.output_list.first.output_type.should eq(AudioOutput::OutputType::Bt)
    restored.output_list.first.name.should eq("Bluetooth")
  end

  it "uses a new host default name unless the user renamed that output" do
    original = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    saved_default = original.save_state.as(Matter::Storage::Document)
    saved_default["output_list"].as(Array(Matter::Storage::Type)).first
      .as(Matter::Storage::Document).delete("user_renamed")
    changed = [AudioOutput::OutputInfo.new(0_u8, AudioOutput::OutputType::Internal, "New speakers"), audio_outputs.last]
    restored_default = build(AudioOutput, output_list: changed, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    restored_default.restore_state(saved_default)
    restored_default.output_list.first.name.should eq("New speakers")

    expect_success(rename_request(original, 0_u8, "My speakers"))
    saved_rename = original.save_state.as(Matter::Storage::Document)
    restored_rename = build(AudioOutput, output_list: changed, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    restored_rename.restore_state(saved_rename)
    restored_rename.output_list.first.name.should eq("My speakers")
  end

  it "reapplies the restored physical route when the host callback is registered" do
    source = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8)
    source.on_select_output { |_output| true }
    expect_success(audio_request(source, 2_u8))
    saved = source.save_state.as(Matter::Storage::Document)
    restored = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8)
    restored.restore_state(saved)

    activated = [] of UInt8
    restored.on_select_output do |output|
      activated << output.index
      true
    end
    activated.should eq([2_u8])
    restored.current_output.should eq(2_u8)

    expect_raises(Matter::ConfigurationError) do
      restored.on_select_output { |_output| false }
    end
  end

  it "rejects malformed command payloads without changing state" do
    cluster = build(AudioOutput, output_list: audio_outputs, current_output: 0_u8,
      feature_map: AudioOutput::Feature::NameUpdates)
    expect_status(invoke(cluster, AudioOutput::CMD_SELECT_OUTPUT), IMCode::InvalidCommand)
    expect_status(invoke(cluster, AudioOutput::CMD_RENAME_OUTPUT), IMCode::InvalidCommand)
    cluster.current_output.should eq(0_u8)
    cluster.output_list.last.name.should eq("Soundbar")
  end
end
