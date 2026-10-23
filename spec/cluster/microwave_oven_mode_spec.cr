require "../spec_helper"

private alias MicrowaveMode = Matter::Cluster::MicrowaveOvenMode
private alias MicrowaveModeBase = Matter::Cluster::ModeBase

private def microwave_modes : Array(MicrowaveModeBase::Option)
  [
    MicrowaveModeBase::Option.new("Normal", 0_u8, [MicrowaveModeBase::Tag.new(MicrowaveMode::ModeTag::Normal.value)]),
    MicrowaveModeBase::Option.new("Defrost", 1_u8, [MicrowaveModeBase::Tag.new(MicrowaveMode::ModeTag::Defrost.value)]),
  ]
end

describe "Matter 1.6 Microwave Oven Mode" do
  it "advertises revision two without disallowed Mode Base commands or attributes" do
    cluster = build(MicrowaveMode, supported_modes: microwave_modes, current_mode: 0_u8)
    cluster.cluster_id.id.should eq(0x005E_u32)
    cluster.cluster_revision.should eq(2_u16)
    read(cluster, 0xFFFC_u32).should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([0_u32, 1_u32])
    accepted_command_ids(cluster).should be_empty
    generated_command_ids(cluster).should be_empty
  end

  it "validates derived tags and current selection" do
    expect_raises(ArgumentError) { build(MicrowaveMode, supported_modes: microwave_modes.first(1), current_mode: 0_u8) }
    expect_raises(ArgumentError) { build(MicrowaveMode, supported_modes: microwave_modes, current_mode: 2_u8) }
    unknown = microwave_modes
    unknown[1] = MicrowaveModeBase::Option.new("Unknown", 1_u8, [MicrowaveModeBase::Tag.new(0x4002_u16)])
    expect_raises(ArgumentError) { build(MicrowaveMode, supported_modes: unknown, current_mode: 0_u8) }
  end

  it "accepts a host-selected supported mode and rejects unsupported selections" do
    cluster = build(MicrowaveMode, supported_modes: microwave_modes, current_mode: 0_u8)
    cluster.current_mode = 1_u8
    cluster.current_mode.should eq(1_u8)
    expect_raises(ArgumentError) { cluster.current_mode = 9_u8 }
  end

  it "keeps the fixed catalogue independent of caller and reader mutations" do
    modes = microwave_modes
    cluster = build(MicrowaveMode, supported_modes: modes, current_mode: 0_u8)
    modes.first.mode_tags.clear
    modes[0] = MicrowaveModeBase::Option.new("Changed", 9_u8, [MicrowaveModeBase::Tag.new(0_u16)])
    exposed = cluster.supported_modes
    exposed.last.mode_tags.clear
    exposed[1] = MicrowaveModeBase::Option.new("Changed", 9_u8, [MicrowaveModeBase::Tag.new(0_u16)])
    cluster.supported_modes.first.label.should eq("Normal")
    cluster.supported_modes.first.mode_tags.size.should eq(1)
    cluster.supported_modes.last.mode.should eq(1_u8)
    cluster.supported_modes.last.mode_tags.size.should eq(1)
    expect_raises(ArgumentError) { cluster.supported_modes = microwave_modes.reverse }
  end

  it "restores a supported selection and falls back when the catalogue changes" do
    saved = build(MicrowaveMode, supported_modes: microwave_modes, current_mode: 1_u8).save_state.as(Matter::Storage::Document)
    retained = build(MicrowaveMode, supported_modes: microwave_modes, current_mode: 0_u8)
    retained.restore_state(saved)
    retained.current_mode.should eq(1_u8)

    replacement = [
      MicrowaveModeBase::Option.new("Normal", 2_u8, [MicrowaveModeBase::Tag.new(MicrowaveMode::ModeTag::Normal.value)]),
      MicrowaveModeBase::Option.new("Defrost", 3_u8, [MicrowaveModeBase::Tag.new(MicrowaveMode::ModeTag::Defrost.value)]),
    ]
    changed = build(MicrowaveMode, supported_modes: replacement, current_mode: 2_u8)
    changed.restore_state(saved)
    changed.current_mode.should eq(2_u8)
  end
end
