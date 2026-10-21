require "../spec_helper"
require "../../src/matter/controller"

private alias Icd = Matter::Cluster::IcdManagement

private class IcdRegistrationImClient < Matter::Controller::ImClient
  getter? invoked = false
  getter request : Icd::RegisterClientRequest? = nil
  getter unregister_request : Icd::UnregisterClientRequest? = nil
  property registration_status : Matter::InteractionModel::StatusCode? = nil
  property? wrong_status_path = false
  property on_register : Proc(Nil)?

  def initialize(client : Matter::Controller::Client, @store : Matter::Controller::IcdPeerStore,
                 @fabric : Matter::Controller::FabricInfo, @device_node_id : UInt64)
    super(client)
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty, timed_request : Bool = false,
             timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT) : Matter::InteractionModel::InvokeResponseMessage
    @invoked = true
    cluster_id.should eq(Icd::CLUSTER_ID)
    endpoint_id.should eq(0_u16)
    path = Matter::InteractionModel::CommandPath.new(endpoint_id, cluster_id,
      command_id == Icd::CMD_REGISTER_CLIENT ? Icd::CMD_REGISTER_CLIENT_RESPONSE : command_id)
    if command_id == Icd::CMD_REGISTER_CLIENT
      @request = Icd::RegisterClientRequest.from_tlv(TLV::Any.from_slice(fields))
      # The key must survive a lost response after the device accepted it.
      staged = @store.find_peer(@fabric.fabric_id, @fabric.root_public_key,
        @fabric.controller_node_id, @device_node_id)
      staged.should_not be_nil
      @on_register.try(&.call)
      if status_code = @registration_status
        status_path = Matter::InteractionModel::CommandPath.new(endpoint_id,
          cluster_id, wrong_status_path? ? Icd::CMD_UNREGISTER_CLIENT : command_id)
        status = Matter::InteractionModel::CommandStatusIB.new(status_path,
          Matter::InteractionModel::StatusIB.new(status_code.value))
        return Matter::InteractionModel::InvokeResponseMessage.new(
          invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
      end
      response = Icd::RegisterClientResponse.new(52_u32)
      data = Matter::InteractionModel::CommandDataIBTlv.new(path,
        response.to_tlv(nil))
      return Matter::InteractionModel::InvokeResponseMessage.new(
        invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_data: data)])
    end
    @unregister_request = Icd::UnregisterClientRequest.from_tlv(TLV::Any.from_slice(fields))
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(
        Matter::InteractionModel::StatusCode::Success.value))
    Matter::InteractionModel::InvokeResponseMessage.new(
      invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
  end
end

private def icd_registration_fabric : Matter::Controller::FabricInfo
  Matter::Controller::FabricInfo.new(
    fabric_id: 0x1111_u64, controller_node_id: 0x2222_u64,
    ipk_value: Bytes.new(16, 0x31_u8),
    root_cert: Bytes[0x15, 0x30, 0x01, 0x01],
    root_public_key: Bytes[0x04_u8] + Bytes.new(64, 0x32_u8),
    controller_noc: Bytes[0x15, 0x30, 0x01, 0x02],
    controller_private_key: Bytes.new(32, 0x33_u8),
    admin_vendor_id: 0xFFF1_u16)
end

private def icd_registration_session(case_session : Bool = true) : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16, peer_session_id: 2_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
    case_session: case_session, fabric_index: case_session ? 1_u8 : nil,
    local_node_id: Matter::DataType::NodeId.new(0x2222_u64),
    peer_node_id: Matter::DataType::NodeId.new(0x3333_u64))
end

describe Matter::Controller::IcdClient do
  it "registers over CASE with a durable key and typed RegisterClientResponse counter" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::IcdPeerStore.new(backend)
    client = Matter::Controller::Client.new(port: 0)
    fabric = icd_registration_fabric
    im = IcdRegistrationImClient.new(client, store, fabric, 0x3333_u64)
    icd = Matter::Controller::IcdClient.new(client, store, im)
    peer = Socket::IPAddress.new("::1", 5540)
    key = Bytes.new(16, 0x71_u8)
    registered = icd.register_client(fabric, 0x3333_u64,
      icd_registration_session, peer, key: key)
    im.request.as(Icd::RegisterClientRequest).key.should eq(key)
    im.request.as(Icd::RegisterClientRequest).check_in_node_id.should eq(fabric.controller_node_id)
    registered.counter_start.should eq(52_u32)
    Matter::Controller::IcdPeerStore.new(backend).find_peer(fabric.fabric_id,
      fabric.root_public_key, fabric.controller_node_id, 0x3333_u64)
      .as(Matter::Controller::IcdPeerStore::Record).key.should eq(key)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "rejects PASE and a different CASE peer before sending a registration" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::IcdPeerStore.new(backend)
    client = Matter::Controller::Client.new(port: 0)
    fabric = icd_registration_fabric
    im = IcdRegistrationImClient.new(client, store, fabric, 0x3333_u64)
    icd = Matter::Controller::IcdClient.new(client, store, im)
    peer = Socket::IPAddress.new("::1", 5540)
    expect_raises(Matter::SessionError) do
      icd.register_client(fabric, 0x3333_u64, icd_registration_session(false), peer)
    end
    expect_raises(Matter::SessionError) do
      icd.register_client(fabric, 0x4444_u64, icd_registration_session, peer)
    end
    im.invoked?.should be_false
    store.records.should be_empty
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "keeps an old key during rotation, then erases it after an authenticated new-key Check-In" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::IcdPeerStore.new(backend)
    client = Matter::Controller::Client.new(port: 0)
    fabric = icd_registration_fabric
    old_key = Bytes.new(16, 0x81_u8)
    new_key = Bytes.new(16, 0x82_u8)
    store.save(Matter::Controller::IcdPeerStore::Record.new(fabric.fabric_id,
      fabric.root_public_key, fabric.controller_node_id, 0x3333_u64,
      old_key, 25_u32, 30_u32))
    im = IcdRegistrationImClient.new(client, store, fabric, 0x3333_u64)
    icd = Matter::Controller::IcdClient.new(client, store, im)
    peer = Socket::IPAddress.new("::1", 5540)
    registered = icd.register_client(fabric, 0x3333_u64,
      icd_registration_session, peer, key: new_key)
    im.request.as(Icd::RegisterClientRequest).verification_key.should eq(old_key)
    registered.key.should eq(old_key)
    registered.pending_key.should eq(new_key)
    registered.pending_counter_start.should eq(52_u32)
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      new_key, 53_u32, 500_u16), peer).should be_true
    promoted = store.find_peer(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 0x3333_u64).as(Matter::Controller::IcdPeerStore::Record)
    promoted.key.should eq(new_key)
    promoted.counter_start.should eq(52_u32)
    promoted.pending_key.should be_nil
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "sends typed UnregisterClient over CASE and removes the persisted key on success" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::IcdPeerStore.new(backend)
    client = Matter::Controller::Client.new(port: 0)
    fabric = icd_registration_fabric
    key = Bytes.new(16, 0x91_u8)
    store.save(Matter::Controller::IcdPeerStore::Record.new(fabric.fabric_id,
      fabric.root_public_key, fabric.controller_node_id, 0x3333_u64, key))
    im = IcdRegistrationImClient.new(client, store, fabric, 0x3333_u64)
    icd = Matter::Controller::IcdClient.new(client, store, im)
    icd.unregister_client(fabric, 0x3333_u64, icd_registration_session,
      Socket::IPAddress.new("::1", 5540))
    im.unregister_request.as(Icd::UnregisterClientRequest).verification_key.should eq(key)
    store.records.should be_empty
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "rolls back a rejected registration without keeping an unaccepted key" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::IcdPeerStore.new(backend)
    client = Matter::Controller::Client.new(port: 0)
    fabric = icd_registration_fabric
    im = IcdRegistrationImClient.new(client, store, fabric, 0x3333_u64)
    im.registration_status = Matter::InteractionModel::StatusCode::ResourceExhausted
    icd = Matter::Controller::IcdClient.new(client, store, im)
    expect_raises(Matter::ClusterError) do
      icd.register_client(fabric, 0x3333_u64, icd_registration_session,
        Socket::IPAddress.new("::1", 5540), key: Bytes.new(16, 0xA1_u8))
    end
    store.records.should be_empty
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "does not treat a status for another command as a registration rejection" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::IcdPeerStore.new(backend)
    client = Matter::Controller::Client.new(port: 0)
    fabric = icd_registration_fabric
    im = IcdRegistrationImClient.new(client, store, fabric, 0x3333_u64)
    im.registration_status = Matter::InteractionModel::StatusCode::ResourceExhausted
    im.wrong_status_path = true
    icd = Matter::Controller::IcdClient.new(client, store, im)
    expect_raises(Matter::ProtocolError) do
      icd.register_client(fabric, 0x3333_u64, icd_registration_session,
        Socket::IPAddress.new("::1", 5540), key: Bytes.new(16, 0xA2_u8))
    end
    # An unrelated status leaves the candidate available for a Check-In if
    # the ICD accepted the command but its actual response was lost.
    store.records.size.should eq(1)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "keeps the accepted Check-In counter when it arrives before RegisterClientResponse" do
    backend = Matter::Storage::Memory.new
    store = Matter::Controller::IcdPeerStore.new(backend)
    client = Matter::Controller::Client.new(port: 0)
    fabric = icd_registration_fabric
    im = IcdRegistrationImClient.new(client, store, fabric, 0x3333_u64)
    icd = Matter::Controller::IcdClient.new(client, store, im)
    key = Bytes.new(16, 0xB1_u8)
    peer = Socket::IPAddress.new("::1", 5540)
    im.on_register = -> do
      icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
        key, 53_u32, 1_000_u16), peer).should be_true
      nil
    end
    registered = icd.register_client(fabric, 0x3333_u64,
      icd_registration_session, peer, key: key)
    registered.counter_start.should eq(52_u32)
    registered.last_counter.should eq(53_u32)
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      key, 53_u32, 1_000_u16), peer).should be_true
    store.find_peer(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 0x3333_u64)
      .as(Matter::Controller::IcdPeerStore::Record).last_counter.should eq(53_u32)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end
end
