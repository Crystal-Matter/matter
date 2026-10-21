require "../spec_helper"
require "../../src/matter/cluster/level_control"

describe "LevelControl bound attribute declarations" do
  it "always declares MinLevel and MaxLevel as fixed readable attributes" do
    cluster = build(Matter::Cluster::LevelControl)
    min_level = cluster.attributes.find { |attribute| attribute.id.id == Matter::Cluster::LevelControl::ATTR_MIN_LEVEL }
    max_level = cluster.attributes.find { |attribute| attribute.id.id == Matter::Cluster::LevelControl::ATTR_MAX_LEVEL }

    min_level.should_not be_nil
    max_level.should_not be_nil
    min_level = min_level.as(Matter::Cluster::AttributeMetadata)
    max_level = max_level.as(Matter::Cluster::AttributeMetadata)
    min_level.optional?.should be_false
    max_level.optional?.should be_false
    min_level.fixed?.should be_true
    max_level.fixed?.should be_true
    read(cluster, Matter::Cluster::LevelControl::ATTR_MIN_LEVEL).should eq(cluster.min_level)
    read(cluster, Matter::Cluster::LevelControl::ATTR_MAX_LEVEL).should eq(cluster.max_level)
  end
end
