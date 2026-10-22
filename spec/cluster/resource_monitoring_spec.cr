require "../spec_helper"

private alias Resource = Matter::Cluster::ResourceMonitoring
private alias Hepa = Matter::Cluster::HepaFilterMonitoring
private alias Carbon = Matter::Cluster::ActivatedCarbonFilterMonitoring
private alias WaterTank = Matter::Cluster::WaterTankLevelMonitoring
private alias IMCode = Matter::InteractionModel::StatusCode
private alias IMStatus = Matter::InteractionModel::Status

describe "Matter 1.6 Resource Monitoring family" do
  it "registers all three revision-one identities with the mandatory indication" do
    {build(Hepa) => 0x0071_u32, build(Carbon) => 0x0072_u32, build(WaterTank) => 0x0079_u32}.each do |cluster, id|
      cluster.cluster_id.id.should eq(id)
      cluster.cluster_revision.should eq(1_u16)
      cluster.attributes.map(&.id.id).should eq([Hepa::ATTR_CHANGE_INDICATION])
      cluster.commands.should be_empty
      expect_status(invoke(cluster, Hepa::CMD_RESET_CONDITION), IMCode::UnsupportedCommand)
      Matter::Cluster::Registry.for(id).should eq(cluster.class)
    end
  end

  it "gates Condition and ReplacementProductList by features" do
    products = [Resource::ReplacementProduct.new(Resource::ProductIdentifierType::Upc, "123456789012")]
    cluster = build(Hepa, feature_map: Hepa::Feature::Condition | Hepa::Feature::ReplacementProductList,
      replacement_product_list: products)
    cluster.attributes.map(&.id.id).should eq([
      Hepa::ATTR_CONDITION, Hepa::ATTR_DEGRADATION_DIRECTION,
      Hepa::ATTR_CHANGE_INDICATION, Hepa::ATTR_REPLACEMENT_PRODUCT_LIST,
    ])
    cluster.attributes.find!(&.id.id.==(Hepa::ATTR_DEGRADATION_DIRECTION)).fixed?.should be_true
    cluster.attributes.find!(&.id.id.==(Hepa::ATTR_REPLACEMENT_PRODUCT_LIST)).fixed?.should be_true
    read_tlv(cluster, Hepa::ATTR_REPLACEMENT_PRODUCT_LIST).as_list.size.should eq(1)
    expect_raises(ArgumentError) do
      build(Hepa, feature_map: Hepa::Feature::ReplacementProductList,
        replacement_product_list: Array.new(6) { |i| Resource::ReplacementProduct.new(Resource::ProductIdentifierType::Oem, "#{i}") })
    end
    expect_raises(ArgumentError) do
      build(Hepa, feature_map: Hepa::Feature::ReplacementProductList,
        replacement_product_list: [Resource::ReplacementProduct.new(Resource::ProductIdentifierType::Oem, "a"),
                                   Resource::ReplacementProduct.new(Resource::ProductIdentifierType::Oem, "a")])
    end
  end

  it "does not expose a mutable reference to its fixed replacement product list" do
    product = Resource::ReplacementProduct.new(Resource::ProductIdentifierType::Oem, "filter-1")
    cluster = build(Hepa, feature_map: Hepa::Feature::ReplacementProductList,
      replacement_product_list: [product])
    initial_version = cluster.data_version
    cluster.replacement_product_list << Resource::ReplacementProduct.new(Resource::ProductIdentifierType::Oem, "filter-2")
    cluster.replacement_product_list.size.should eq(1)
    read_tlv(cluster, Hepa::ATTR_REPLACEMENT_PRODUCT_LIST).as_list.size.should eq(1)
    cluster.data_version.should eq(initial_version)
  end

  it "validates condition and warning feature on host reports" do
    cluster = build(Carbon, feature_map: Carbon::Feature::Condition)
    expect_raises(ArgumentError) { cluster.update_resource(101_u8, Resource::ChangeIndication::Critical) }
    expect_raises(ArgumentError) { cluster.update_resource(25_u8, Resource::ChangeIndication::Warning) }
    cluster.condition.should eq(100_u8)
    cluster.change_indication.should eq(Resource::ChangeIndication::Ok)
    expect_raises(ArgumentError) { cluster.condition = 101_u8 }
    expect_raises(ArgumentError) { cluster.change_indication = Resource::ChangeIndication::Warning }
    cluster.update_resource(20_u8, Resource::ChangeIndication::Critical)
    cluster.condition.should eq(20_u8)
    cluster.change_indication.should eq(Resource::ChangeIndication::Critical)
  end

  it "resets upwards and downwards resources only after host acceptance" do
    [Resource::DegradationDirection::Down, Resource::DegradationDirection::Up].each do |direction|
      cluster = build(WaterTank, feature_map: WaterTank::Feature::Condition | WaterTank::Feature::Warning,
        degradation_direction: direction, reset_condition_supported: true)
      cluster.update_resource(40_u8, Resource::ChangeIndication::Warning)
      expect_status(invoke(cluster, WaterTank::CMD_RESET_CONDITION), IMCode::InvalidInState)
      cluster.on_reset_condition { IMStatus.invalid_in_state }
      expect_status(invoke(cluster, WaterTank::CMD_RESET_CONDITION), IMCode::InvalidInState)
      cluster.condition.should eq(40_u8)
      cluster.on_reset_condition { IMStatus.success }
      expect_success(invoke(cluster, WaterTank::CMD_RESET_CONDITION))
      cluster.condition.should eq(direction.up? ? 0_u8 : 100_u8)
      cluster.change_indication.should eq(Resource::ChangeIndication::Ok)
    end
  end

  it "persists only optional LastChangedTime and enforces its Operate write" do
    cluster = build(Hepa, feature_map: Hepa::Feature::Condition,
      last_changed_time_supported: true, in_place_indicator_supported: true)
    metadata = cluster.attributes.find!(&.id.id.==(Hepa::ATTR_LAST_CHANGED_TIME))
    metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    expect_success(write(cluster, Hepa::ATTR_LAST_CHANGED_TIME, 1234_u32))
    cluster.update_resource(50_u8, Resource::ChangeIndication::Critical)
    cluster.in_place_indicator = false
    saved = cluster.save_state.as(Matter::Storage::Document)
    saved.has_key?("last_changed_time").should be_true
    saved.has_key?("condition").should be_false
    saved.has_key?("change_indication").should be_false
    restored = build(Hepa, feature_map: Hepa::Feature::Condition,
      last_changed_time_supported: true, in_place_indicator_supported: true)
    restored.restore_state(saved)
    restored.last_changed_time.should eq(1234_u32)
    restored.condition.should eq(100_u8)
    restored.change_indication.should eq(Resource::ChangeIndication::Ok)
    restored.in_place_indicator?.should be_true
  end
end
