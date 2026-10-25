require "../spec_helper"
require "../../src/matter/device"
require "../../src/matter/cluster/binding"
require "../../src/matter/cluster/identify"

private class BindingRemovalDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Binding Removal Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8127_u16,
    discriminator: 3845_u16, pin: 20202098_u32,
    device_type: Matter::DeviceType::ON_OFF_LIGHT_SWITCH
  storage :memory

  endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT_SWITCH do
    cluster Matter::Cluster::Identify, identify_type: :none
    cluster Matter::Cluster::Binding, as: :bindings
  end
end

private class BindingWriteFailureMemory < Matter::Storage::Memory
  property? fail_binding_write : Bool = false

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_binding_write && collection == Matter::Storage::Collections::CLUSTERS &&
       id == Matter::Cluster::Base.persistence_key(1_u16, Matter::Cluster::Binding::CLUSTER_ID)
      raise Matter::StorageError.new("Injected Binding write failure")
    end
    super
  end
end

private def binding_removal_fabric(index : UInt8, id : UInt64) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: id, fabric_index: index, node_id: id,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

private def read_bindings(cluster : Matter::Cluster::Binding, index : UInt8) : Array(Matter::Cluster::Binding::Target)
  cluster.with_request_context do
    cluster.request_fabric_index = index
    value = cluster.read_attribute(Matter::Cluster::Binding::ATTR_BINDING, index).as(TLV::Any)
    Array(Matter::Cluster::Binding::Target).from_tlv(value.to_slice)
  end
end

describe "Binding fabric removal" do
  it "preserves other fabrics and does not bump the version when nothing was removed" do
    cluster = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_fabric_index = 1_u8
    cluster.binding = [Matter::Cluster::Binding::Target.new(node: 0x111_u64, endpoint: 1_u16)]
    cluster.request_fabric_index = 2_u8
    cluster.binding = [Matter::Cluster::Binding::Target.new(group: 2_u16)]
    initial_version = cluster.data_version

    cluster.remove_fabric(3_u8).should be_false
    cluster.data_version.should eq(initial_version)
    cluster.remove_fabric(1_u8).should be_true
    cluster.data_version.should eq(initial_version + 1)
    read_bindings(cluster, 1_u8).should be_empty
    read_bindings(cluster, 2_u8).map(&.group).should eq([2_u16])

    restored = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    read_bindings(restored, 1_u8).should be_empty
    read_bindings(restored, 2_u8).map(&.group).should eq([2_u16])
  end

  it "does not disclose removed bindings when an unrelated fabric reuses the index" do
    storage = Matter::Storage::Memory.new
    device = BindingRemovalDevice.new(storage: storage, port: 0)
    device.fabric_table.add_fabric(binding_removal_fabric(1_u8, 0x100_u64)).should be_true
    device.fabric_table.add_fabric(binding_removal_fabric(2_u8, 0x200_u64)).should be_true
    cluster = device.bindings
    cluster.request_fabric_index = 1_u8
    cluster.binding = [Matter::Cluster::Binding::Target.new(node: 0x111_u64, endpoint: 1_u16)]
    cluster.request_fabric_index = 2_u8
    cluster.binding = [Matter::Cluster::Binding::Target.new(group: 2_u16)]
    device.persistence.save_cluster(cluster).should be_true

    device.operational_credentials.credentials.remove_fabric(1_u8).ok?.should be_true
    read_bindings(cluster, 2_u8).map(&.group).should eq([2_u16])
    device.fabric_table.add_fabric(binding_removal_fabric(1_u8, 0x300_u64)).should be_true
    read_bindings(cluster, 1_u8).should be_empty

    saved = storage.read(Matter::Storage::Collections::CLUSTERS, cluster.persistence_key).as(Matter::Storage::Document)
    restored = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(saved)
    read_bindings(restored, 1_u8).should be_empty
    read_bindings(restored, 2_u8).map(&.group).should eq([2_u16])
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end

  it "repairs orphaned Binding state on boot before an index is reused" do
    storage = Matter::Storage::Memory.new
    first = BindingRemovalDevice.new(storage: storage, port: 0)
    first.fabric_table.add_fabric(binding_removal_fabric(1_u8, 0x100_u64)).should be_true
    first.fabric_table.add_fabric(binding_removal_fabric(2_u8, 0x200_u64)).should be_true
    first.bindings.request_fabric_index = 1_u8
    first.bindings.binding = [Matter::Cluster::Binding::Target.new(node: 0x111_u64, endpoint: 1_u16)]
    first.bindings.request_fabric_index = 2_u8
    first.bindings.binding = [Matter::Cluster::Binding::Target.new(group: 2_u16)]
    first.persistence.save_cluster(first.bindings).should be_true
    # Model a crash after the fabric document was deleted, before the callback.
    first.fabric_table.remove_fabric(1_u8).should be_true
    first.message_handler.close
    first.persistence.close
    first.transport.close

    second = BindingRemovalDevice.new(storage: storage, port: 0)
    second.fabric_table.add_fabric(binding_removal_fabric(1_u8, 0x300_u64)).should be_true
    read_bindings(second.bindings, 1_u8).should be_empty
    read_bindings(second.bindings, 2_u8).map(&.group).should eq([2_u16])
    saved = storage.read(Matter::Storage::Collections::CLUSTERS, second.bindings.persistence_key).as(Matter::Storage::Document)
    restored = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(saved)
    read_bindings(restored, 1_u8).should be_empty
  ensure
    if second
      second.message_handler.close
      second.persistence.close
      second.transport.close
    end
    if first
      first.message_handler.close
      first.persistence.close
      first.transport.close
    end
  end

  it "keeps the fabric index reserved until a failed Binding erase is durable" do
    storage = BindingWriteFailureMemory.new
    first = BindingRemovalDevice.new(storage: storage, port: 0)
    first.fabric_table.add_fabric(binding_removal_fabric(1_u8, 0x100_u64)).should be_true
    first.bindings.request_fabric_index = 1_u8
    first.bindings.binding = [Matter::Cluster::Binding::Target.new(node: 0x111_u64, endpoint: 1_u16)]
    first.persistence.save_cluster(first.bindings).should be_true

    storage.fail_binding_write = true
    expect_raises(Matter::StorageError, /Could not persist erased Binding/) do
      first.operational_credentials.credentials.remove_fabric(1_u8)
    end
    first.fabric_table.get_fabric(1_u8).should_not be_nil
    first.fabric_table.add_fabric(binding_removal_fabric(1_u8, 0x300_u64)).should be_false
    persisted = storage.read(Matter::Storage::Collections::CLUSTERS, first.bindings.persistence_key).as(Matter::Storage::Document)
    old_state = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    old_state.restore_state(persisted)
    read_bindings(old_state, 1_u8).map(&.node).should eq([0x111_u64])

    # The first erase changed RAM; retry must still write an empty document.
    storage.fail_binding_write = false
    first.operational_credentials.credentials.remove_fabric(1_u8).ok?.should be_true
    first.fabric_table.add_fabric(binding_removal_fabric(1_u8, 0x300_u64)).should be_true
    first.message_handler.close
    first.persistence.close
    first.transport.close

    second = BindingRemovalDevice.new(storage: storage, port: 0)
    read_bindings(second.bindings, 1_u8).should be_empty
  ensure
    if second
      second.message_handler.close
      second.persistence.close
      second.transport.close
    end
    if first
      first.message_handler.close
      first.persistence.close
      first.transport.close
    end
  end
end
