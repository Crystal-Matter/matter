require "../spec_helper"

private alias EnergyPreference = Matter::Cluster::EnergyPreference
private alias IMCode = Matter::InteractionModel::StatusCode

private def energy_balances : Array(EnergyPreference::Balance)
  [
    EnergyPreference::Balance.new(0_u8, "Comfort"),
    EnergyPreference::Balance.new(50_u8, "Balanced"),
    EnergyPreference::Balance.new(100_u8, "Efficient"),
  ]
end

private def low_power_sensitivities : Array(EnergyPreference::Balance)
  [
    EnergyPreference::Balance.new(0_u8, "Conservative"),
    EnergyPreference::Balance.new(100_u8, "Aggressive"),
  ]
end

private def energy_preference : EnergyPreference
  build(EnergyPreference,
    feature_map: EnergyPreference::Feature::EnergyBalance | EnergyPreference::Feature::LowPowerModeSensitivity,
    energy_balances: energy_balances,
    energy_priorities: [EnergyPreference::EnergyPriority::Comfort, EnergyPreference::EnergyPriority::Efficiency],
    low_power_mode_sensitivities: low_power_sensitivities)
end

describe EnergyPreference do
  it "declares Matter 1.6 revision 1 and both conditional preference groups" do
    cluster = energy_preference
    cluster.cluster_id.id.should eq(0x009b_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([
      EnergyPreference::ATTR_ENERGY_BALANCES,
      EnergyPreference::ATTR_CURRENT_ENERGY_BALANCE,
      EnergyPreference::ATTR_ENERGY_PRIORITIES,
      EnergyPreference::ATTR_LOW_POWER_MODE_SENSITIVITIES,
      EnergyPreference::ATTR_CURRENT_LOW_POWER_MODE_SENSITIVITY,
    ])
    cluster.commands.should be_empty
    cluster.events.should be_empty
    read_tlv(cluster, EnergyPreference::ATTR_ENERGY_BALANCES).as_list.size.should eq(3)
    read(cluster, EnergyPreference::ATTR_CURRENT_ENERGY_BALANCE).should eq(0_u8)
    read(cluster, EnergyPreference::ATTR_CURRENT_LOW_POWER_MODE_SENSITIVITY).should eq(0_u8)
  end

  it "hides attributes belonging to unsupported features and uses canonical struct tags" do
    balance = EnergyPreference::Balance.new(50_u8, "Balanced")
    balance.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    EnergyPreference::Balance.from_tlv(balance.to_tlv(nil)).label.should eq("Balanced")

    only_energy = build(EnergyPreference, feature_map: EnergyPreference::Feature::EnergyBalance,
      energy_balances: energy_balances,
      energy_priorities: [EnergyPreference::EnergyPriority::Comfort, EnergyPreference::EnergyPriority::Efficiency])
    read_status(only_energy, EnergyPreference::ATTR_LOW_POWER_MODE_SENSITIVITIES).status.should eq(IMCode::UnsupportedAttribute)

    only_low_power = build(EnergyPreference, feature_map: EnergyPreference::Feature::LowPowerModeSensitivity,
      low_power_mode_sensitivities: low_power_sensitivities)
    read_status(only_low_power, EnergyPreference::ATTR_ENERGY_BALANCES).status.should eq(IMCode::UnsupportedAttribute)
  end

  it "requires a feature and validates every advertised scale" do
    expect_raises(ArgumentError) { build(EnergyPreference, feature_map: EnergyPreference::Feature::None) }
    expect_raises(ArgumentError) do
      build(EnergyPreference, feature_map: EnergyPreference::Feature::EnergyBalance,
        energy_balances: [EnergyPreference::Balance.new(0_u8), EnergyPreference::Balance.new(50_u8)],
        energy_priorities: [EnergyPreference::EnergyPriority::Comfort, EnergyPreference::EnergyPriority::Efficiency])
    end
    expect_raises(ArgumentError) do
      build(EnergyPreference, feature_map: EnergyPreference::Feature::EnergyBalance,
        energy_balances: [EnergyPreference::Balance.new(0_u8), EnergyPreference::Balance.new(0_u8), EnergyPreference::Balance.new(100_u8)],
        energy_priorities: [EnergyPreference::EnergyPriority::Comfort, EnergyPreference::EnergyPriority::Efficiency])
    end
    expect_raises(ArgumentError) do
      build(EnergyPreference, feature_map: EnergyPreference::Feature::EnergyBalance,
        energy_balances: energy_balances,
        energy_priorities: [EnergyPreference::EnergyPriority::Comfort, EnergyPreference::EnergyPriority::Comfort])
    end
    expect_raises(ArgumentError) do
      build(EnergyPreference, feature_map: EnergyPreference::Feature::EnergyBalance,
        energy_balances: [EnergyPreference::Balance.new(0_u8, "x" * 65), EnergyPreference::Balance.new(100_u8)],
        energy_priorities: [EnergyPreference::EnergyPriority::Comfort, EnergyPreference::EnergyPriority::Efficiency])
    end
    expect_raises(ArgumentError) do
      build(EnergyPreference, feature_map: EnergyPreference::Feature::LowPowerModeSensitivity,
        low_power_mode_sensitivities: [EnergyPreference::Balance.new(10_u8), EnergyPreference::Balance.new(10_u8)])
    end
  end

  it "returns ConstraintError for out-of-range indices and persists accepted preferences" do
    cluster = energy_preference
    expect_status(write(cluster, EnergyPreference::ATTR_CURRENT_ENERGY_BALANCE, 3_u8), IMCode::ConstraintError)
    expect_status(write(cluster, EnergyPreference::ATTR_CURRENT_LOW_POWER_MODE_SENSITIVITY, 2_u8), IMCode::ConstraintError)
    expect_status(write(cluster, EnergyPreference::ATTR_CURRENT_ENERGY_BALANCE, 2_u8), IMCode::Success)
    expect_status(write(cluster, EnergyPreference::ATTR_CURRENT_LOW_POWER_MODE_SENSITIVITY, 1_u8), IMCode::Success)
    restored = energy_preference
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    read(restored, EnergyPreference::ATTR_CURRENT_ENERGY_BALANCE).should eq(2_u8)
    read(restored, EnergyPreference::ATTR_CURRENT_LOW_POWER_MODE_SENSITIVITY).should eq(1_u8)
  end

  it "keeps extreme energy preferences when the host changes available steps" do
    cluster = energy_preference
    cluster.update_energy_balances([
      EnergyPreference::Balance.new(0_u8), EnergyPreference::Balance.new(25_u8),
      EnergyPreference::Balance.new(75_u8), EnergyPreference::Balance.new(100_u8),
    ])
    cluster.current_energy_balance.should eq(0_u8)
    cluster.current_energy_balance = 3_u8
    cluster.update_energy_balances(energy_balances)
    cluster.current_energy_balance.should eq(2_u8)

    cluster.current_energy_balance = 1_u8
    cluster.update_energy_balances([
      EnergyPreference::Balance.new(0_u8), EnergyPreference::Balance.new(25_u8),
      EnergyPreference::Balance.new(75_u8), EnergyPreference::Balance.new(100_u8),
    ])
    cluster.current_energy_balance.should eq(1_u8)
  end

  it "resets the energy selection when the manufacturer changes its priorities" do
    cluster = energy_preference
    cluster.current_energy_balance = 2_u8
    cluster.update_energy_priorities([
      EnergyPreference::EnergyPriority::Speed,
      EnergyPreference::EnergyPriority::WaterConsumption,
    ])
    cluster.current_energy_balance.should eq(0_u8)
  end

  it "maps persisted selections to the nearest configured steps after restart" do
    source = energy_preference
    source.current_energy_balance = 1_u8
    source.current_low_power_mode_sensitivity = 1_u8
    restored = build(EnergyPreference,
      feature_map: EnergyPreference::Feature::EnergyBalance | EnergyPreference::Feature::LowPowerModeSensitivity,
      energy_balances: [
        EnergyPreference::Balance.new(0_u8), EnergyPreference::Balance.new(25_u8),
        EnergyPreference::Balance.new(75_u8), EnergyPreference::Balance.new(100_u8),
      ],
      energy_priorities: [EnergyPreference::EnergyPriority::Comfort, EnergyPreference::EnergyPriority::Efficiency],
      low_power_mode_sensitivities: [
        EnergyPreference::Balance.new(0_u8), EnergyPreference::Balance.new(40_u8), EnergyPreference::Balance.new(90_u8),
      ])
    restored.restore_state(source.save_state.as(Matter::Storage::Document))
    restored.current_energy_balance.should eq(1_u8)
    restored.current_low_power_mode_sensitivity.should eq(2_u8)

    source.current_energy_balance = 2_u8
    restored.restore_state(source.save_state.as(Matter::Storage::Document))
    restored.current_energy_balance.should eq(3_u8)
  end
end
