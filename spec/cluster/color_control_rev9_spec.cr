require "../spec_helper"
require "../../src/matter/cluster/color_control"
require "../../src/matter/device"

private alias RevisionNineColor = Matter::Cluster::ColorControl
private alias RevisionNinePrivilege = Matter::InteractionModel::EntryPrivilege

private class RevisionNineColorDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Color Startup Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8130_u16,
    discriminator: 3850_u16, pin: 20202096_u32,
    device_type: Matter::DeviceType::EXTENDED_COLOR_LIGHT

  storage :memory

  endpoint 1, device_type: Matter::DeviceType::EXTENDED_COLOR_LIGHT do
    cluster Matter::Cluster::OnOff, feature_map: :lighting
    cluster Matter::Cluster::LevelControl
    cluster Matter::Cluster::ColorControl, as: :color_control
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
  end
end

describe "Color Control Matter 1.6 revision 9" do
  it "advertises mandatory metadata and correct write privileges" do
    color = build(RevisionNineColor)
    color.cluster_revision.should eq(9_u16)
    number = color.attributes.find!(&.id.id.==(RevisionNineColor::ATTR_NUMBER_OF_PRIMARIES))
    coupling = color.attributes.find!(&.id.id.==(RevisionNineColor::ATTR_COUPLE_COLOR_TEMP_TO_LEVEL_MIN_MIREDS))
    startup = color.attributes.find!(&.id.id.==(RevisionNineColor::ATTR_START_UP_COLOR_TEMPERATURE_MIREDS))
    options = color.attributes.find!(&.id.id.==(RevisionNineColor::ATTR_OPTIONS))
    number.fixed?.should be_true
    number.optional?.should be_false
    coupling.optional?.should be_false
    startup.optional?.should be_false
    startup.write_access.should eq(RevisionNinePrivilege::Manage)
    options.write_access.should eq(RevisionNinePrivilege::Operate)
    read(color, RevisionNineColor::ATTR_COUPLE_COLOR_TEMP_TO_LEVEL_MIN_MIREDS).should eq(color.color_temp_physical_min_mireds)
  end

  it "does not advertise temperature fields without the CT feature" do
    color = build(RevisionNineColor, feature_map: RevisionNineColor::Feature::HueSaturation)
    ids = color.attributes.map(&.id.id)
    ids.should contain(RevisionNineColor::ATTR_NUMBER_OF_PRIMARIES)
    ids.should_not contain(RevisionNineColor::ATTR_COUPLE_COLOR_TEMP_TO_LEVEL_MIN_MIREDS)
    ids.should_not contain(RevisionNineColor::ATTR_START_UP_COLOR_TEMPERATURE_MIREDS)
  end

  it "enforces the XML's feature dependencies" do
    expect_raises(ArgumentError) do
      build(RevisionNineColor, feature_map: RevisionNineColor::Feature::ColorLoop)
    end
    expect_raises(ArgumentError) do
      build(RevisionNineColor, feature_map: RevisionNineColor::Feature::EnhancedHue)
    end
  end

  it "encodes ColorLoopActive as a bounded uint8 value" do
    color = build(RevisionNineColor, feature_map: RevisionNineColor::Feature::HueSaturation |
                                                  RevisionNineColor::Feature::EnhancedHue | RevisionNineColor::Feature::ColorLoop)
    read(color, RevisionNineColor::ATTR_COLOR_LOOP_ACTIVE).should eq(0_u8)
    color.color_loop_active = 1_u8
    read(color, RevisionNineColor::ATTR_COLOR_LOOP_ACTIVE).should eq(1_u8)
    expect_raises(ArgumentError) { color.color_loop_active = 2_u8 }
  end

  it "reports configured fixed primaries and only their required coordinates" do
    color = build(RevisionNineColor, primary_coordinates: [{100_u16, 200_u16}, {300_u16, 400_u16}])
    read(color, RevisionNineColor::ATTR_NUMBER_OF_PRIMARIES).should eq(2_u8)
    read(color, RevisionNineColor::ATTR_PRIMARY_1_X).should eq(100_u16)
    read(color, RevisionNineColor::ATTR_PRIMARY_1_Y).should eq(200_u16)
    read(color, RevisionNineColor::ATTR_PRIMARY_2_X).should eq(300_u16)
    read(color, RevisionNineColor::ATTR_PRIMARY_2_Y).should eq(400_u16)
    color.attributes.map(&.id.id).should_not contain(RevisionNineColor::ATTR_PRIMARY_3_X)
    expect_raises(ArgumentError) { color.number_of_primaries = 3_u8 }
  end

  it "rejects invalid fixed primary and coupling configuration" do
    expect_raises(ArgumentError) do
      build(RevisionNineColor, primary_coordinates: Array({UInt16, UInt16}).new(7) { {1_u16, 1_u16} })
    end
    expect_raises(ArgumentError) do
      build(RevisionNineColor, primary_coordinates: [{RevisionNineColor::CHROMATICITY_MAX + 1_u16, 1_u16}])
    end
    expect_raises(ArgumentError) do
      build(RevisionNineColor, couple_color_temp_to_level_min_mireds: 100_u16)
    end
  end

  it "persists startup temperature and applies it on ordinary power-up" do
    original = build(RevisionNineColor)
    original.start_up_color_temperature_mireds = 320_u16
    original.color_temperature_mireds = 250_u16
    saved = original.save_state.as(Matter::Storage::Document)
    saved["start_up_color_temperature_mireds"].should eq(320_i64)

    restored = build(RevisionNineColor)
    restored.restore_state(saved)
    restored.apply_startup_color_temperature
    restored.color_temperature_mireds.should eq(320_u16)
    restored.color_mode.should eq(RevisionNineColor::ColorMode::ColorTemperatureMireds)
    restored.enhanced_color_mode.should eq(RevisionNineColor::EnhancedColorMode::ColorTemperatureMireds)
  end

  it "preserves color on OTA restart and when startup setting is null" do
    color = build(RevisionNineColor)
    color.start_up_color_temperature_mireds = 320_u16
    color.apply_startup_color_temperature(ota_restart: true)
    color.color_temperature_mireds.should eq(250_u16)
    color.start_up_color_temperature_mireds = nil
    color.apply_startup_color_temperature
    color.color_temperature_mireds.should eq(250_u16)
  end

  it "applies restored startup temperature through Device#start" do
    require_udp_sockets!
    backend = Matter::Storage::Memory.new
    first = RevisionNineColorDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    first.color_control.start_up_color_temperature_mireds = 320_u16
    first.persistence.save_cluster(first.color_control).should be_true
    first.shutdown!

    ordinary = RevisionNineColorDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    ordinary.start
    ordinary.color_control.color_temperature_mireds.should eq(320_u16)
    ordinary.shutdown!

    ota = RevisionNineColorDevice.new(backend, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    ota.color_control.color_temperature_mireds = 250_u16
    ota.start(ota_restart: true)
    ota.color_control.color_temperature_mireds.should eq(250_u16)
  ensure
    first.try(&.shutdown!)
    ordinary.try(&.shutdown!)
    ota.try(&.shutdown!)
  end
end
