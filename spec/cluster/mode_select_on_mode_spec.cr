require "../spec_helper"
require "../../src/matter/cluster/mode_select"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/bridged_device_basic_information"
require "../../src/matter/endpoint"

private alias OnModeSelect = Matter::Cluster::ModeSelect
private alias OnModeOnOff = Matter::Cluster::OnOff

private def on_mode_cluster : OnModeSelect
  build(OnModeSelect, description: "Operating mode",
    supported_modes: [OnModeSelect::ModeOption.new("Eco", 1_u8), OnModeSelect::ModeOption.new("Boost", 2_u8)],
    current_mode: 1_u8, feature_map: OnModeSelect::Feature::OnOff, on_mode: 2_u8)
end

describe "Mode Select OnMode dependency" do
  it "applies OnMode on an Off-to-On command without replacing the host OnOff callback" do
    on_off = build(OnModeOnOff)
    mode = on_mode_cluster
    endpoint = Matter::Endpoint.new(endpoint(1_u16))
    endpoint.add_cluster(mode)
    endpoint.add_cluster(on_off)

    states = [] of Bool
    on_off.on_state_changed { |state| states << state }
    expect_success(invoke(on_off, OnModeOnOff::CMD_ON))
    mode.current_mode.should eq(2_u8)
    states.should eq([true])

    mode.current_mode = 1_u8
    expect_success(invoke(on_off, OnModeOnOff::CMD_ON))
    mode.current_mode.should eq(1_u8)
    expect_success(invoke(on_off, OnModeOnOff::CMD_OFF))
    mode.current_mode.should eq(1_u8)
    states.should eq([true, false])
    expect_success(invoke(on_off, OnModeOnOff::CMD_ON))
    mode.current_mode.should eq(2_u8)
  end

  it "applies OnMode when a bridge host reports Off-to-On, regardless of cluster insertion order" do
    on_off = build(OnModeOnOff)
    mode = on_mode_cluster
    endpoint = Matter::Endpoint.new(endpoint(1_u16))
    endpoint.add_cluster(on_off)
    endpoint.add_cluster(mode)
    endpoint.add_cluster(build(Matter::Cluster::BridgedDeviceBasicInformation, unique_id: "bridged-mode"))

    on_off.on_off = true
    mode.current_mode.should eq(2_u8)
    on_off.on_off = false
    mode.current_mode = 1_u8
    mode.on_mode = nil
    on_off.on_off = true
    mode.current_mode.should eq(1_u8)
  end
end
