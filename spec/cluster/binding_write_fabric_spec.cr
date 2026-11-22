require "../spec_helper"
require "../../src/matter/cluster/binding"

private alias WireBinding = Matter::Cluster::Binding
private alias WireBindingStatus = Matter::InteractionModel::StatusCode

private def binding_value : TLV::Any
  TLV::Serializable.serialize_value([WireBinding::Target.new(node: 2_u64, endpoint: 1_u16)], nil)
end

describe "Binding fabric-scoped wire writes" do
  [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |invalid_fabric|
    it "rejects reserved fabric #{invalid_fabric} before hooks or state changes" do
      cluster = WireBinding.new(endpoint(1))
      cluster.request_is_case_session = true
      cluster.request_fabric_index = invalid_fabric
      callbacks = 0
      cluster.on_before_write = ->(_attribute : UInt32) { callbacks += 1; nil }
      cluster.on_version_changed = -> { callbacks += 1; nil }
      before_state = cluster.save_state
      before_version = cluster.data_version

      cluster.write_attribute(WireBinding::ATTR_BINDING, binding_value).status.should eq(WireBindingStatus::UnsupportedAccess)

      cluster.save_state.should eq(before_state)
      cluster.data_version.should eq(before_version)
      callbacks.should eq(0)
    end
  end

  it "rejects non-CASE, non-Group writes with a supplied valid fabric" do
    cluster = WireBinding.new(endpoint(1))
    cluster.request_fabric_index = Matter::Fabric::MIN_FABRIC_INDEX
    callbacks = 0
    cluster.on_before_write = ->(_attribute : UInt32) { callbacks += 1; nil }
    cluster.on_version_changed = -> { callbacks += 1; nil }
    before_state = cluster.save_state
    before_version = cluster.data_version

    cluster.write_attribute(WireBinding::ATTR_BINDING, binding_value).status.should eq(WireBindingStatus::UnsupportedAccess)

    cluster.save_state.should eq(before_state)
    cluster.data_version.should eq(before_version)
    callbacks.should eq(0)
  end

  it "keeps Group-authenticated Manage writes eligible" do
    cluster = WireBinding.new(endpoint(1))
    cluster.request_auth_mode = Matter::InteractionModel::EntryAuthMode::Group
    cluster.request_fabric_index = Matter::Fabric::MIN_FABRIC_INDEX

    cluster.write_attribute(WireBinding::ATTR_BINDING, binding_value).status.should eq(WireBindingStatus::Success)
    cluster.binding.map(&.fabric_index).should eq([Matter::Fabric::MIN_FABRIC_INDEX])
  end

  [Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX].each do |fabric|
    it "accepts CASE writes for fabric #{fabric}" do
      cluster = WireBinding.new(endpoint(1))
      cluster.request_is_case_session = true
      cluster.request_fabric_index = fabric

      cluster.write_attribute(WireBinding::ATTR_BINDING, binding_value).status.should eq(WireBindingStatus::Success)
      cluster.binding.map(&.fabric_index).should eq([fabric])
    end
  end
end
