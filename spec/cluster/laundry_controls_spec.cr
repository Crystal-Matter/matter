require "../spec_helper"

private alias Dryer = Matter::Cluster::LaundryDryerControls
private alias Washer = Matter::Cluster::LaundryWasherControls
private alias LaundryStatus = Matter::InteractionModel::Status
private alias LaundryCode = Matter::InteractionModel::StatusCode

private def dryer
  build(Dryer, supported_dryness_levels: [Dryer::DrynessLevel::Low, Dryer::DrynessLevel::Normal],
    selected_dryness_level: Dryer::DrynessLevel::Normal)
end

private def washer
  build(Washer, feature_map: Washer::Feature::Spin | Washer::Feature::Rinse,
    spin_speeds: ["Gentle", "Fast"], spin_speed_current: 1_u8,
    supported_rinses: [Washer::NumberOfRinses::None, Washer::NumberOfRinses::Normal],
    number_of_rinses: Washer::NumberOfRinses::Normal)
end

describe "Matter 1.6 Laundry Dryer Controls" do
  it "advertises the revision-one attribute-only schema and operate writes" do
    cluster = dryer
    cluster.cluster_id.id.should eq(0x004A_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([Dryer::ATTR_SUPPORTED_DRYNESS_LEVELS, Dryer::ATTR_SELECTED_DRYNESS_LEVEL])
    cluster.commands.should be_empty
    cluster.events.should be_empty
    cluster.get_attribute_metadata(Dryer::ATTR_SELECTED_DRYNESS_LEVEL).as(Matter::Cluster::AttributeMetadata).write_access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    read_tlv(cluster, Dryer::ATTR_SUPPORTED_DRYNESS_LEVELS).as_list.size.should eq(2)
    read(cluster, Dryer::ATTR_SELECTED_DRYNESS_LEVEL).should eq(Dryer::DrynessLevel::Normal.value)
  end

  it "requires one to four supported levels and a selected member" do
    expect_raises(ArgumentError) { build(Dryer, supported_dryness_levels: [] of Dryer::DrynessLevel) }
    expect_raises(ArgumentError) do
      build(Dryer, supported_dryness_levels: [Dryer::DrynessLevel::Low] * 5)
    end
    expect_raises(ArgumentError) do
      build(Dryer, supported_dryness_levels: [Dryer::DrynessLevel::Low],
        selected_dryness_level: Dryer::DrynessLevel::Extra)
    end
    expect_raises(ArgumentError) { dryer.supported_dryness_levels = [] of Dryer::DrynessLevel }
  end

  it "validates remote writes before host acceptance and supports null" do
    cluster = dryer
    write(cluster, Dryer::ATTR_SUPPORTED_DRYNESS_LEVELS, [Dryer::DrynessLevel::Max]).status.should eq(LaundryCode::UnsupportedWrite)
    write(cluster, Dryer::ATTR_SELECTED_DRYNESS_LEVEL, Dryer::DrynessLevel::Extra).status.should eq(LaundryCode::ConstraintError)
    write(cluster, Dryer::ATTR_SELECTED_DRYNESS_LEVEL, Dryer::DrynessLevel::Low).status.should eq(LaundryCode::InvalidInState)
    cluster.on_select_dryness { |_level| LaundryStatus.invalid_in_state }
    write(cluster, Dryer::ATTR_SELECTED_DRYNESS_LEVEL, Dryer::DrynessLevel::Low).status.should eq(LaundryCode::InvalidInState)
    read(cluster, Dryer::ATTR_SELECTED_DRYNESS_LEVEL).should eq(Dryer::DrynessLevel::Normal.value)
    cluster.on_select_dryness { |_level| LaundryStatus.success }
    write(cluster, Dryer::ATTR_SELECTED_DRYNESS_LEVEL, nil).status.should eq(LaundryCode::Success)
    read(cluster, Dryer::ATTR_SELECTED_DRYNESS_LEVEL).should be_nil
  end

  it "reconciles a persisted selection with the current mode after restart" do
    original = dryer
    saved = original.save_state.as(Matter::Storage::Document)
    restored = build(Dryer, supported_dryness_levels: [Dryer::DrynessLevel::Low],
      selected_dryness_level: nil)
    restored.restore_state(saved)
    restored.selected_dryness_level.should be_nil
    restored.supported_dryness_levels.should eq([Dryer::DrynessLevel::Low])
  end

  it "updates the mode-dependent dryness list and selection together" do
    cluster = dryer
    cluster.configure_mode([Dryer::DrynessLevel::Extra], Dryer::DrynessLevel::Extra)
    cluster.supported_dryness_levels.should eq([Dryer::DrynessLevel::Extra])
    cluster.selected_dryness_level.should eq(Dryer::DrynessLevel::Extra)
  end
end

describe "Matter 1.6 Laundry Washer Controls" do
  it "requires Spin or Rinse and exposes only feature-gated attributes" do
    expect_raises(ArgumentError) { build(Washer, feature_map: Washer::Feature::None) }
    spin = build(Washer, feature_map: Washer::Feature::Spin, spin_speeds: ["Fast"], spin_speed_current: 0_u8)
    spin.cluster_id.id.should eq(0x0053_u32)
    spin.cluster_revision.should eq(2_u16)
    spin.attributes.map(&.id.id).should eq([Washer::ATTR_SPIN_SPEEDS, Washer::ATTR_SPIN_SPEED_CURRENT])
    read_status(spin, Washer::ATTR_NUMBER_OF_RINSES).status.should eq(LaundryCode::UnsupportedAttribute)
    rinse = build(Washer, feature_map: Washer::Feature::Rinse,
      supported_rinses: [Washer::NumberOfRinses::Normal], number_of_rinses: Washer::NumberOfRinses::Normal)
    rinse.attributes.map(&.id.id).should eq([Washer::ATTR_NUMBER_OF_RINSES, Washer::ATTR_SUPPORTED_RINSES])
    washer.attributes.map(&.id.id).should eq([
      Washer::ATTR_SPIN_SPEEDS, Washer::ATTR_SPIN_SPEED_CURRENT,
      Washer::ATTR_NUMBER_OF_RINSES, Washer::ATTR_SUPPORTED_RINSES,
    ])
    washer.commands.should be_empty
    washer.events.should be_empty
  end

  it "enforces spin list and current index constraints" do
    expect_raises(ArgumentError) { build(Washer, feature_map: Washer::Feature::Spin, spin_speeds: [] of String) }
    expect_raises(ArgumentError) do
      build(Washer, feature_map: Washer::Feature::Spin, spin_speeds: ["x" * 65])
    end
    expect_raises(ArgumentError) do
      build(Washer, feature_map: Washer::Feature::Spin, spin_speeds: ["Fast"], spin_speed_current: 1_u8)
    end
    cluster = washer
    write(cluster, Washer::ATTR_SPIN_SPEED_CURRENT, 15_u8).status.should eq(LaundryCode::ConstraintError)
    write(cluster, Washer::ATTR_SPIN_SPEED_CURRENT, 2_u8).status.should eq(LaundryCode::ConstraintError)
    write(cluster, Washer::ATTR_SPIN_SPEED_CURRENT, 0_u8).status.should eq(LaundryCode::InvalidInState)
    cluster.on_select_spin_speed { |_index| LaundryStatus.success }
    write(cluster, Washer::ATTR_SPIN_SPEED_CURRENT, nil).status.should eq(LaundryCode::Success)
    read(cluster, Washer::ATTR_SPIN_SPEED_CURRENT).should be_nil
  end

  it "enforces distinct supported rinses and host state for writes" do
    expect_raises(ArgumentError) do
      build(Washer, feature_map: Washer::Feature::Rinse,
        supported_rinses: [Washer::NumberOfRinses::Normal, Washer::NumberOfRinses::Normal],
        number_of_rinses: Washer::NumberOfRinses::Normal)
    end
    cluster = washer
    write(cluster, Washer::ATTR_NUMBER_OF_RINSES, Washer::NumberOfRinses::Extra).status.should eq(LaundryCode::ConstraintError)
    write(cluster, Washer::ATTR_NUMBER_OF_RINSES, Washer::NumberOfRinses::None).status.should eq(LaundryCode::InvalidInState)
    cluster.on_select_rinses { |_rinses| LaundryStatus.success }
    write(cluster, Washer::ATTR_NUMBER_OF_RINSES, Washer::NumberOfRinses::None).status.should eq(LaundryCode::Success)
    read(cluster, Washer::ATTR_NUMBER_OF_RINSES).should eq(Washer::NumberOfRinses::None.value)
  end

  it "reconciles saved spin and rinse selections with the current mode" do
    saved = washer.save_state.as(Matter::Storage::Document)
    restored = build(Washer, feature_map: Washer::Feature::Spin | Washer::Feature::Rinse,
      spin_speeds: ["Gentle"], spin_speed_current: nil,
      supported_rinses: [Washer::NumberOfRinses::None], number_of_rinses: Washer::NumberOfRinses::None)
    restored.restore_state(saved)
    restored.spin_speeds.should eq(["Gentle"])
    restored.spin_speed_current.should be_nil
    restored.number_of_rinses.should eq(Washer::NumberOfRinses::None)
  end

  it "updates mode-dependent spin and rinse options without leaving an invalid selection" do
    cluster = washer
    cluster.configure_spin_mode(["Eco"], nil)
    cluster.spin_speeds.should eq(["Eco"])
    cluster.spin_speed_current.should be_nil
    cluster.configure_rinse_mode([Washer::NumberOfRinses::Extra], Washer::NumberOfRinses::Extra)
    cluster.supported_rinses.should eq([Washer::NumberOfRinses::Extra])
    cluster.number_of_rinses.should eq(Washer::NumberOfRinses::Extra)
  end
end
