require "../spec_helper"

describe "Matter 1.6 global EventList" do
  it "reports declared event IDs and advertises EventList on an eventful cluster" do
    cluster = build(Matter::Cluster::OperationalState)
    read_tlv(cluster, 0xFFFA_u32).as_list.map(&.as_u32).should eq([
      Matter::Cluster::OperationalState::EVENT_OPERATIONAL_ERROR,
      Matter::Cluster::OperationalState::EVENT_OPERATION_COMPLETION,
    ])
    attribute_ids(cluster).should contain(0xFFFA_u32)
  end

  it "reports an empty EventList and advertises it on an eventless cluster" do
    cluster = build(Matter::Cluster::OnOff)
    read_tlv(cluster, 0xFFFA_u32).as_list.should be_empty
    attribute_ids(cluster).should contain(0xFFFA_u32)
  end
end
