require "../spec_helper"

private alias MediaInput = Matter::Cluster::MediaInput
private alias IMCode = Matter::InteractionModel::StatusCode

private def hdmi_input(index : UInt8 = 1_u8, name : String = "HDMI 1") : MediaInput::InputInfo
  MediaInput::InputInfo.new(index, MediaInput::InputType::Hdmi, name, "Living room source")
end

private def media_input : MediaInput
  build(MediaInput, input_list: [hdmi_input, hdmi_input(2_u8, "HDMI 2")], current_input: 1_u8)
end

describe MediaInput do
  it "declares the revision-one schema and feature-gated RenameInput" do
    cluster = media_input
    cluster.cluster_id.id.should eq(0x0507_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.feature_map.value.should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([MediaInput::ATTR_INPUT_LIST, MediaInput::ATTR_CURRENT_INPUT])
    accepted_command_ids(cluster).should eq([
      MediaInput::CMD_SELECT_INPUT, MediaInput::CMD_SHOW_INPUT_STATUS, MediaInput::CMD_HIDE_INPUT_STATUS,
    ])
    cluster.events.should be_empty
    cluster.get_command_metadata(MediaInput::CMD_SELECT_INPUT).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    cluster.get_command_metadata(MediaInput::CMD_SHOW_INPUT_STATUS).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    cluster.get_command_metadata(MediaInput::CMD_HIDE_INPUT_STATUS).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)

    named = build(MediaInput, feature_map: MediaInput::Feature::NameUpdates, input_list: [hdmi_input])
    accepted_command_ids(named).should contain(MediaInput::CMD_RENAME_INPUT)
    named.get_command_metadata(MediaInput::CMD_RENAME_INPUT).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
  end

  it "round-trips typed InputInfo and request structures" do
    info = hdmi_input
    info.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    MediaInput::InputInfo.from_tlv(info.to_tlv(nil)).should eq(info)
    read_tlv(media_input, MediaInput::ATTR_INPUT_LIST).as_list.size.should eq(2)
    read(media_input, MediaInput::ATTR_CURRENT_INPUT).should eq(1_u8)
    MediaInput::SelectInputRequest.from_tlv(MediaInput::SelectInputRequest.new(2_u8).to_tlv(nil)).index.should eq(2_u8)
    MediaInput::RenameInputRequest.from_tlv(MediaInput::RenameInputRequest.new(2_u8, "Console").to_tlv(nil)).name.should eq("Console")
  end

  it "rejects empty, duplicate and unselected input catalogs" do
    expect_raises(ArgumentError) { build(MediaInput, input_list: [] of MediaInput::InputInfo) }
    expect_raises(ArgumentError) { build(MediaInput, input_list: [hdmi_input, hdmi_input]) }
    expect_raises(ArgumentError) { build(MediaInput, input_list: [hdmi_input], current_input: 2_u8) }
    cluster = media_input
    expect_raises(ArgumentError) { cluster.current_input = 3_u8 }
    expect_raises(ArgumentError) { cluster.input_list = [hdmi_input(3_u8)] }
    cluster.current_input.should eq(1_u8)
    cluster.input_list.size.should eq(2)
  end

  it "selects known inputs only after host acceptance" do
    cluster = media_input
    expect_status(invoke(cluster, MediaInput::CMD_SELECT_INPUT, MediaInput::SelectInputRequest.new(2_u8)), IMCode::InvalidInState)
    read(cluster, MediaInput::ATTR_CURRENT_INPUT).should eq(1_u8)
    cluster.on_select_input { |index| index == 2_u8 ? Matter::InteractionModel::Status.success : Matter::InteractionModel::Status.invalid_in_state }
    expect_status(invoke(cluster, MediaInput::CMD_SELECT_INPUT, MediaInput::SelectInputRequest.new(2_u8)), IMCode::Success)
    read(cluster, MediaInput::ATTR_CURRENT_INPUT).should eq(2_u8)
    cluster.on_select_input { |_index| Matter::InteractionModel::Status.invalid_in_state }
    expect_status(invoke(cluster, MediaInput::CMD_SELECT_INPUT, MediaInput::SelectInputRequest.new(1_u8)), IMCode::InvalidInState)
    expect_status(invoke(cluster, MediaInput::CMD_SELECT_INPUT, MediaInput::SelectInputRequest.new(3_u8)), IMCode::NotFound)
    read(cluster, MediaInput::ATTR_CURRENT_INPUT).should eq(2_u8)
    expect_status(invoke(cluster, MediaInput::CMD_SELECT_INPUT), IMCode::InvalidCommand)
  end

  it "delegates show and hide to the host" do
    cluster = media_input
    expect_status(invoke(cluster, MediaInput::CMD_SHOW_INPUT_STATUS), IMCode::InvalidInState)
    expect_status(invoke(cluster, MediaInput::CMD_HIDE_INPUT_STATUS), IMCode::InvalidInState)
    seen = [] of Bool
    cluster.on_input_status { |visible| seen << visible; Matter::InteractionModel::Status.success }
    expect_status(invoke(cluster, MediaInput::CMD_SHOW_INPUT_STATUS), IMCode::Success)
    expect_status(invoke(cluster, MediaInput::CMD_HIDE_INPUT_STATUS), IMCode::Success)
    seen.should eq([true, false])
  end

  it "renames only known inputs when NameUpdates is advertised" do
    absent = media_input
    expect_status(invoke(absent, MediaInput::CMD_RENAME_INPUT, MediaInput::RenameInputRequest.new(1_u8, "TV")), IMCode::UnsupportedCommand)
    cluster = build(MediaInput, feature_map: MediaInput::Feature::NameUpdates, input_list: [hdmi_input])
    expect_status(invoke(cluster, MediaInput::CMD_RENAME_INPUT, MediaInput::RenameInputRequest.new(2_u8, "TV")), IMCode::NotFound)
    expect_status(invoke(cluster, MediaInput::CMD_RENAME_INPUT, MediaInput::RenameInputRequest.new(1_u8, "TV")), IMCode::Success)
    cluster.input_list.first.name.should eq("TV")
    expect_status(invoke(cluster, MediaInput::CMD_RENAME_INPUT), IMCode::InvalidCommand)
  end

  it "persists selected input and names through the typed storage record" do
    cluster = build(MediaInput, feature_map: MediaInput::Feature::NameUpdates,
      input_list: [hdmi_input, hdmi_input(2_u8, "HDMI 2")])
    cluster.on_select_input { |_index| Matter::InteractionModel::Status.success }
    expect_status(invoke(cluster, MediaInput::CMD_SELECT_INPUT, MediaInput::SelectInputRequest.new(2_u8)), IMCode::Success)
    expect_status(invoke(cluster, MediaInput::CMD_RENAME_INPUT, MediaInput::RenameInputRequest.new(2_u8, "Media Box")), IMCode::Success)
    saved = cluster.save_state.as(Matter::Storage::Document)

    restored = build(MediaInput, feature_map: MediaInput::Feature::NameUpdates,
      input_list: [hdmi_input, hdmi_input(2_u8, "HDMI 2")])
    restored.restore_state(saved)
    restored.current_input.should eq(2_u8)
    restored.input_list.last.name.should eq("Media Box")
  end
end
