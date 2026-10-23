require "../spec_helper"

private alias OvenMode = Matter::Cluster::OvenMode
private alias ModeBase = Matter::Cluster::ModeBase

private def oven_modes
  [
    ModeBase::Option.new("Bake", 0_u8, [ModeBase::Tag.new(OvenMode::ModeTag::Bake.value)]),
    ModeBase::Option.new("Roast", 1_u8, [ModeBase::Tag.new(OvenMode::ModeTag::Roast.value)]),
  ]
end

private def oven_mode
  build(OvenMode, supported_modes: oven_modes, current_mode: 0_u8)
end

describe OvenMode do
  it "advertises the revision-two oven surface without OnOff or startup attributes" do
    cluster = oven_mode
    cluster.cluster_id.id.should eq(0x0049_u32)
    cluster.cluster_revision.should eq(2_u16)
    read(cluster, 0xFFFC_u32).should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([OvenMode::ATTR_SUPPORTED_MODES, OvenMode::ATTR_CURRENT_MODE])
    accepted_command_ids(cluster).should eq([OvenMode::CMD_CHANGE_TO_MODE])
    generated_command_ids(cluster).should eq([OvenMode::CMD_CHANGE_TO_MODE_RESPONSE])
    read_status(cluster, 0x0002_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    read_status(cluster, 0x0003_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
  end

  it "provides every Matter 1.6 oven tag and validates derived mode tags" do
    OvenMode::DERIVED_TAGS.should eq((0x4000_u16..0x400C_u16).to_a)
    expect_raises(ArgumentError) do
      build(OvenMode, supported_modes: [
        ModeBase::Option.new("Wrong", 0_u8, [ModeBase::Tag.new(0x400D_u16)]),
        oven_modes.last,
      ], current_mode: 0_u8)
    end
  end

  it "keeps the fixed SupportedModes catalogue isolated from caller mutation" do
    configured = oven_modes
    cluster = build(OvenMode, supported_modes: configured, current_mode: 0_u8)
    configured.first.mode_tags.clear
    cluster.supported_modes.first.mode_tags.size.should eq(1)
    cluster.supported_modes.clear
    cluster.supported_modes.size.should eq(2)
  end

  it "changes modes only after host acceptance and preserves rejected state" do
    cluster = oven_mode
    unsupported = invoke(cluster, OvenMode::CMD_CHANGE_TO_MODE, ModeBase::ChangeToModeRequest.new(9_u8)).as(Matter::Cluster::CommandResponse)
    ModeBase::ChangeToModeResponse.from_tlv(unsupported.response.as(TLV::Any)).status.should eq(ModeBase::ModeChangeStatus::UnsupportedMode.value)
    cluster.current_mode.should eq(0_u8)

    cluster.on_change_to_mode = ->(_old : UInt8, _new : UInt8) {
      ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::InvalidInMode, "door open")
    }
    denied = invoke(cluster, OvenMode::CMD_CHANGE_TO_MODE, ModeBase::ChangeToModeRequest.new(1_u8)).as(Matter::Cluster::CommandResponse)
    ModeBase::ChangeToModeResponse.from_tlv(denied.response.as(TLV::Any)).status.should eq(ModeBase::ModeChangeStatus::InvalidInMode.value)
    cluster.current_mode.should eq(0_u8)

    cluster.on_change_to_mode = ->(_old : UInt8, _new : UInt8) { ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::Success) }
    accepted = invoke(cluster, OvenMode::CMD_CHANGE_TO_MODE, ModeBase::ChangeToModeRequest.new(1_u8)).as(Matter::Cluster::CommandResponse)
    accepted.command_id.should eq(OvenMode::CMD_CHANGE_TO_MODE_RESPONSE)
    cluster.current_mode.should eq(1_u8)
  end

  it "reconciles a saved mode removed from the current fixed catalogue" do
    previous = oven_mode
    previous.current_mode = 1_u8
    saved = previous.save_state.as(Matter::Storage::Document)
    configured = [
      ModeBase::Option.new("Steam", 2_u8, [ModeBase::Tag.new(OvenMode::ModeTag::Steam.value)]),
      ModeBase::Option.new("Roast", 3_u8, [ModeBase::Tag.new(OvenMode::ModeTag::Roast.value)]),
    ]
    restored = build(OvenMode, supported_modes: configured, current_mode: 3_u8)
    restored.restore_state(saved)
    restored.current_mode.should eq(3_u8)
  end
end
