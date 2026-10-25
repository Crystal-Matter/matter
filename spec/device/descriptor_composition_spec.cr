require "../spec_helper"
require "../../src/matter/device"

private alias Descriptor = Matter::Cluster::Descriptor

private class ComposedDescriptorDevice < Matter::Device
  identity vendor: "Crystal", product: "Descriptor composition test",
    vendor_id: 0xFFF1_u16, product_id: 0x9231_u16,
    discriminator: 3840_u16, pin: 20202021_u32,
    device_type: Matter::DeviceType::AGGREGATOR
  storage :memory

  endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
  end

  endpoint 2, device_type: Matter::DeviceType::ON_OFF_LIGHT,
    parent_endpoint: 1_u16,
    tag_list: [Descriptor::SemanticTag.new(nil, 1_u8, 1_u8)] do
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
    cluster Matter::Cluster::OnOff
  end

  endpoint_template :dynamic_light, device_type: Matter::DeviceType::ON_OFF_LIGHT,
    tag_list: [Descriptor::SemanticTag.new(nil, 1_u8, 2_u8)] do
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
    cluster Matter::Cluster::OnOff
  end
end

private class InvalidParentDescriptorDevice < Matter::Device
  identity vendor: "Crystal", product: "Invalid parent test",
    vendor_id: 0xFFF1_u16, product_id: 0x9232_u16,
    discriminator: 3841_u16, pin: 20202022_u32,
    device_type: Matter::DeviceType::AGGREGATOR
  storage :memory

  endpoint 1, device_type: Matter::DeviceType::AGGREGATOR, parent_endpoint: 7_u16 do
    cluster Matter::Cluster::Identify
  end
end

private class CyclicDescriptorDevice < Matter::Device
  identity vendor: "Crystal", product: "Cyclic parent test",
    vendor_id: 0xFFF1_u16, product_id: 0x9233_u16,
    discriminator: 3842_u16, pin: 20202023_u32,
    device_type: Matter::DeviceType::AGGREGATOR
  storage :memory

  endpoint 1, device_type: Matter::DeviceType::AGGREGATOR, parent_endpoint: 2_u16 do
    cluster Matter::Cluster::Identify
  end
  endpoint 2, device_type: Matter::DeviceType::AGGREGATOR, parent_endpoint: 1_u16 do
    cluster Matter::Cluster::Identify
  end
end

describe "Descriptor endpoint composition" do
  it "exposes a parent tree and a typed TagList while retaining root's full family" do
    device = ComposedDescriptorDevice.new(port: 0)
    root = device.node.endpoint!(0_u16).descriptor
    parent = device.node.endpoint!(1_u16).descriptor
    child = device.node.endpoint!(2_u16).descriptor

    root.parts_list.should eq([1_u16, 2_u16])
    parent.parts_list.should eq([2_u16])
    child.parts_list.should be_empty
    child.feature_map.tag_list?.should be_true
    child.tag_list.should eq([Descriptor::SemanticTag.new(nil, 1_u8, 1_u8)])
    Descriptor::SemanticTag.from_tlv(child.tag_list.first.to_tlv).should eq(child.tag_list.first)
  ensure
    device.try(&.transport.close)
  end

  it "updates both parent and root when dynamic descendants are added and removed" do
    device = ComposedDescriptorDevice.new(port: 0)
    device.add_endpoint(3_u16, Matter::DeviceType::ON_OFF_LIGHT, [
      Matter::Cluster::Identify.new(endpoint(3_u16)),
      Matter::Cluster::Groups.new(endpoint(3_u16)),
      Matter::Cluster::OnOff.new(endpoint(3_u16)),
    ] of Matter::Cluster::Base, parent_endpoint: 1_u16).should be_true
    device.node.endpoint!(1_u16).descriptor.parts_list.should eq([2_u16, 3_u16])
    device.node.endpoint!(0_u16).descriptor.parts_list.should eq([1_u16, 2_u16, 3_u16])
    expect_raises(Matter::ConfigurationError) { device.remove_endpoint(1_u16) }
    device.remove_endpoint(3_u16).should be_true
    device.node.endpoint!(1_u16).descriptor.parts_list.should eq([2_u16])
  ensure
    device.try(&.transport.close)
  end

  it "keeps a nonroot Aggregator's full family through nested children" do
    device = ComposedDescriptorDevice.new(port: 0)
    device.add_endpoint(3_u16, Matter::DeviceType::AGGREGATOR,
      [] of Matter::Cluster::Base, parent_endpoint: 1_u16).should be_true
    device.add_endpoint(4_u16, Matter::DeviceType::AGGREGATOR,
      [] of Matter::Cluster::Base, parent_endpoint: 3_u16).should be_true
    device.node.endpoint!(1_u16).descriptor.parts_list.should eq([2_u16, 3_u16, 4_u16])
    device.node.endpoint!(2_u16).descriptor.parts_list.should be_empty
    device.node.endpoint!(3_u16).descriptor.parts_list.should eq([4_u16])
  ensure
    device.try(&.transport.close)
  end

  it "restores the parent of a templated dynamic endpoint" do
    storage = Matter::Storage::Memory.new
    device = ComposedDescriptorDevice.new(storage, port: 0)
    device.add_endpoint(:dynamic_light, endpoint_id: 3_u16, parent_endpoint: 1_u16)
    device.node.endpoint!(1_u16).descriptor.parts_list.should eq([2_u16, 3_u16])
    device.transport.close

    restored = ComposedDescriptorDevice.new(storage, port: 0)
    restored.node.endpoint!(3_u16).parent_endpoint_id.should eq(1_u16)
    restored.node.endpoint!(1_u16).descriptor.parts_list.should eq([2_u16, 3_u16])
    restored.node.endpoint!(3_u16).descriptor.tag_list.should eq([Descriptor::SemanticTag.new(nil, 1_u8, 2_u8)])
  ensure
    restored.try(&.transport.close)
    device.try(&.transport.close)
  end

  it "rejects nonexistent and cyclic static parents" do
    expect_raises(Matter::ConfigurationError, /parent 7 does not exist/) do
      InvalidParentDescriptorDevice.new(port: 0)
    end
    expect_raises(Matter::ConfigurationError, /parent cycle/) do
      CyclicDescriptorDevice.new(port: 0)
    end
  end

  it "rejects a dynamic parent that does not exist before publishing the child" do
    device = ComposedDescriptorDevice.new(port: 0)
    expect_raises(Matter::ConfigurationError, /parent 7 does not exist/) do
      device.add_endpoint(3_u16, Matter::DeviceType::AGGREGATOR,
        [] of Matter::Cluster::Base, parent_endpoint: 7_u16)
    end
    device.node.has_endpoint?(3_u16).should be_false
    device.node.endpoint!(0_u16).descriptor.parts_list.should eq([1_u16, 2_u16])
  ensure
    device.try(&.transport.close)
  end

  it "guards TagList size and manufacturer tags" do
    descriptor = Descriptor.new(endpoint(5_u16))
    descriptor.get_attribute_metadata(Descriptor::ATTR_TAG_LIST).should be_nil
    expect_raises(Matter::ConfigurationError) do
      descriptor.configure_tag_list(Array.new(7) { |index| Descriptor::SemanticTag.new(nil, 1_u8, index.to_u8) })
    end
    expect_raises(Matter::ConfigurationError) do
      descriptor.configure_tag_list([Descriptor::SemanticTag.new(0xFFF1_u16, 1_u8, 1_u8)])
    end
    expect_raises(Matter::ConfigurationError) do
      descriptor.configure_tag_list([Descriptor::SemanticTag.new(nil, 1_u8, 1_u8, "standard")])
    end
    descriptor.configure_tag_list([Descriptor::SemanticTag.new(nil, 1_u8, 1_u8)])
    descriptor.get_attribute_metadata(Descriptor::ATTR_TAG_LIST).should_not be_nil
  end
end
