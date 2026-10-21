require "../spec_helper"
require "../../src/matter/cluster/boolean_state"
require "../../src/matter/cluster/basic_information"
require "../../src/matter/cluster/color_control"
require "../../src/matter/cluster/descriptor"
require "../../src/matter/cluster/door_lock"
require "../../src/matter/cluster/group_key_management"
require "../../src/matter/cluster/groups"
require "../../src/matter/cluster/icd_management"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/level_control"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/window_covering"

private alias Base = Matter::Cluster::Base

# The ClusterRevision global attribute is read straight from each cluster's
# `CLUSTER_REVISION` constant, resolved in the subclass scope by `Base`'s
# `macro inherited`. One example per cluster whose revision is not the default.
describe "Cluster::Base ClusterRevision" do
  it "reports the Base default for a cluster that does not set CLUSTER_REVISION" do
    cluster = build(Matter::Cluster::BooleanState)

    Base::CLUSTER_REVISION.should eq(1_u16)
    cluster.cluster_revision.should eq(Base::CLUSTER_REVISION)
    read(cluster, Base::GLOBAL_CLUSTER_REVISION).should eq(Base::CLUSTER_REVISION)
  end

  {% for pair in [
                   {Matter::Cluster::BasicInformation, 6_u16},
                   {Matter::Cluster::ColorControl, 7_u16},
                   {Matter::Cluster::Descriptor, 3_u16},
                   {Matter::Cluster::DoorLock, 9_u16},
                   {Matter::Cluster::GroupKeyManagement, 2_u16},
                   {Matter::Cluster::Groups, 4_u16},
                   {Matter::Cluster::IcdManagement, 3_u16},
                   {Matter::Cluster::Identify, 6_u16},
                   {Matter::Cluster::LevelControl, 6_u16},
                   {Matter::Cluster::OnOff, 6_u16},
                   {Matter::Cluster::WindowCovering, 6_u16},
                 ] %}
    it "reports {{ pair[0] }}::CLUSTER_REVISION ({{ pair[1] }})" do
      cluster = build({{ pair[0] }})

      {{ pair[0] }}::CLUSTER_REVISION.should eq({{ pair[1] }})
      cluster.cluster_revision.should eq({{ pair[0] }}::CLUSTER_REVISION)
      read(cluster, Base::GLOBAL_CLUSTER_REVISION).should eq({{ pair[0] }}::CLUSTER_REVISION)
    end
  {% end %}
end
