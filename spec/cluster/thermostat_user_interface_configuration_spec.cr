require "../spec_helper"

private alias ThermostatUI = Matter::Cluster::ThermostatUserInterfaceConfiguration

describe "Matter 1.6 Thermostat User Interface Configuration" do
  it "declares revision 2 and the mandatory and supported optional attributes" do
    cluster = build(ThermostatUI)
    cluster.cluster_id.id.should eq(0x0204_u32)
    cluster.cluster_revision.should eq(2_u16)
    cluster.attributes.map(&.id.id).should eq([
      ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE,
      ThermostatUI::ATTR_KEYPAD_LOCKOUT,
      ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY,
    ])
    cluster.commands.should be_empty
    read(cluster, ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE).should eq(0_u8)
    read(cluster, ThermostatUI::ATTR_KEYPAD_LOCKOUT).should eq(0_u8)
    read(cluster, ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY).should eq(0_u8)
  end

  it "enforces the XML privileges and enum domains on writes" do
    cluster = build(ThermostatUI)
    cluster.attributes.find!(&.id.id.==(ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE)).write_access
      .should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    [ThermostatUI::ATTR_KEYPAD_LOCKOUT, ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY].each do |id|
      cluster.attributes.find!(&.id.id.==(id)).write_access
        .should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    end

    expect_status(write(cluster, ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE, 1_u8),
      Matter::InteractionModel::StatusCode::Success)
    expect_status(write(cluster, ThermostatUI::ATTR_KEYPAD_LOCKOUT, 5_u8),
      Matter::InteractionModel::StatusCode::Success)
    expect_status(write(cluster, ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY, 1_u8),
      Matter::InteractionModel::StatusCode::Success)
    read(cluster, ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE).should eq(1_u8)
    read(cluster, ThermostatUI::ATTR_KEYPAD_LOCKOUT).should eq(5_u8)
    read(cluster, ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY).should eq(1_u8)

    expect_status(write(cluster, ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE, 2_u8),
      Matter::InteractionModel::StatusCode::ConstraintError)
    expect_status(write(cluster, ThermostatUI::ATTR_KEYPAD_LOCKOUT, 6_u8),
      Matter::InteractionModel::StatusCode::ConstraintError)
    expect_status(write(cluster, ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY, 2_u8),
      Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "restores accepted preferences and lockout after restart" do
    source = build(ThermostatUI)
    write(source, ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE, 1_u8)
    write(source, ThermostatUI::ATTR_KEYPAD_LOCKOUT, 3_u8)
    write(source, ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY, 1_u8)
    restored = build(ThermostatUI)
    restored.restore_state(source.save_state.as(Matter::Storage::Document))
    read(restored, ThermostatUI::ATTR_TEMPERATURE_DISPLAY_MODE).should eq(1_u8)
    read(restored, ThermostatUI::ATTR_KEYPAD_LOCKOUT).should eq(3_u8)
    read(restored, ThermostatUI::ATTR_SCHEDULE_PROGRAMMING_VISIBILITY).should eq(1_u8)
  end
end
