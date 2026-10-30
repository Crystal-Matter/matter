require "../spec_helper"

require "../../src/matter/cluster/groups"

describe Matter::Cluster::Groups do
  it "persists group table" do
    cluster = build(Matter::Cluster::Groups)

    # Add group 0x0001 named "Test"
    cluster.add_group(Matter::Cluster::Groups::AddGroupRequest.new(Matter::DataType::GroupId.new(1_u16), "Test"))

    cluster.group_count.should eq(1)
    cluster.member_of?(1_u16).should be_true

    cluster.data_version = 7_u32
    document = cluster.save_state.as(Matter::Storage::Document)
    document["groups"].should eq(Matter::Storage::Document{"1" => "Test"})
    document["data_version"].should eq(7_i64)

    cluster2 = build(Matter::Cluster::Groups)
    cluster2.restore_state(document)

    cluster2.group_count.should eq(1)
    cluster2.groups[1_u16].should eq("Test")
    cluster2.data_version.should eq(7_u32)
  end
end
