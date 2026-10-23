require "../spec_helper"

private alias EvseMode = Matter::Cluster::EnergyEvseMode
private alias EvseModeBase = Matter::Cluster::ModeBase

private def evse_modes : Array(EvseModeBase::Option)
  [
    EvseModeBase::Option.new("Manual", 0_u8,
      [EvseModeBase::Tag.new(EvseMode::ModeTag::Manual.value)]),
    EvseModeBase::Option.new("Time of use", 1_u8,
      [EvseModeBase::Tag.new(EvseMode::ModeTag::TimeOfUse.value)]),
  ]
end

describe EvseMode do
  it "advertises revision 2 and omits prohibited Mode Base elements" do
    cluster = build(EvseMode, supported_modes: evse_modes, current_mode: 0_u8)
    cluster.cluster_id.id.should eq(0x009D_u32)
    cluster.cluster_revision.should eq(2_u16)
    read(cluster, 0xFFFC_u32).should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([0_u32, 1_u32])
    accepted_command_ids(cluster).should eq([0_u32])
    generated_command_ids(cluster).should eq([1_u32])
  end

  it "requires supported unique tags, labels, and current selection" do
    expect_raises(ArgumentError) { build(EvseMode, supported_modes: evse_modes.first(1), current_mode: 0_u8) }
    expect_raises(ArgumentError) { build(EvseMode, supported_modes: evse_modes, current_mode: 9_u8) }
    unknown = evse_modes
    unknown[1] = EvseModeBase::Option.new("Unknown", 1_u8, [EvseModeBase::Tag.new(0x4004_u16)])
    expect_raises(ArgumentError) { build(EvseMode, supported_modes: unknown, current_mode: 0_u8) }
  end

  it "requires a standalone Manual mode" do
    no_manual = [
      EvseModeBase::Option.new("Solar", 0_u8, [EvseModeBase::Tag.new(EvseMode::ModeTag::SolarCharging.value)]),
      EvseModeBase::Option.new("Time of use", 1_u8, [EvseModeBase::Tag.new(EvseMode::ModeTag::TimeOfUse.value)]),
    ]
    expect_raises(ArgumentError) { build(EvseMode, supported_modes: no_manual, current_mode: 0_u8) }

    combined = evse_modes
    combined[0] = EvseModeBase::Option.new("Manual solar", 0_u8,
      [EvseModeBase::Tag.new(EvseMode::ModeTag::Manual.value),
       EvseModeBase::Tag.new(EvseMode::ModeTag::SolarCharging.value)])
    expect_raises(ArgumentError) { build(EvseMode, supported_modes: combined, current_mode: 0_u8) }
  end

  it "handles unsupported, accepted, and host-refused transitions" do
    cluster = build(EvseMode, supported_modes: evse_modes, current_mode: 0_u8)
    cluster.change_to_mode(EvseModeBase::ChangeToModeRequest.new(9_u8)).status
      .should eq(EvseModeBase::ModeChangeStatus::UnsupportedMode.value)
    cluster.on_change_to_mode = ->(_current : UInt8, _requested : UInt8) do
      EvseModeBase::ChangeToModeResponse.new(EvseModeBase::ModeChangeStatus::InvalidInMode, "grid unavailable")
    end
    cluster.change_to_mode(EvseModeBase::ChangeToModeRequest.new(1_u8)).status
      .should eq(EvseModeBase::ModeChangeStatus::InvalidInMode.value)
    cluster.current_mode.should eq(0_u8)
    cluster.on_change_to_mode = nil
    cluster.change_to_mode(EvseModeBase::ChangeToModeRequest.new(1_u8)).status
      .should eq(EvseModeBase::ModeChangeStatus::Success.value)
    cluster.current_mode.should eq(1_u8)
  end

  it "retains valid selections and uses the host default when modes change" do
    selected = build(EvseMode, supported_modes: evse_modes, current_mode: 1_u8)
    saved = selected.save_state.as(Matter::Storage::Document)
    restored = build(EvseMode, supported_modes: evse_modes, current_mode: 0_u8)
    restored.restore_state(saved)
    restored.current_mode.should eq(1_u8)

    replacement = [
      EvseModeBase::Option.new("Manual", 2_u8, [EvseModeBase::Tag.new(EvseMode::ModeTag::Manual.value)]),
      EvseModeBase::Option.new("Solar", 3_u8, [EvseModeBase::Tag.new(EvseMode::ModeTag::SolarCharging.value)]),
    ]
    changed = build(EvseMode, supported_modes: replacement, current_mode: 2_u8)
    changed.restore_state(saved)
    changed.current_mode.should eq(2_u8)
  end

  it "copies its fixed mode catalogue on assignment and read" do
    modes = evse_modes
    cluster = build(EvseMode, supported_modes: modes, current_mode: 0_u8)
    modes.first.mode_tags.clear
    cluster.supported_modes.last.mode_tags.clear
    cluster.supported_modes.first.mode_tags.size.should eq(1)
    cluster.supported_modes.last.mode_tags.size.should eq(1)
    expect_raises(ArgumentError) { cluster.supported_modes = evse_modes.reverse }
  end
end
