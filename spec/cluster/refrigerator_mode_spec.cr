require "../spec_helper"

private alias RefrigeratorMode = Matter::Cluster::RefrigeratorAndTemperatureControlledCabinetMode
private alias ModeBase = Matter::Cluster::ModeBase

private def refrigerator_modes : Array(ModeBase::Option)
  [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(0_u16)]),
    ModeBase::Option.new("Rapid Cool", 1_u8, [ModeBase::Tag.new(RefrigeratorMode::ModeTag::RapidCool.value)]),
  ]
end

describe "Matter 1.6 Refrigerator and Temperature Controlled Cabinet Mode" do
  it "advertises revision three and only the permitted Mode Base attributes" do
    cluster = build(RefrigeratorMode, supported_modes: refrigerator_modes, current_mode: 0_u8)
    cluster.cluster_id.id.should eq(0x0052_u32)
    cluster.cluster_revision.should eq(3_u16)
    read(cluster, 0xFFFC_u32).should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([0_u32, 1_u32])
    accepted_command_ids(cluster).should eq([0_u32])
    generated_command_ids(cluster).should eq([1_u32])
    RefrigeratorMode::COMMANDS_BY_ID[RefrigeratorMode::CMD_CHANGE_TO_MODE].response_id.should eq(1_u32)
  end

  it "validates derived tags and the initial selection" do
    expect_raises(ArgumentError) do
      build(RefrigeratorMode, supported_modes: refrigerator_modes.first(1), current_mode: 0_u8)
    end
    expect_raises(ArgumentError) do
      build(RefrigeratorMode, supported_modes: refrigerator_modes, current_mode: 2_u8)
    end
    unknown = refrigerator_modes
    unknown[1] = ModeBase::Option.new("Unknown", 1_u8, [ModeBase::Tag.new(0x4002_u16)])
    expect_raises(ArgumentError) do
      build(RefrigeratorMode, supported_modes: unknown, current_mode: 0_u8)
    end
  end

  it "returns UnsupportedMode without changing state and accepts a supported transition" do
    cluster = build(RefrigeratorMode, supported_modes: refrigerator_modes, current_mode: 0_u8)
    cluster.change_to_mode(ModeBase::ChangeToModeRequest.new(9_u8)).status.should eq(ModeBase::ModeChangeStatus::UnsupportedMode.value)
    cluster.current_mode.should eq(0_u8)
    cluster.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8)).status.should eq(ModeBase::ModeChangeStatus::Success.value)
    cluster.current_mode.should eq(1_u8)
    expect_raises(ArgumentError) { cluster.current_mode = 9_u8 }
  end

  it "leaves the current mode alone when the appliance refuses a transition" do
    cluster = build(RefrigeratorMode, supported_modes: refrigerator_modes, current_mode: 0_u8)
    cluster.on_change_to_mode = ->(_current : UInt8, _requested : UInt8) do
      ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::InvalidInMode, "door open")
    end
    response = cluster.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8))
    response.status.should eq(ModeBase::ModeChangeStatus::InvalidInMode.value)
    response.status_text.should eq("door open")
    cluster.current_mode.should eq(0_u8)
  end

  it "keeps its fixed catalogue independent of caller and reader mutations" do
    modes = refrigerator_modes
    cluster = build(RefrigeratorMode, supported_modes: modes, current_mode: 0_u8)
    modes.first.mode_tags.clear
    modes[0] = ModeBase::Option.new("Changed", 0_u8, [ModeBase::Tag.new(0_u16)])
    exposed = cluster.supported_modes
    exposed.last.mode_tags.clear
    exposed[1] = ModeBase::Option.new("Changed", 9_u8, [ModeBase::Tag.new(0_u16)])
    cluster.supported_modes.first.label.should eq("Normal")
    cluster.supported_modes.first.mode_tags.size.should eq(1)
    cluster.supported_modes.last.mode.should eq(1_u8)
    cluster.supported_modes.last.mode_tags.size.should eq(1)
    expect_raises(ArgumentError) { cluster.supported_modes = refrigerator_modes.reverse }
  end

  it "restores a supported selection and falls back when the host catalogue changes" do
    original = build(RefrigeratorMode, supported_modes: refrigerator_modes, current_mode: 1_u8)
    saved = original.save_state.as(Matter::Storage::Document)
    retained = build(RefrigeratorMode, supported_modes: refrigerator_modes, current_mode: 0_u8)
    retained.restore_state(saved)
    retained.current_mode.should eq(1_u8)

    replacement = [
      ModeBase::Option.new("Normal", 2_u8, [ModeBase::Tag.new(0_u16)]),
      ModeBase::Option.new("Rapid Freeze", 3_u8, [ModeBase::Tag.new(RefrigeratorMode::ModeTag::RapidFreeze.value)]),
    ]
    changed = build(RefrigeratorMode, supported_modes: replacement, current_mode: 2_u8)
    changed.restore_state(saved)
    changed.current_mode.should eq(2_u8)
  end
end
