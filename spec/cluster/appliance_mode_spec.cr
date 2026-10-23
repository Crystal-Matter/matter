require "../spec_helper"

private alias ModeBase = Matter::Cluster::ModeBase
private alias DishwasherMode = Matter::Cluster::DishwasherMode
private alias LaundryWasherMode = Matter::Cluster::LaundryWasherMode

private def dishwasher_options : Array(ModeBase::Option)
  [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Heavy", 1_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Heavy.value)]),
  ]
end

private def laundry_options : Array(ModeBase::Option)
  [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Delicate", 1_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Delicate.value)]),
  ]
end

describe "Matter 1.6 appliance Mode Base derivations" do
  it "advertises revision 3 mandatory attributes and a response command without disallowed members" do
    dishwasher = build(DishwasherMode, supported_modes: dishwasher_options, current_mode: 0_u8)
    laundry = build(LaundryWasherMode, supported_modes: laundry_options, current_mode: 0_u8)

    {dishwasher, laundry}.each do |cluster|
      cluster.cluster_revision.should eq(3_u16)
      cluster.read_attribute(Matter::Cluster::Base::GLOBAL_FEATURE_MAP, nil).as(TLV::Any).value.should eq(0_u32)
      cluster.attributes.map(&.id.id).should contain(0_u32)
      cluster.attributes.map(&.id.id).should contain(1_u32)
      cluster.attributes.map(&.id.id).should_not contain(2_u32)
      cluster.attributes.map(&.id.id).should_not contain(3_u32)
      cluster.commands.map(&.id.id).should contain(0_u32)
    end
    DishwasherMode::COMMANDS_BY_ID[DishwasherMode::CMD_CHANGE_TO_MODE].response_id.should eq(1_u32)
    LaundryWasherMode::COMMANDS_BY_ID[LaundryWasherMode::CMD_CHANGE_TO_MODE].response_id.should eq(1_u32)
  end

  it "validates fixed modes and never advertises a set with no standard tag" do
    expect_raises(ArgumentError) { build(DishwasherMode, supported_modes: dishwasher_options.first(1), current_mode: 0_u8) }
    expect_raises(ArgumentError) { build(LaundryWasherMode, supported_modes: laundry_options, current_mode: 7_u8) }
    vendor_only = [ModeBase::Tag.new(0x8000_u16, 0xFFF1_u16)]
    invalid = [ModeBase::Option.new("Vendor", 0_u8, vendor_only), laundry_options.last]
    expect_raises(ArgumentError) { build(LaundryWasherMode, supported_modes: invalid, current_mode: 0_u8) }
  end

  it "rejects duplicate labels and equivalent mode-tag sets" do
    duplicate_labels = [
      ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Normal.value)]),
      ModeBase::Option.new("Normal", 1_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Heavy.value)]),
    ]
    expect_raises(ArgumentError) { build(DishwasherMode, supported_modes: duplicate_labels, current_mode: 0_u8) }

    normal = ModeBase::Tag.new(DishwasherMode::ModeTag::Normal.value)
    heavy = ModeBase::Tag.new(DishwasherMode::ModeTag::Heavy.value)
    duplicate_tag_sets = [
      ModeBase::Option.new("First", 0_u8, [normal, heavy]),
      ModeBase::Option.new("Second", 1_u8, [heavy, normal]),
    ]
    expect_raises(ArgumentError) { build(DishwasherMode, supported_modes: duplicate_tag_sets, current_mode: 0_u8) }
  end

  it "requires manufacturer mode tags to use their reserved value range" do
    invalid_tag = ModeBase::Tag.new(DishwasherMode::ModeTag::Heavy.value, 0xFFF1_u16)
    options = [
      dishwasher_options.first,
      ModeBase::Option.new("Vendor Heavy", 1_u8, [ModeBase::Tag.new(0_u16), invalid_tag]),
    ]
    expect_raises(ArgumentError) { build(DishwasherMode, supported_modes: options, current_mode: 0_u8) }
  end

  it "returns UnsupportedMode in the response and leaves CurrentMode unchanged" do
    dishwasher = build(DishwasherMode, supported_modes: dishwasher_options, current_mode: 0_u8)
    response = dishwasher.change_to_mode(ModeBase::ChangeToModeRequest.new(7_u8))

    response.status.should eq(ModeBase::ModeChangeStatus::UnsupportedMode.value)
    dishwasher.current_mode.should eq(0_u8)
    decoded = ModeBase::ChangeToModeResponse.from_tlv(response.to_tlv(nil))
    decoded.status.should eq(response.status)
    decoded.status_text.should eq(response.status_text)
  end

  it "lets the host refuse a supported transition with mandatory failure text" do
    laundry = build(LaundryWasherMode, supported_modes: laundry_options, current_mode: 0_u8)
    laundry.on_change_to_mode = ->(_previous : UInt8, _requested : UInt8) do
      ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::InvalidInMode, "Cycle running")
    end

    response = laundry.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8))
    response.status.should eq(ModeBase::ModeChangeStatus::InvalidInMode.value)
    response.status_text.should eq("Cycle running")
    laundry.current_mode.should eq(0_u8)
    expect_raises(ArgumentError) { ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::InvalidInMode, "") }
  end

  it "changes to a supported mode and treats same-mode requests as success" do
    dishwasher = build(DishwasherMode, supported_modes: dishwasher_options, current_mode: 0_u8)
    calls = 0
    dishwasher.on_change_to_mode = ->(_previous : UInt8, _requested : UInt8) do
      calls += 1
      ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::Success)
    end

    dishwasher.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8)).status.should eq(0_u8)
    dishwasher.current_mode.should eq(1_u8)
    dishwasher.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8)).status.should eq(0_u8)
    calls.should eq(1)
    expect_raises(ArgumentError) { dishwasher.current_mode = 7_u8 }
  end

  it "reconciles persisted dishwasher mode when the host changes its catalogue" do
    original = build(DishwasherMode, supported_modes: dishwasher_options, current_mode: 1_u8)
    saved = original.save_state.as(Matter::Storage::Document)
    replacement = [
      ModeBase::Option.new("Normal", 2_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Normal.value)]),
      ModeBase::Option.new("Heavy", 3_u8, [ModeBase::Tag.new(DishwasherMode::ModeTag::Heavy.value)]),
    ]
    restored = build(DishwasherMode, supported_modes: replacement, current_mode: 2_u8)
    restored.restore_state(saved)
    restored.current_mode.should eq(2_u8)

    still_supported = build(DishwasherMode, supported_modes: dishwasher_options, current_mode: 0_u8)
    still_supported.restore_state(saved)
    still_supported.current_mode.should eq(1_u8)
  end

  it "reconciles persisted laundry mode when the host changes its catalogue" do
    original = build(LaundryWasherMode, supported_modes: laundry_options, current_mode: 1_u8)
    saved = original.save_state.as(Matter::Storage::Document)
    replacement = [
      ModeBase::Option.new("Normal", 2_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Normal.value)]),
      ModeBase::Option.new("Delicate", 3_u8, [ModeBase::Tag.new(LaundryWasherMode::ModeTag::Delicate.value)]),
    ]
    restored = build(LaundryWasherMode, supported_modes: replacement, current_mode: 2_u8)
    restored.restore_state(saved)
    restored.current_mode.should eq(2_u8)

    still_supported = build(LaundryWasherMode, supported_modes: laundry_options, current_mode: 0_u8)
    still_supported.restore_state(saved)
    still_supported.current_mode.should eq(1_u8)
  end

  it "keeps the fixed dishwasher catalogue isolated from caller and reader mutations" do
    options = dishwasher_options
    cluster = build(DishwasherMode, supported_modes: options, current_mode: 0_u8)
    options.first.mode_tags.clear
    options.first.label = "Changed"
    exposed = cluster.supported_modes
    exposed.first.mode_tags.clear
    exposed.first.mode = 9_u8

    cluster.supported_modes.first.label.should eq("Normal")
    cluster.supported_modes.first.mode.should eq(0_u8)
    cluster.supported_modes.first.mode_tags.size.should eq(1)
  end

  it "keeps the fixed laundry catalogue isolated from caller and reader mutations" do
    options = laundry_options
    cluster = build(LaundryWasherMode, supported_modes: options, current_mode: 0_u8)
    options.first.mode_tags.clear
    options.first.label = "Changed"
    exposed = cluster.supported_modes
    exposed.first.mode_tags.clear
    exposed.first.mode = 9_u8

    cluster.supported_modes.first.label.should eq("Normal")
    cluster.supported_modes.first.mode.should eq(0_u8)
    cluster.supported_modes.first.mode_tags.size.should eq(1)
  end
end
