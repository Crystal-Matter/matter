require "../spec_helper"
require "../../src/matter/device/ota_requestor_lifecycle"

private alias OtaLifecycle = Matter::Device::OtaRequestorLifecycle
private alias OtaProvider = Matter::Cluster::OtaProvider
private alias OtaRequestor = Matter::Cluster::OtaRequestor

private class OtaLifecycleClientFake
  getter queries = 0
  getter applies = 0
  getter notifications = 0
  property staged : Matter::Controller::OtaRequestorClient::StagedUpdate?
  property approval = OtaProvider::ApplyUpdateResponse.new(OtaProvider::ApplyAction::Proceed, 0_u32)
  property? fail_download = false
  property? fail_notification = false
  property notify_entered : Channel(Nil)?
  property notify_release : Channel(Nil)?

  def initialize(@staged)
  end

  def query_and_download(session, address, endpoint, vendor_id, product_id, version, sink)
    @queries += 1
    raise Matter::ProtocolError.new("download failed") if fail_download?
    sink.write("image".to_slice)
    @staged
  end

  def request_apply(session, address, endpoint, staged)
    @applies += 1
    @approval
  end

  def notify_applied(session, address, endpoint, token, version, product_id,
                     publish_result : Bool = true)
    @notifications += 1
    @notify_entered.try(&.send(nil))
    @notify_release.try(&.receive)
    raise Matter::ProtocolError.new("provider unreachable") if fail_notification?
  end
end

private class OtaFailDeleteMemory < Matter::Storage::Memory
  property? fail_pending_delete = false

  def delete(collection : String, id : String) : Nil
    if @fail_pending_delete && collection == Matter::Storage::Collections::APP &&
       id == OtaLifecycle::PENDING_ID
      @fail_pending_delete = false
      raise Matter::StorageError.new("injected pending delete failure")
    end
    super
  end
end

private class OtaFailFabricDeleteMemory < Matter::Storage::Memory
  property? fail_fabric_delete = false

  def delete(collection : String, id : String) : Nil
    if @fail_fabric_delete && collection == Matter::FabricTable::COLLECTION
      @fail_fabric_delete = false
      raise Matter::StorageError.new("injected fabric delete failure")
    end
    super
  end
end

private class OtaFailMarkerWriteMemory < Matter::Storage::Memory
  property? fail_event_marker = false

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_event_marker && collection == Matter::Storage::Collections::APP &&
       id == OtaLifecycle::PENDING_ID && document["event_published"]? == true
      @fail_event_marker = false
      raise Matter::StorageError.new("injected event marker write failure")
    end
    super
  end
end

private def ota_lifecycle_session(fabric : UInt8 = 1_u8,
                                  node : UInt64 = 0x1234_u64) : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16, peer_session_id: 2_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 0x11_u8),
    decryption_key: Bytes.new(16, 0x22_u8),
    peer_node_id: Matter::DataType::NodeId.new(node),
    case_session: true, fabric_index: fabric)
end

private def ota_lifecycle_staged
  header = Matter::Protocol::OtaImage::Header.new
  header.software_version = 11_u32
  Matter::Controller::OtaRequestorClient::StagedUpdate.new(
    header, Bytes[1, 2, 3, 4, 5, 6, 7, 8], "bdx://0000000000001234/fw", 5_u64)
end

private def ota_lifecycle_service(client : OtaLifecycleClientFake,
                                  store : Matter::Storage::Backend,
                                  cluster : OtaRequestor,
                                  version : UInt32 = 10_u32,
                                  peer_fabric : UInt8 = 1_u8,
                                  installed : Array(UInt32) = [] of UInt32,
                                  fail_install : Bool = false)
  resolver = ->(_fabric : UInt8, node : UInt64) do
    OtaLifecycle::Peer.new(ota_lifecycle_session(peer_fabric, node),
      Socket::IPAddress.new("127.0.0.1", 5540)).as(OtaLifecycle::Peer?)
  end
  sink = -> { IO::Memory.new.as(IO) }
  installer = ->(_image : IO, header : Matter::Protocol::OtaImage::Header) do
    raise Matter::ProtocolError.new("installer failed") if fail_install
    installed << header.software_version
    nil
  end
  current = -> { version }
  store.open unless store.open?
  table = Matter::FabricTable.new(store)
  unless table.get_fabric(1_u8)
    table.add_fabric(Matter::Fabric.new(
      fabric_id: 1_u64, fabric_index: 1_u8, node_id: 0x1_u64,
      root_public_key: Random::Secure.random_bytes(65),
      operational_cert: Random::Secure.random_bytes(200),
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: Random::Secure.random_bytes(16)))
  end
  unless table.get_fabric(2_u8)
    table.add_fabric(Matter::Fabric.new(
      fabric_id: 2_u64, fabric_index: 2_u8, node_id: 0x1_u64,
      root_public_key: Random::Secure.random_bytes(65),
      operational_cert: Random::Secure.random_bytes(200),
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: Random::Secure.random_bytes(16)))
  end
  OtaLifecycle.new(cluster, client, store, table, resolver, sink, installer,
    0xFFF1_u16, 0x8001_u16, current)
end

describe "device OTA Requestor lifecycle" do
  it "starts an announced provider only after CASE authentication" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    client = OtaLifecycleClientFake.new(nil)
    service = ota_lifecycle_service(client, store, cluster)
    service.attach
    cluster.update_possible?.should be_true
    request = OtaRequestor::AnnounceProviderRequest.new(0x1234_u64,
      0xFFF1_u16, OtaRequestor::AnnouncementReason::UpdateAvailable, 0_u16)

    cluster.invoke_command(OtaRequestor::CMD_ANNOUNCE_OTA_PROVIDER,
      request.to_tlv(nil)).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    Fiber.yield
    client.queries.should eq(0)

    cluster.request_peer_node_id = 0x9999_u64
    cluster.invoke_command(OtaRequestor::CMD_ANNOUNCE_OTA_PROVIDER,
      request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    Fiber.yield
    client.queries.should eq(1)
  end

  it "queries only the default provider selected for its fabric" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    cluster.default_ota_providers = [
      OtaRequestor::ProviderLocation.new(0xAAAA_u64, 0_u16, 1_u8),
      OtaRequestor::ProviderLocation.new(0x1234_u64, 1_u16, 2_u8),
    ]
    client = OtaLifecycleClientFake.new(nil)
    service = ota_lifecycle_service(client, store, cluster, peer_fabric: 2_u8)

    service.process_default(2_u8).should eq(OtaLifecycle::Result::NoUpdate)
    client.queries.should eq(1)
    expect_raises(Matter::SessionError) { service.process_default(1_u8) }
    client.queries.should eq(1)
  end

  it "rejects a resolver that returns a CASE peer from another fabric before querying" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, cluster, peer_fabric: 2_u8)

    expect_raises(Matter::SessionError) { service.process_provider(1_u8, 0x1234_u64, 0_u16) }
    client.queries.should eq(0)
    service.pending_notification.should be_nil
  end

  it "does not install while a provider delays application or consent delays query" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    installed = [] of UInt32
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    client.approval = OtaProvider::ApplyUpdateResponse.new(OtaProvider::ApplyAction::Proceed, 30_u32)
    service = ota_lifecycle_service(client, store, cluster, installed: installed)
    service.process_provider(1_u8, 0x1234_u64, 0_u16).should eq(OtaLifecycle::Result::Delayed)
    installed.should be_empty
    service.pending_notification.should be_nil
    service.next_apply_at.should_not be_nil
    service.resume_delayed_apply.should eq(OtaLifecycle::Result::Delayed)

    consent_cluster = OtaRequestor.new
    consent_client = OtaLifecycleClientFake.new(nil)
    consent_cluster.transition_to(OtaRequestor::UpdateState::DelayedOnUserConsent,
      OtaRequestor::ChangeReason::Unknown)
    consent_service = ota_lifecycle_service(consent_client, Matter::Storage::Memory.new,
      consent_cluster, installed: installed)
    consent_service.process_provider(1_u8, 0x1234_u64, 0_u16).should eq(OtaLifecycle::Result::Delayed)
    consent_client.applies.should eq(0)
    installed.should be_empty
  end

  it "retains a staged image across AwaitNextAction and resumes without another query" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    installed = [] of UInt32
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    client.approval = OtaProvider::ApplyUpdateResponse.new(OtaProvider::ApplyAction::AwaitNextAction, 0_u32)
    service = ota_lifecycle_service(client, store, cluster, installed: installed)

    service.process_provider(1_u8, 0x1234_u64, 0_u16).should eq(OtaLifecycle::Result::Delayed)
    client.queries.should eq(1)
    installed.should be_empty
    client.approval = OtaProvider::ApplyUpdateResponse.new(OtaProvider::ApplyAction::Proceed, 0_u32)
    service.resume_delayed_apply.should eq(OtaLifecycle::Result::Installed)
    client.queries.should eq(1)
    client.applies.should eq(2)
    installed.should eq([11_u32])
  end

  it "releases a delayed image when the host closes the lifecycle" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    client.approval = OtaProvider::ApplyUpdateResponse.new(OtaProvider::ApplyAction::AwaitNextAction, 0_u32)
    service = ota_lifecycle_service(client, store, cluster)
    service.attach
    service.process_provider(1_u8, 0x1234_u64, 0_u16).should eq(OtaLifecycle::Result::Delayed)

    service.close
    service.next_apply_at.should be_nil
    cluster.update_possible?.should be_false
    expect_raises(Matter::ProtocolError, /closed/) { service.resume_delayed_apply }
  end

  it "does not journal or install a failed download" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    installed = [] of UInt32
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    client.fail_download = true
    service = ota_lifecycle_service(client, store, cluster, installed: installed)

    expect_raises(Matter::ProtocolError) { service.process_provider(1_u8, 0x1234_u64, 0_u16) }
    service.pending_notification.should be_nil
    installed.should be_empty
  end

  it "persists the token before installation and retries notification after restart" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    installed = [] of UInt32
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, cluster, installed: installed)

    service.process_provider(1_u8, 0x1234_u64, 0_u16).should eq(OtaLifecycle::Result::Installed)
    installed.should eq([11_u32])
    service.pending_notification.as(OtaLifecycle::PendingNotification).update_token
      .should eq(Bytes[1, 2, 3, 4, 5, 6, 7, 8])
    service.notify_if_applied.should be_false

    restarted = ota_lifecycle_service(client, store, OtaRequestor.new, version: 11_u32)
    client.fail_notification = true
    expect_raises(Matter::ProtocolError) { restarted.notify_if_applied }
    restarted.pending_notification.should_not be_nil
    client.fail_notification = false
    restarted.notify_if_applied.should be_true
    restarted.pending_notification.should be_nil
    client.notifications.should eq(2)
  end

  it "recovers a pending token from a reopened file backend" do
    path = File.join(Dir.tempdir, "matter-ota-lifecycle-#{Random::Secure.hex(6)}.json")
    store = Matter::Storage::JsonFile.new(path)
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, OtaRequestor.new)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)
    store.close

    reopened = Matter::Storage::JsonFile.new(path)
    restarted = ota_lifecycle_service(client, reopened, OtaRequestor.new, version: 11_u32)
    restarted.pending_notification.should_not be_nil
    restarted.notify_if_applied.should be_true
    reopened.close
    File.delete?(path)
  end

  it "clears a failed installer journal so later updates can proceed" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, cluster, fail_install: true)

    expect_raises(Matter::ProtocolError) { service.process_provider(1_u8, 0x1234_u64, 0_u16) }
    service.pending_notification.should be_nil
    expect_raises(Matter::ProtocolError) { service.process_provider(1_u8, 0x1234_u64, 0_u16) }
    client.queries.should eq(2)
  end

  it "does not repeat provider notification or VersionApplied after a journal delete failure" do
    store = OtaFailDeleteMemory.new
    cluster = OtaRequestor.new
    emitted = 0
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      emitted += 1 if event == OtaRequestor::EVENT_VERSION_APPLIED
      nil
    end
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, cluster)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)
    restarted = ota_lifecycle_service(client, store, cluster, version: 11_u32)

    store.fail_pending_delete = true
    expect_raises(Matter::StorageError) { restarted.notify_if_applied }
    emitted.should eq(1)
    client.notifications.should eq(1)
    restarted.pending_notification.as(OtaLifecycle::PendingNotification).event_published?.should be_true
    restarted.notify_if_applied.should be_true
    client.notifications.should eq(1)
    emitted.should eq(1)
  end

  it "serializes concurrent restart notifications" do
    store = Matter::Storage::Memory.new
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, OtaRequestor.new)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)
    restarted = ota_lifecycle_service(client, store, OtaRequestor.new, version: 11_u32)
    entered = Channel(Nil).new
    release = Channel(Nil).new
    finished = Channel(Nil).new
    client.notify_entered = entered
    client.notify_release = release

    spawn do
      restarted.notify_if_applied.should be_true
      finished.send(nil)
    end
    entered.receive
    expect_raises(Matter::ProtocolError, /already in progress/) { restarted.notify_if_applied }
    release.send(nil)
    finished.receive
    client.notifications.should eq(1)
  end

  it "keeps a notified token when VersionApplied publication fails and retries the event" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    fail_event = true
    published = 0
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      if event == OtaRequestor::EVENT_VERSION_APPLIED
        if fail_event
          fail_event = false
          raise Matter::StorageError.new("injected event journal failure")
        end
        published += 1
      end
      nil
    end
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, cluster)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)
    restarted = ota_lifecycle_service(client, store, cluster, version: 11_u32)

    expect_raises(Matter::StorageError) { restarted.notify_if_applied }
    restarted.pending_notification.should_not be_nil
    client.notifications.should eq(1)
    published.should eq(0)
    restarted.notify_if_applied.should be_true
    restarted.pending_notification.should be_nil
    client.notifications.should eq(1)
    published.should eq(1)
  end

  it "replays VersionApplied but not NotifyUpdateApplied after an event marker write failure" do
    store = OtaFailMarkerWriteMemory.new
    cluster = OtaRequestor.new
    published = 0
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      published += 1 if event == OtaRequestor::EVENT_VERSION_APPLIED
      nil
    end
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, cluster)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)
    restarted = ota_lifecycle_service(client, store, cluster, version: 11_u32)

    store.fail_event_marker = true
    expect_raises(Matter::StorageError) { restarted.notify_if_applied }
    published.should eq(1)
    client.notifications.should eq(1)
    restarted.pending_notification.as(OtaLifecycle::PendingNotification).event_published?.should be_false
    restarted.notify_if_applied.should be_true
    published.should eq(2)
    client.notifications.should eq(1)
  end

  it "clears a pending token when its fabric is removed" do
    store = Matter::Storage::Memory.new
    cluster = OtaRequestor.new
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, cluster)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)

    service.remove_fabric(2_u8)
    service.pending_notification.should_not be_nil
    service.fabric_table.remove_fabric(1_u8).should be_true
    service.pending_notification.should be_nil
  end

  it "retains the pending notification if durable fabric deletion fails" do
    store = OtaFailFabricDeleteMemory.new
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, OtaRequestor.new)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)
    store.fail_fabric_delete = true

    expect_raises(Matter::StorageError) { service.fabric_table.remove_fabric(1_u8) }
    service.fabric_table.get_fabric(1_u8).should_not be_nil
    restarted = ota_lifecycle_service(client, store, OtaRequestor.new, version: 11_u32)
    restarted.pending_notification.should_not be_nil
    restarted.notify_if_applied.should be_true
    client.notifications.should eq(1)
  end

  it "discards a token if a local fabric index belongs to a different identity after restart" do
    store = Matter::Storage::Memory.new
    client = OtaLifecycleClientFake.new(ota_lifecycle_staged)
    service = ota_lifecycle_service(client, store, OtaRequestor.new)
    service.process_provider(1_u8, 0x1234_u64, 0_u16)
    service.pending_notification.should_not be_nil

    independent_table = Matter::FabricTable.new(store)
    independent_table.remove_fabric(1_u8).should be_true
    independent_table.add_fabric(Matter::Fabric.new(
      fabric_id: 999_u64, fabric_index: 1_u8, node_id: 0x1_u64,
      root_public_key: Random::Secure.random_bytes(65),
      operational_cert: Random::Secure.random_bytes(200),
      operational_key: Matter::Crypto::Key.generate_key_pair,
      ipk: Random::Secure.random_bytes(16))).should be_true

    restarted = ota_lifecycle_service(client, store, OtaRequestor.new, version: 11_u32)
    restarted.notify_if_applied.should be_false
    restarted.pending_notification.should be_nil
    client.notifications.should eq(0)
  end
end
