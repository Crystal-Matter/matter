require "../spec_helper"
require "../../src/matter/cluster/bridged_device_basic_information"

alias BridgedInfoUnderTest = Matter::Cluster::BridgedDeviceBasicInformation

describe Matter::Cluster::BridgedDeviceBasicInformation do
  it "requires a provisioned nonempty UniqueID within the Matter length bound" do
    expect_raises(ArgumentError, /unique_id/) { build(BridgedInfoUnderTest) }
    expect_raises(ArgumentError, /unique_id/) { build(BridgedInfoUnderTest, unique_id: "") }
    expect_raises(ArgumentError, /unique_id/) { build(BridgedInfoUnderTest, unique_id: "x" * 33) }
    build(BridgedInfoUnderTest, unique_id: "bridge-1").unique_id.should eq("bridge-1")
  end

  it "always advertises the fixed UniqueID attribute and reads its value" do
    cluster = build(BridgedInfoUnderTest, unique_id: "bridge-1")
    metadata = cluster.attributes.find { |entry| entry.id.id == BridgedInfoUnderTest::ATTR_UNIQUE_ID }
    metadata.try(&.optional?).should be_false
    metadata.try(&.fixed?).should be_true
    read(cluster, BridgedInfoUnderTest::ATTR_UNIQUE_ID).should eq("bridge-1")
  end
end
