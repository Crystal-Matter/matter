require "../spec_helper"

private alias RunMode = Matter::Cluster::RvcRunMode
private alias CleanMode = Matter::Cluster::RvcCleanMode
private alias ModeBase = Matter::Cluster::ModeBase

private def rvc_mode(label : String, id : UInt8, *tags : UInt16) : ModeBase::Option
  ModeBase::Option.new(label, id, tags.to_a.map { |tag| ModeBase::Tag.new(tag) })
end

private def run_modes : Array(ModeBase::Option)
  [
    rvc_mode("Idle", 0_u8, RunMode::ModeTag::Idle.value),
    rvc_mode("Clean", 1_u8, RunMode::ModeTag::Cleaning.value),
    rvc_mode("Map", 2_u8, RunMode::ModeTag::Mapping.value),
  ]
end

private def clean_modes : Array(ModeBase::Option)
  [
    rvc_mode("Vacuum", 0_u8, CleanMode::ModeTag::Vacuum.value),
    rvc_mode("Mop", 1_u8, CleanMode::ModeTag::Mop.value),
  ]
end

describe RunMode do
  it "advertises revision four and only derived Mode Base attributes" do
    cluster = build(RunMode, supported_modes: run_modes, current_mode: 0_u8)
    cluster.cluster_id.id.should eq(0x0054_u32)
    cluster.cluster_revision.should eq(4_u16)
    cluster.attributes.map(&.id.id).should eq([RunMode::ATTR_SUPPORTED_MODES, RunMode::ATTR_CURRENT_MODE])
    accepted_command_ids(cluster).should eq([RunMode::CMD_CHANGE_TO_MODE])
  end

  it "requires separate Idle and Cleaning options and exclusive run tags" do
    expect_raises(ArgumentError) { build(RunMode, supported_modes: run_modes[1..], current_mode: 1_u8) }
    expect_raises(ArgumentError) { build(RunMode, supported_modes: [run_modes[0], run_modes[2]], current_mode: 0_u8) }
    invalid = rvc_mode("Both", 1_u8, RunMode::ModeTag::Idle.value, RunMode::ModeTag::Cleaning.value)
    expect_raises(ArgumentError) { build(RunMode, supported_modes: [run_modes[0], invalid], current_mode: 0_u8) }
  end

  it "requires Idle between distinct active modes unless DirectModeChange is enabled" do
    cluster = build(RunMode, supported_modes: run_modes, current_mode: 0_u8)
    cluster.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8)).success?.should be_true
    response = cluster.change_to_mode(ModeBase::ChangeToModeRequest.new(2_u8))
    response.status.should eq(ModeBase::ModeChangeStatus::InvalidInMode.value)
    response.status_text.should_not be_empty
    cluster.current_mode.should eq(1_u8)
    cluster.change_to_mode(ModeBase::ChangeToModeRequest.new(0_u8)).success?.should be_true
    enabled = build(RunMode, supported_modes: run_modes, current_mode: 1_u8,
      feature_map: RunMode::Feature::DirectModeChange)
    enabled.change_to_mode(ModeBase::ChangeToModeRequest.new(2_u8)).success?.should be_true
    enabled.current_mode.should eq(2_u8)
  end

  it "keeps its fixed catalogue independent and restores to the configured mode when removed" do
    modes = run_modes
    cluster = build(RunMode, supported_modes: modes, current_mode: 0_u8)
    modes.clear
    cluster.supported_modes.size.should eq(3)
    cluster.supported_modes.clear
    cluster.supported_modes.size.should eq(3)
    expect_raises(ArgumentError) { cluster.supported_modes = run_modes[0..1] }
  end

  it "returns a typed RVC rejection without changing CurrentMode" do
    cluster = build(RunMode, supported_modes: run_modes, current_mode: 0_u8)
    cluster.on_change_to_mode = ->(_current : UInt8, _requested : UInt8) do
      ModeBase::ChangeToModeResponse.new(RunMode::ModeStatus::Stuck.value, "Robot is stuck")
    end
    response = cluster.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8))
    response.status.should eq(RunMode::ModeStatus::Stuck.value)
    cluster.current_mode.should eq(0_u8)
  end
end

describe CleanMode do
  it "requires a Vacuum or Mop option and couples DirectModeChange to Run Mode" do
    run = build(RunMode, supported_modes: run_modes, current_mode: 0_u8)
    expect_raises(ArgumentError) do
      build(CleanMode, run_mode: run, supported_modes: [
        rvc_mode("Deep", 0_u8, CleanMode::ModeTag::DeepClean.value),
        rvc_mode("Quick", 1_u8, 1_u16),
      ], current_mode: 0_u8)
    end
    clean = build(CleanMode, run_mode: run, supported_modes: clean_modes, current_mode: 0_u8)
    clean.cluster_revision.should eq(5_u16)
    clean.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8)).success?.should be_true
    run.change_to_mode(ModeBase::ChangeToModeRequest.new(1_u8)).success?.should be_true
    denied = clean.change_to_mode(ModeBase::ChangeToModeRequest.new(0_u8))
    denied.status.should eq(ModeBase::ModeChangeStatus::InvalidInMode.value)
    denied.status_text.should_not be_empty
    enabled = build(CleanMode, run_mode: run, supported_modes: clean_modes, current_mode: 1_u8,
      feature_map: CleanMode::Feature::DirectModeChange)
    enabled.change_to_mode(ModeBase::ChangeToModeRequest.new(0_u8)).success?.should be_true
  end
end
