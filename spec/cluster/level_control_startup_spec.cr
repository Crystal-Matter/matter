require "../spec_helper"
require "../../src/matter/cluster/level_control"
require "../../src/matter/device"

private alias StartupLevel = Matter::Cluster::LevelControl

private class StartupLevelDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Startup Level Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8128_u16,
    discriminator: 3848_u16, pin: 20202096_u32,
    device_type: Matter::DeviceType::DIMMABLE_LIGHT

  storage :memory

  endpoint 1, device_type: Matter::DeviceType::DIMMABLE_LIGHT do
    cluster Matter::Cluster::OnOff, feature_map: :lighting
    cluster Matter::Cluster::LevelControl, feature_map: StartupLevel::Feature::OnOff | StartupLevel::Feature::Lighting,
      as: :level_control
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
  end
end

private def restored_startup_level(current : UInt8?, startup : UInt8?) : StartupLevel
  original = build(StartupLevel, current_level: 80_u8,
    feature_map: StartupLevel::Feature::OnOff | StartupLevel::Feature::Lighting)
  original.current_level = current
  original.start_up_current_level = startup
  saved = original.save_state.as(Matter::Storage::Document)

  restored = build(StartupLevel,
    feature_map: StartupLevel::Feature::OnOff | StartupLevel::Feature::Lighting)
  restored.restore_state(saved)
  restored
end

describe "LevelControl Matter 1.6 startup behavior" do
  # Matter 1.6 Application Cluster §1.6.6.15: zero selects MinLevel,
  # null preserves the previous level, and another value is the new level.
  it "applies a configured StartUpCurrentLevel on ordinary power-up" do
    level = restored_startup_level(80_u8, 42_u8)
    level.apply_startup_level(ota_restart: false)
    level.current_level.should eq(42_u8)
    level.save_state.as(Matter::Storage::Document)["current_level"].should eq(42_i64)
  end

  it "maps StartUpCurrentLevel zero to the configured minimum" do
    level = restored_startup_level(80_u8, 0_u8)
    level.apply_startup_level(ota_restart: false)
    level.current_level.should eq(level.min_level)
  end

  it "retains the previous nullable CurrentLevel when StartUpCurrentLevel is null" do
    level = restored_startup_level(nil, nil)
    level.apply_startup_level(ota_restart: false)
    level.current_level.should be_nil
  end

  it "retains the previous CurrentLevel after an OTA restart" do
    level = restored_startup_level(80_u8, 42_u8)
    level.apply_startup_level(ota_restart: true)
    level.current_level.should eq(80_u8)
  end

  it "applies startup after restoring state, but bypasses it for an OTA restart" do
    require_udp_sockets!
    backend = Matter::Storage::Memory.new

    first = StartupLevelDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    first.level_control.current_level = 80_u8
    first.level_control.start_up_current_level = 42_u8
    first.persistence.save_cluster(first.level_control).should be_true
    first.shutdown!

    ordinary = StartupLevelDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    ordinary.level_control.current_level.should eq(80_u8)
    ordinary.start
    ordinary.level_control.current_level.should eq(42_u8)
    ordinary.shutdown!

    ota = StartupLevelDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    ota.level_control.current_level = 80_u8
    ota.persistence.save_cluster(ota.level_control).should be_true
    ota.start(ota_restart: true)
    ota.level_control.current_level.should eq(80_u8)
  ensure
    first.try(&.shutdown!)
    ordinary.try(&.shutdown!)
    ota.try(&.shutdown!)
  end
end
