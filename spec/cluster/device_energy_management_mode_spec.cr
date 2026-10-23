require "../spec_helper"

private alias EnergyMode = Matter::Cluster::DeviceEnergyManagementMode
private alias EnergyModeBase = Matter::Cluster::ModeBase

private def energy_modes : Array(EnergyModeBase::Option)
  [
    EnergyModeBase::Option.new("No optimization", 0_u8,
      [EnergyModeBase::Tag.new(EnergyMode::ModeTag::NoOptimization.value)]),
    EnergyModeBase::Option.new("Grid optimization", 1_u8,
      [EnergyModeBase::Tag.new(EnergyMode::ModeTag::GridOptimization.value)]),
  ]
end

describe EnergyMode do
  it "advertises revision 2 and omits prohibited Mode Base elements" do
    cluster = build(EnergyMode, supported_modes: energy_modes, current_mode: 0_u8)
    cluster.cluster_id.id.should eq(0x009F_u32)
    cluster.cluster_revision.should eq(2_u16)
    read(cluster, 0xFFFC_u32).should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([0_u32, 1_u32])
    accepted_command_ids(cluster).should eq([0_u32])
    generated_command_ids(cluster).should eq([1_u32])
  end

  it "requires supported unique tags, labels, and current selection" do
    expect_raises(ArgumentError) { build(EnergyMode, supported_modes: energy_modes.first(1), current_mode: 0_u8) }
    expect_raises(ArgumentError) { build(EnergyMode, supported_modes: energy_modes, current_mode: 9_u8) }
    unknown = energy_modes
    unknown[1] = EnergyModeBase::Option.new("Unknown", 1_u8, [EnergyModeBase::Tag.new(0x4004_u16)])
    expect_raises(ArgumentError) { build(EnergyMode, supported_modes: unknown, current_mode: 0_u8) }
  end

  it "handles unsupported, accepted, and host-refused transitions" do
    cluster = build(EnergyMode, supported_modes: energy_modes, current_mode: 0_u8)
    cluster.change_to_mode(EnergyModeBase::ChangeToModeRequest.new(9_u8)).status
      .should eq(EnergyModeBase::ModeChangeStatus::UnsupportedMode.value)
    cluster.on_change_to_mode = ->(_current : UInt8, _requested : UInt8) do
      EnergyModeBase::ChangeToModeResponse.new(EnergyModeBase::ModeChangeStatus::InvalidInMode, "grid unavailable")
    end
    cluster.change_to_mode(EnergyModeBase::ChangeToModeRequest.new(1_u8)).status
      .should eq(EnergyModeBase::ModeChangeStatus::InvalidInMode.value)
    cluster.current_mode.should eq(0_u8)
    cluster.on_change_to_mode = nil
    cluster.change_to_mode(EnergyModeBase::ChangeToModeRequest.new(1_u8)).status
      .should eq(EnergyModeBase::ModeChangeStatus::Success.value)
    cluster.current_mode.should eq(1_u8)
  end

  it "retains valid selections and uses the host default when modes change" do
    selected = build(EnergyMode, supported_modes: energy_modes, current_mode: 1_u8)
    saved = selected.save_state.as(Matter::Storage::Document)
    restored = build(EnergyMode, supported_modes: energy_modes, current_mode: 0_u8)
    restored.restore_state(saved)
    restored.current_mode.should eq(1_u8)

    replacement = [
      EnergyModeBase::Option.new("Local", 2_u8, [EnergyModeBase::Tag.new(EnergyMode::ModeTag::LocalOptimization.value)]),
      EnergyModeBase::Option.new("Device", 3_u8, [EnergyModeBase::Tag.new(EnergyMode::ModeTag::DeviceOptimization.value)]),
    ]
    changed = build(EnergyMode, supported_modes: replacement, current_mode: 2_u8)
    changed.restore_state(saved)
    changed.current_mode.should eq(2_u8)
  end

  it "copies its fixed mode catalogue on assignment and read" do
    modes = energy_modes
    cluster = build(EnergyMode, supported_modes: modes, current_mode: 0_u8)
    modes.first.mode_tags.clear
    cluster.supported_modes.last.mode_tags.clear
    cluster.supported_modes.first.mode_tags.size.should eq(1)
    cluster.supported_modes.last.mode_tags.size.should eq(1)
    expect_raises(ArgumentError) { cluster.supported_modes = energy_modes.reverse }
  end
end
