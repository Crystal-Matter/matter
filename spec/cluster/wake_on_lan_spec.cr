require "../spec_helper"
require "../../src/matter/cluster/wake_on_lan"

alias WakeOnLan = Matter::Cluster::WakeOnLan

describe WakeOnLan do
  link_local = Bytes[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

  it "advertises revision 1 and omits both optional addresses when unconfigured" do
    cluster = build(WakeOnLan)

    cluster.cluster_id.id.should eq(0x0503_u32)
    read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(1_u16)
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(0_u32)
    attribute_ids(cluster).should_not contain(WakeOnLan::ATTR_MAC_ADDRESS)
    attribute_ids(cluster).should_not contain(WakeOnLan::ATTR_LINK_LOCAL_ADDRESS)
    expect_status(read_status(cluster, WakeOnLan::ATTR_MAC_ADDRESS), Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    expect_status(read_status(cluster, WakeOnLan::ATTR_LINK_LOCAL_ADDRESS), Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    accepted_command_ids(cluster).should be_empty
    generated_command_ids(cluster).should be_empty
  end

  it "encodes configured addresses using the canonical string and 16-byte IPv6 types" do
    cluster = build(WakeOnLan, mac_address: "12345678ABCD", link_local_address: link_local)

    attribute_ids(cluster).should contain(WakeOnLan::ATTR_MAC_ADDRESS)
    attribute_ids(cluster).should contain(WakeOnLan::ATTR_LINK_LOCAL_ADDRESS)
    read(cluster, WakeOnLan::ATTR_MAC_ADDRESS).should eq("12345678ABCD")
    read(cluster, WakeOnLan::ATTR_LINK_LOCAL_ADDRESS).should eq(link_local)
    cluster.get_attribute_metadata(WakeOnLan::ATTR_MAC_ADDRESS).as(Matter::Cluster::AttributeMetadata).writable?.should be_false
    cluster.get_attribute_metadata(WakeOnLan::ATTR_LINK_LOCAL_ADDRESS).as(Matter::Cluster::AttributeMetadata).writable?.should be_false
  end

  it "rejects invalid MAC formats and non-link-local IPv6 addresses before advertisement" do
    ["12345678abcD", "12:34:56:78:AB:CD", "12345678ABC", "12345678ABCG", ""].each do |mac|
      expect_raises(ArgumentError) { build(WakeOnLan, mac_address: mac) }
    end
    expect_raises(ArgumentError) { build(WakeOnLan, link_local_address: Bytes.new(15, 0_u8)) }
    expect_raises(ArgumentError) { build(WakeOnLan, link_local_address: Bytes.new(16, 0_u8)) }
    expect_raises(ArgumentError) { build(WakeOnLan, link_local_address: Bytes[0xfe, 0xc0] + Bytes.new(14, 0_u8)) }
  end

  it "copies a configured IPv6 address and rejects host attempts to change fixed addresses" do
    supplied = link_local.dup
    cluster = build(WakeOnLan, mac_address: "12345678ABCD", link_local_address: supplied)
    supplied[0] = 0_u8
    read(cluster, WakeOnLan::ATTR_LINK_LOCAL_ADDRESS).should eq(link_local)

    version = cluster.data_version
    expect_raises(ArgumentError) { cluster.mac_address = "ABCDEF123456" }
    leaked = cluster.link_local_address.as(Bytes)
    leaked[0] = 0_u8
    cluster.data_version.should eq(version)
    read(cluster, WakeOnLan::ATTR_MAC_ADDRESS).should eq("12345678ABCD")
    read(cluster, WakeOnLan::ATTR_LINK_LOCAL_ADDRESS).should eq(link_local)
  end
end
