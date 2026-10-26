require "../spec_helper"
require "../../src/matter/cluster/mode_select"
require "../../src/matter/device"

private alias StartupMode = Matter::Cluster::ModeSelect

private class StartupModeDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Startup Mode Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8129_u16,
    discriminator: 3849_u16, pin: 20202097_u32,
    device_type: Matter::DeviceType::ON_OFF_LIGHT

  storage :memory

  endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT do
    cluster Matter::Cluster::OnOff, feature_map: :lighting, as: :on_off_cluster
    cluster StartupMode, description: "Operating mode",
      supported_modes: [StartupMode::ModeOption.new("Eco", 1_u8), StartupMode::ModeOption.new("Boost", 2_u8)],
      current_mode: 1_u8, feature_map: StartupMode::Feature::OnOff, as: :mode_select
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
  end
end

describe "Mode Select Matter 1.6 startup behavior" do
  it "applies a persisted StartUpMode on ordinary power-up and retains CurrentMode after OTA" do
    require_udp_sockets!
    backend = Matter::Storage::Memory.new
    first = StartupModeDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    first.mode_select.current_mode = 2_u8
    first.mode_select.start_up_mode = 1_u8
    first.persistence.save_cluster(first.mode_select).should be_true
    first.shutdown!

    ordinary = StartupModeDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    ordinary.mode_select.current_mode.should eq(2_u8)
    ordinary.start
    ordinary.mode_select.current_mode.should eq(1_u8)
    ordinary.shutdown!

    ota = StartupModeDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    ota.mode_select.current_mode = 2_u8
    ota.persistence.save_cluster(ota.mode_select).should be_true
    ota.start(ota_restart: true)
    ota.mode_select.current_mode.should eq(2_u8)
  ensure
    first.try(&.shutdown!)
    ordinary.try(&.shutdown!)
    ota.try(&.shutdown!)
  end

  it "leaves the persisted CurrentMode in place when StartUpMode is null" do
    mode = build(StartupMode, description: "Operating mode",
      supported_modes: [StartupMode::ModeOption.new("Eco", 1_u8), StartupMode::ModeOption.new("Boost", 2_u8)],
      current_mode: 2_u8)
    mode.start_up_mode.should be_nil
    mode.apply_startup_mode
    mode.current_mode.should eq(2_u8)
  end

  it "uses OnMode when OnOff starts On, including after an OTA reboot" do
    mode = build(StartupMode, description: "Operating mode",
      supported_modes: [StartupMode::ModeOption.new("Eco", 1_u8), StartupMode::ModeOption.new("Boost", 2_u8)],
      current_mode: 1_u8, feature_map: StartupMode::Feature::OnOff,
      start_up_mode: 1_u8, on_mode: 2_u8)
    mode.apply_startup_mode(on_mode_override: true)
    mode.current_mode.should eq(2_u8)
    mode.current_mode = 1_u8
    mode.apply_startup_mode(ota_restart: true, on_mode_override: true)
    mode.current_mode.should eq(2_u8)
    mode.current_mode = 1_u8
    mode.apply_startup_mode(ota_restart: true)
    mode.current_mode.should eq(1_u8)
  end

  it "reads the sibling OnOff power-up setting before choosing OnMode" do
    require_udp_sockets!
    backend = Matter::Storage::Memory.new
    device = StartupModeDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    device.mode_select.start_up_mode = 1_u8
    device.mode_select.on_mode = 2_u8
    device.on_off_cluster.start_up_on_off = Matter::Cluster::OnOff::StartUpOnOff::On
    device.start
    device.on_off_cluster.on?.should be_true
    device.mode_select.current_mode.should eq(2_u8)
    device.shutdown!

    ota = StartupModeDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    ota.on_off_cluster.on_off = false
    ota.mode_select.current_mode = 1_u8
    ota.persistence.save_cluster(ota.on_off_cluster).should be_true
    ota.persistence.save_cluster(ota.mode_select).should be_true
    ota.start(ota_restart: true)
    ota.on_off_cluster.on?.should be_false
    ota.mode_select.current_mode.should eq(1_u8)
  ensure
    device.try(&.shutdown!)
    ota.try(&.shutdown!)
  end
end
