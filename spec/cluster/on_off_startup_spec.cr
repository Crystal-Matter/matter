require "../spec_helper"
require "../../src/matter/cluster/on_off"

private alias StartupOnOff = Matter::Cluster::OnOff

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
end
