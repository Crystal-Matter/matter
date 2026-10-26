require "../spec_helper"
require "../../src/matter/cluster/on_off"
require "../../src/matter/device"

private alias StartupOnOff = Matter::Cluster::OnOff

private class StartupBridgeDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Startup Bridge Test",
    vendor_id: 0xFFF1_u16, product_id: 0x812A_u16,
    discriminator: 3850_u16, pin: 20202098_u32,
    device_type: Matter::DeviceType::ROOT_NODE

  storage :memory
end

private def restored_lighting_on_off(previous : Bool, startup : StartupOnOff::StartUpOnOff?) : StartupOnOff
  original = build(StartupOnOff, feature_map: StartupOnOff::Feature::Lighting)
  original.on_off = previous
  original.start_up_on_off = startup
  restored = build(StartupOnOff, feature_map: StartupOnOff::Feature::Lighting)
  restored.restore_state(original.save_state.as(Matter::Storage::Document))
  restored
end

describe "OnOff Matter 1.6 startup behavior" do
  it "applies Off, On, and Toggle to the persisted OnOff state" do
    off = restored_lighting_on_off(true, StartupOnOff::StartUpOnOff::Off)
    off.apply_startup_on_off
    off.on?.should be_false

    on = restored_lighting_on_off(false, StartupOnOff::StartUpOnOff::On)
    on.apply_startup_on_off
    on.on?.should be_true

    toggle = restored_lighting_on_off(false, StartupOnOff::StartUpOnOff::Toggle)
    toggle.apply_startup_on_off
    toggle.on?.should be_true
    toggle.save_state.as(Matter::Storage::Document)["on_off"].should be_true
  end

  it "keeps the previous value for null startup, OTA restart, or no Lighting feature" do
    unchanged = restored_lighting_on_off(true, nil)
    unchanged.apply_startup_on_off
    unchanged.on?.should be_true

    ota = restored_lighting_on_off(false, StartupOnOff::StartUpOnOff::On)
    ota.apply_startup_on_off(ota_restart: true)
    ota.on?.should be_false

    unlit = build(StartupOnOff, on_off: false)
    unlit.apply_startup_on_off
    unlit.on?.should be_false
  end

  it "leaves bridge-owned endpoint state to the bridge host" do
    require_udp_sockets!
    device = StartupBridgeDevice.new(Matter::Storage::Memory.new, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    device.add_endpoint(endpoint_id: 2_u16, device_type: Matter::DeviceType::AGGREGATOR,
      clusters: [] of Matter::Cluster::Base).should be_true

    bridged = Matter::Cluster::OnOff.new(endpoint(3_u16), feature_map: StartupOnOff::Feature::Lighting)
    bridged.on_off = true
    bridged.start_up_on_off = StartupOnOff::StartUpOnOff::Off
    device.add_endpoint(endpoint_id: 3_u16, device_type: Matter::DeviceType::ON_OFF_LIGHT,
      parent_endpoint: 2_u16, clusters: [
      bridged,
      Matter::Cluster::Identify.new(endpoint(3_u16)),
      Matter::Cluster::Groups.new(endpoint(3_u16)),
    ] of Matter::Cluster::Base).should be_true

    device.start
    bridged.on?.should be_true
  ensure
    device.try(&.shutdown!)
  end
end
