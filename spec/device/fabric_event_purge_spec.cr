require "../spec_helper"
require "../../src/matter/device"

private class FabricEventSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Fabric Event Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8130_u16,
    discriminator: 3844_u16, pin: 20202097_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory
end

private class FabricEventFailAclStorage < Matter::Storage::Memory
  property fail_next_acl_id : String?

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::CLUSTERS && id == @fail_next_acl_id
      @fail_next_acl_id = nil
      raise Matter::StorageError.new("Injected ACL write failure")
    end
    super
  end
end

private def event_spec_fabric(index : UInt8, fabric_id : UInt64) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: fabric_id, fabric_index: index, node_id: 0x5678_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

describe Matter::Device do
  it "purges CASE sessions, ACL, and retained events on direct fabric table removal" do
    require_udp_sockets!
    device = FabricEventSpecDevice.new(storage: Matter::Storage::Memory.new, port: 0)
    fabric = event_spec_fabric(1_u8, 0x1001_u64)
    device.fabric_table.add_fabric(fabric).should be_true
    resumption_id = Bytes.new(Matter::Session::Case::RESUMPTION_ID_LENGTH, 0x21_u8)
    resumptions = Matter::Session::Case::ResumptionStore.new(device.fabric_table.backend)
    resumptions.save(Matter::Session::Case::ResumptionStore::Record.new(
      fabric_id: fabric.fabric_id, root_public_key: fabric.root_public_key,
      local_node_id: fabric.node_id, peer_node_id: 0x1234_u64,
      resumption_id: resumption_id, shared_secret: Bytes.new(32, 0x31_u8),
      peer_subject_ids: [0x1234_u64]))
    acl = device.access_control
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      subjects: [0x1234_u64], targets: nil, fabric_index: 1_u8)
    device.persistence.save_cluster(acl).should be_true
    session = Matter::Session::SecureContext.new(
      session_id: 111_u16, peer_session_id: 112_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 1_u8), decryption_key: Bytes.new(16, 2_u8),
      case_session: true, fabric_index: 1_u8,
      peer_node_id: Matter::DataType::NodeId.new(0x1234_u64))
    device.message_handler.sessions[session.session_id] = session
    device.message_handler.registry.add_subscription(Matter::Protocol::ActiveSubscription.new(
      subscription_id: 10_u32, min_interval: 1_u16, max_interval: 60_u16,
      peer: Socket::IPAddress.new("127.0.0.1", 5540), session: session,
      attribute_paths: [Matter::InteractionModel::AttributePath.new(
        endpoint: 0_u16, cluster: Matter::Cluster::AccessControl::CLUSTER_ID,
        attribute: Matter::Cluster::AccessControl::ATTR_ACL)],
      exchange_id: 7_u16))
    journal = device.node.event_journal
    journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(11_u32, nil), fabric_index: 1_u8)

    observed = [] of UInt8
    device.fabric_table.on_fabric_removed = ->(removed : Matter::Fabric) do
      observed << removed.fabric_index
      nil
    end
    device.fabric_table.remove_fabric(1_u8).should be_true
    observed.should eq([1_u8])
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x2001_u64)).should be_true
    resumptions.find_by_id(resumption_id).should be_nil
    device.message_handler.sessions.has_key?(111_u16).should be_false
    device.message_handler.active_subscriptions.has_key?(10_u32).should be_false
    acl.acl(1_u8).should be_empty
    journal.query([Matter::InteractionModel::EventPath.new], fabric_index: 1_u8)
      .select { |record| record.fabric_index == 1_u8 }.should be_empty
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end

  it "keeps a direct removal's index reserved when ACL cleanup cannot persist" do
    require_udp_sockets!
    storage = FabricEventFailAclStorage.new
    device = FabricEventSpecDevice.new(storage: storage, port: 0)
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x1001_u64)).should be_true
    storage.fail_next_acl_id = device.access_control.persistence_key

    expect_raises(Matter::StorageError, "Could not persist erased Access Control") do
      device.fabric_table.remove_fabric(1_u8)
    end
    device.fabric_table.get_fabric(1_u8).should_not be_nil
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x2001_u64)).should be_false
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end

  it "purges old fabric events before an ACL failure can expose them to a reused index" do
    require_udp_sockets!
    storage = FabricEventFailAclStorage.new
    device = FabricEventSpecDevice.new(storage: storage, port: 0)
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x1001_u64)).should be_true
    device.fabric_table.add_fabric(event_spec_fabric(2_u8, 0x1002_u64)).should be_true

    journal = device.node.event_journal
    before = journal.latest_event_number
    old = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(11_u32, nil), fabric_index: 1_u8)
    other = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(22_u32, nil), fabric_index: 2_u8)
    global = journal.record(0_u16, Matter::Cluster::GeneralDiagnostics::CLUSTER_ID,
      Matter::Cluster::GeneralDiagnostics::EVENT_BOOT_REASON,
      :critical, TLV::Any.new(33_u32, nil))
    path = [Matter::InteractionModel::EventPath.new]
    journal.query(path, after: before, fabric_index: 1_u8).map(&.event_number).should eq([old.event_number, global.event_number])

    storage.fail_next_acl_id = device.access_control.persistence_key
    expect_raises(Matter::StorageError, "Could not persist erased Access Control") do
      device.operational_credentials.credentials.remove_fabric(1_u8)
    end
    device.fabric_table.get_fabric(1_u8).should_not be_nil
    device.fabric_table.quarantined?(1_u8).should be_true
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x2001_u64)).should be_false
    journal.query(path, after: before, fabric_index: 1_u8).map(&.event_number).should eq([global.event_number])
    journal.query(path, after: before, fabric_index: 2_u8).map(&.event_number).should eq([other.event_number, global.event_number])
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end

  it "does not disclose retained fabric events after RemoveFabric reuses an index" do
    require_udp_sockets!
    device = FabricEventSpecDevice.new(storage: Matter::Storage::Memory.new, port: 0)
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x1001_u64)).should be_true
    device.fabric_table.add_fabric(event_spec_fabric(2_u8, 0x1002_u64)).should be_true

    journal = device.node.event_journal
    before = journal.latest_event_number
    old = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(11_u32, nil), fabric_index: 1_u8)
    other = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(22_u32, nil), fabric_index: 2_u8)
    global = journal.record(0_u16, Matter::Cluster::GeneralDiagnostics::CLUSTER_ID,
      Matter::Cluster::GeneralDiagnostics::EVENT_BOOT_REASON,
      :critical, TLV::Any.new(33_u32, nil))
    path = [Matter::InteractionModel::EventPath.new]
    journal.query(path, after: before, fabric_index: 1_u8).map(&.event_number).should eq([old.event_number, global.event_number])

    response = device.operational_credentials.handle_remove_fabric(
      Matter::Cluster::OperationalCredentials::RemoveFabricCommand.new(1_u8))
    response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok)
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x2001_u64)).should be_true
    fresh = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(44_u32, nil), fabric_index: 1_u8)

    fresh.event_number.should be > global.event_number
    journal.query(path, after: before, fabric_index: 1_u8).map(&.event_number).should eq([global.event_number, fresh.event_number])
    journal.query(path, after: before, fabric_index: 2_u8).map(&.event_number).should eq([other.event_number, global.event_number])
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end
end
