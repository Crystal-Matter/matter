require "../spec_helper"

private alias CommodityMeter = Matter::Cluster::CommodityMetering
private alias MeterStatus = Matter::InteractionModel::StatusCode

describe CommodityMeter do
  it "exposes revision one and four nullable read-only attributes" do
    cluster = build(CommodityMeter)
    cluster.cluster_id.id.should eq(0x0B07_u32)
    cluster.cluster_revision.should eq(1_u16)
    read(cluster, CommodityMeter::ATTR_METERED_QUANTITY).should be_nil
    read(cluster, CommodityMeter::ATTR_METERED_QUANTITY_TIMESTAMP).should be_nil
    read(cluster, CommodityMeter::ATTR_TARIFF_UNIT).should be_nil
    read(cluster, CommodityMeter::ATTR_MAXIMUM_METERED_QUANTITIES).should be_nil
    accepted_command_ids(cluster).should be_empty
    write(cluster, CommodityMeter::ATTR_MAXIMUM_METERED_QUANTITIES, 2_u16).status.should eq(MeterStatus::UnsupportedWrite)
  end

  it "encodes metered quantity using canonical TLV tags and isolates component IDs" do
    ids = [7_u32, 9_u32]
    quantity = CommodityMeter::MeteredQuantity.new(ids, 123_456_i64)
    ids.clear
    quantity.tariff_component_ids.should eq([7_u32, 9_u32])
    quantity.tariff_component_ids.clear
    quantity.tariff_component_ids.should eq([7_u32, 9_u32])
    quantity.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    decoded = CommodityMeter::MeteredQuantity.from_tlv(quantity.to_tlv(nil))
    decoded.tariff_component_ids.should eq([7_u32, 9_u32])
    decoded.quantity.should eq(123_456_i64)
    expect_raises(ArgumentError) { CommodityMeter::MeteredQuantity.new(Array.new(129, 1_u32), 1_i64) }
  end

  it "validates a complete reading and keeps invalid updates atomic" do
    one = CommodityMeter::MeteredQuantity.new([4_u32], 25_i64)
    two = CommodityMeter::MeteredQuantity.new([5_u32], -10_i64)
    cluster = build(CommodityMeter)
    expect_raises(ArgumentError) { cluster.publish([one], 100_u32, CommodityMeter::TariffUnit::KWh, 0_u16) }
    expect_raises(ArgumentError) { cluster.publish([one, two], 100_u32, CommodityMeter::TariffUnit::KWh, 1_u16) }
    read(cluster, CommodityMeter::ATTR_METERED_QUANTITY).should be_nil

    source = [one]
    changed = capture_changes(cluster) do
      cluster.publish(source, 100_u32, CommodityMeter::TariffUnit::KWh, 2_u16)
    end
    changed.map(&.attribute).sort.should eq([
      CommodityMeter::ATTR_METERED_QUANTITY,
      CommodityMeter::ATTR_METERED_QUANTITY_TIMESTAMP,
      CommodityMeter::ATTR_TARIFF_UNIT,
      CommodityMeter::ATTR_MAXIMUM_METERED_QUANTITIES,
    ].sort)
    source.clear
    cluster.metered_quantity.as(Array(CommodityMeter::MeteredQuantity)).size.should eq(1)
    cluster.metered_quantity.as(Array(CommodityMeter::MeteredQuantity)).clear
    cluster.metered_quantity.as(Array(CommodityMeter::MeteredQuantity)).size.should eq(1)

    expect_raises(ArgumentError) { cluster.publish([one, two], 200_u32, CommodityMeter::TariffUnit::KWh, 1_u16) }
    cluster.metered_quantity_timestamp.should eq(100_u32)
    cluster.maximum_metered_quantities.should eq(2_u16)
    read_tlv(cluster, CommodityMeter::ATTR_METERED_QUANTITY).as_list.size.should eq(1)
    capture_changes(cluster) { cluster.publish([one], 100_u32, CommodityMeter::TariffUnit::KWh, 2_u16) }.should be_empty
  end

  it "clears unavailable data to four nulls and does not persist readings" do
    quantity = CommodityMeter::MeteredQuantity.new([] of UInt32, 0_i64)
    cluster = build(CommodityMeter, metered_quantity: [quantity],
      metered_quantity_timestamp: 500_u32,
      tariff_unit: CommodityMeter::TariffUnit::KVAh,
      maximum_metered_quantities: 1_u16)
    read_tlv(cluster, CommodityMeter::ATTR_METERED_QUANTITY).as_list.size.should eq(1)
    cluster.clear_reading
    read(cluster, CommodityMeter::ATTR_METERED_QUANTITY).should be_nil
    read(cluster, CommodityMeter::ATTR_METERED_QUANTITY_TIMESTAMP).should be_nil
    read(cluster, CommodityMeter::ATTR_TARIFF_UNIT).should be_nil
    read(cluster, CommodityMeter::ATTR_MAXIMUM_METERED_QUANTITIES).should be_nil
    expect_raises(ArgumentError) { build(CommodityMeter, tariff_unit: CommodityMeter::TariffUnit::KWh) }
    build(CommodityMeter).metered_quantity.should be_nil
  end
end
