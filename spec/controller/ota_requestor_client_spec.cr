require "../spec_helper"
require "../../src/matter/controller/ota_requestor_client"
require "openssl"

private alias OtaRequestorClientSpec = Matter::Controller::OtaRequestorClient
private alias OtaProviderSpec = Matter::Cluster::OtaProvider
private alias OtaRequestorSpec = Matter::Cluster::OtaRequestor

private class OtaImFake
  getter requests = [] of OtaProviderSpec::QueryImageRequest
  getter endpoints = [] of UInt16
  property response : OtaProviderSpec::QueryImageResponse

  def initialize(@response)
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes) : Matter::InteractionModel::InvokeResponseMessage
    cluster_id.should eq(OtaProviderSpec::CLUSTER_ID)
    command_id.should eq(OtaProviderSpec::CMD_QUERY_IMAGE)
    @requests << OtaProviderSpec::QueryImageRequest.from_slice(fields)
    @endpoints << endpoint_id
    path = Matter::InteractionModel::CommandPath.new(endpoint_id, cluster_id,
      1_u32)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, @response.to_tlv(nil))
    Matter::InteractionModel::InvokeResponseMessage.new(
      invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_data: data)])
  end
end

private class OtaBdxFake
  getter designators = [] of Bytes
  getter max_bytes = [] of UInt64

  def initialize(@image : Bytes)
  end

  def download(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
               file_designator : Bytes, sink : IO,
               max_bytes : UInt64) : UInt64
    @designators << file_designator
    @max_bytes << max_bytes
    sink.write(@image)
    @image.size.to_u64
  end
end

private class OtaHttpsFake < Matter::Controller::OtaHttpsDownloader
  getter urls = [] of String
  getter max_bytes = [] of UInt64

  def initialize(@image : Bytes)
    super()
  end

  def download(url : String, sink : IO, max_bytes : UInt64) : UInt64
    @urls << url
    @max_bytes << max_bytes
    sink.write(@image)
    @image.size.to_u64
  end
end

private class OtaApplyImFake
  getter applies = [] of OtaProviderSpec::ApplyUpdateRequest
  getter notifications = [] of OtaProviderSpec::NotifyUpdateAppliedRequest
  property action = OtaProviderSpec::ApplyAction::Proceed
  property delay = 0_u32

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes) : Matter::InteractionModel::InvokeResponseMessage
    case command_id
    when OtaProviderSpec::CMD_APPLY_UPDATE_REQUEST
      @applies << OtaProviderSpec::ApplyUpdateRequest.from_slice(fields)
      path = Matter::InteractionModel::CommandPath.new(endpoint_id, cluster_id,
        OtaProviderSpec::CMD_APPLY_UPDATE_REQUEST_RESPONSE)
      data = Matter::InteractionModel::CommandDataIBTlv.new(path,
        OtaProviderSpec::ApplyUpdateResponse.new(@action, @delay).to_tlv(nil))
      Matter::InteractionModel::InvokeResponseMessage.new(
        invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_data: data)])
    when OtaProviderSpec::CMD_NOTIFY_UPDATE_APPLIED
      @notifications << OtaProviderSpec::NotifyUpdateAppliedRequest.from_slice(fields)
      path = Matter::InteractionModel::CommandPath.new(endpoint_id, cluster_id, command_id)
      status = Matter::InteractionModel::CommandStatusIB.new(path,
        Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::Success.value))
      Matter::InteractionModel::InvokeResponseMessage.new(
        invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
    else
      raise Matter::ProtocolError.new("Unexpected OTA command")
    end
  end
end

private def ota_controller_image(payload : Bytes = "firmware".to_slice) : Bytes
  digest = OpenSSL::Digest.new("SHA256").update(payload).final
  header = Matter::Protocol::OtaImage::Header.new
  header.vendor_id = 0xFFF1_u16
  header.product_id = 0x8001_u16
  header.software_version = 11_u32
  header.software_version_string = "11.0"
  header.payload_size = payload.size.to_u64
  header.image_digest_type = 1_u8
  header.image_digest = digest
  header_bytes = header.to_slice
  io = IO::Memory.new
  io.write_bytes(Matter::Protocol::OtaImage::MAGIC, IO::ByteFormat::LittleEndian)
  io.write_bytes((16 + header_bytes.size + payload.size).to_u64, IO::ByteFormat::LittleEndian)
  io.write_bytes(header_bytes.size.to_u32, IO::ByteFormat::LittleEndian)
  io.write(header_bytes)
  io.write(payload)
  io.to_slice
end

private def ota_controller_session(peer_node_id : UInt64 = 0x1234_u64) : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16, peer_session_id: 2_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 0x11_u8),
    decryption_key: Bytes.new(16, 0x22_u8),
    peer_node_id: Matter::DataType::NodeId.new(peer_node_id),
    case_session: true, fabric_index: 1_u8)
end

describe "OTA Requestor controller download" do
  it "queries a CASE provider, downloads its designator, and validates the staged image" do
    token = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    im = OtaImFake.new(OtaProviderSpec::QueryImageResponse.available(
      "bdx://0000000000001234/fw%20v11", 11_u32, "11.0", token))
    bdx = OtaBdxFake.new(ota_controller_image)
    cluster = OtaRequestorSpec.new
    client = OtaRequestorClientSpec.new(im, bdx, cluster)
    sink = IO::Memory.new

    staged = client.query_and_download(ota_controller_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 0_u16,
      0xFFF1_u16, 0x8001_u16, 10_u32, sink,
      max_image_bytes: 4096_u64)

    staged.should_not be_nil
    if update = staged
      update.header.software_version.should eq(11_u32)
      update.update_token.should eq(token)
    end
    im.requests.first.protocols_supported.should eq([OtaProviderSpec::DownloadProtocol::BdxSynchronous])
    im.requests.first.requestor_can_consent.should be_false
    # Matter sends the URI path octets verbatim as the BDX file designator.
    bdx.designators.should eq(["fw%20v11".to_slice])
    bdx.max_bytes.should eq([4096_u64])
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::Downloading)
    sink.pos.should eq(0)
  end

  it "advertises HTTPS only when a downloader is wired and validates that image" do
    token = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    im = OtaImFake.new(OtaProviderSpec::QueryImageResponse.available(
      "https://updates.example.test/v11.ota", 11_u32, "11.0", token))
    bdx = OtaBdxFake.new(Bytes.empty)
    https = OtaHttpsFake.new(ota_controller_image)
    client = OtaRequestorClientSpec.new(im, bdx, OtaRequestorSpec.new, https: https)

    staged = client.query_and_download(ota_controller_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 0_u16,
      0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new,
      max_image_bytes: 4096_u64)

    staged.should_not be_nil
    im.requests.first.protocols_supported.should eq([
      OtaProviderSpec::DownloadProtocol::BdxSynchronous,
      OtaProviderSpec::DownloadProtocol::Https,
    ])
    https.urls.should eq(["https://updates.example.test/v11.ota"])
    bdx.designators.should be_empty
  end

  it "asks for user consent before downloading when the provider requires it" do
    offer = OtaProviderSpec::QueryImageResponse.available(
      "bdx://0000000000001234/image", 11_u32, "11.0", Bytes[1, 2, 3, 4, 5, 6, 7, 8])
    offer.user_consent_needed = true
    im = OtaImFake.new(offer)
    bdx = OtaBdxFake.new(ota_controller_image)
    cluster = OtaRequestorSpec.new
    client = OtaRequestorClientSpec.new(im, bdx, cluster)
    client.on_user_consent = ->(_offer : OtaProviderSpec::QueryImageResponse) { false }

    client.query_and_download(ota_controller_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 0_u16,
      0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new).should be_nil
    im.requests.first.requestor_can_consent.should be_true
    bdx.designators.should be_empty
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::DelayedOnUserConsent)

    client.on_user_consent = ->(_offer : OtaProviderSpec::QueryImageResponse) { true }
    client.query_and_download(ota_controller_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 0_u16,
      0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new).should_not be_nil
    bdx.designators.size.should eq(1)
  end

  it "keeps the image idle when the provider has no update" do
    im = OtaImFake.new(OtaProviderSpec::QueryImageResponse.new(OtaProviderSpec::QueryStatus::NotAvailable))
    bdx = OtaBdxFake.new(ota_controller_image)
    cluster = OtaRequestorSpec.new
    result = OtaRequestorClientSpec.new(im, bdx, cluster).query_and_download(
      ota_controller_session, Socket::IPAddress.new("127.0.0.1", 5540), 0_u16,
      0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new)
    result.should be_nil
    bdx.designators.should be_empty
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::Idle)
  end

  it "respects an available offer's delayed action time before querying or downloading again" do
    im = OtaImFake.new(OtaProviderSpec::QueryImageResponse.new(
      OtaProviderSpec::QueryStatus::UpdateAvailable,
      delayed_action_time: 60_u32,
      image_uri: "bdx://0000000000001234/image",
      software_version: 11_u32,
      software_version_string: "11.0",
      update_token: Bytes[1, 2, 3, 4, 5, 6, 7, 8]))
    bdx = OtaBdxFake.new(ota_controller_image)
    cluster = OtaRequestorSpec.new
    client = OtaRequestorClientSpec.new(im, bdx, cluster)
    session = ota_controller_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    client.query_and_download(session, peer, 0_u16,
      0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new).should be_nil
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::DelayedOnQuery)
    client.next_query_at(session).should_not be_nil
    bdx.designators.should be_empty

    client.query_and_download(session, peer, 0_u16,
      0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new).should be_nil
    im.requests.size.should eq(1)
  end

  it "uses only the default provider stored for the CASE fabric" do
    cluster = OtaRequestorSpec.new
    cluster.default_ota_providers = [
      OtaRequestorSpec::ProviderLocation.new(0x5678_u64, 1_u16, 2_u8),
      OtaRequestorSpec::ProviderLocation.new(0x1234_u64, 3_u16, 1_u8),
    ]
    im = OtaImFake.new(OtaProviderSpec::QueryImageResponse.new(OtaProviderSpec::QueryStatus::NotAvailable))
    client = OtaRequestorClientSpec.new(im, OtaBdxFake.new(Bytes.empty), cluster)
    client.query_default_and_download(ota_controller_session,
      Socket::IPAddress.new("127.0.0.1", 5540),
      0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new)
    im.requests.size.should eq(1)
    im.endpoints.should eq([3_u16])

    expect_raises(Matter::SessionError) do
      client.query_default_and_download(ota_controller_session(0x9999_u64),
        Socket::IPAddress.new("127.0.0.1", 5540),
        0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new)
    end
    im.requests.size.should eq(1)
  end

  it "rejects a BDX authority outside the authenticated CASE peer" do
    im = OtaImFake.new(OtaProviderSpec::QueryImageResponse.available(
      "bdx://0000000000005678/image", 11_u32, "11.0", Bytes[1, 2, 3, 4, 5, 6, 7, 8]))
    bdx = OtaBdxFake.new(ota_controller_image)
    cluster = OtaRequestorSpec.new
    expect_raises(Matter::ProtocolError) do
      OtaRequestorClientSpec.new(im, bdx, cluster).query_and_download(
        ota_controller_session, Socket::IPAddress.new("127.0.0.1", 5540), 0_u16,
        0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new)
    end
    bdx.designators.should be_empty
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::Idle)
  end

  it "records a download error and returns idle when the streamed digest fails" do
    im = OtaImFake.new(OtaProviderSpec::QueryImageResponse.available(
      "bdx://0000000000001234/image", 11_u32, "11.0", Bytes[1, 2, 3, 4, 5, 6, 7, 8]))
    image = ota_controller_image.dup
    image[-1] ^= 0x01_u8
    bdx = OtaBdxFake.new(image)
    cluster = OtaRequestorSpec.new
    emitted = [] of UInt32
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      emitted << event
      nil
    end
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      OtaRequestorClientSpec.new(im, bdx, cluster).query_and_download(
        ota_controller_session, Socket::IPAddress.new("127.0.0.1", 5540), 0_u16,
        0xFFF1_u16, 0x8001_u16, 10_u32, IO::Memory.new)
    end
    emitted.should contain(OtaRequestorSpec::EVENT_DOWNLOAD_ERROR)
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::Idle)
  end

  it "requests provider approval before apply and notifies after application succeeds" do
    token = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    im = OtaApplyImFake.new
    cluster = OtaRequestorSpec.new
    client = OtaRequestorClientSpec.new(im, OtaBdxFake.new(Bytes.empty), cluster)
    header = Matter::Protocol::OtaImage::Header.new
    header.software_version = 11_u32
    header.product_id = 0x8001_u16
    staged = OtaRequestorClientSpec::StagedUpdate.new(header, token,
      "bdx://0000000000001234/image", 1024_u64)
    session = ota_controller_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    client.request_apply(session, peer, 0_u16, staged).action
      .should eq(OtaProviderSpec::ApplyAction::Proceed)
    im.applies.first.new_version.should eq(11_u32)
    im.applies.first.update_token.should eq(token)
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::Applying)

    client.notify_applied(session, peer, 0_u16, token, 11_u32, 0x8001_u16)
    im.notifications.first.software_version.should eq(11_u32)
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::Idle)
  end

  it "delays or stops apply when directed by the provider" do
    token = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    im = OtaApplyImFake.new
    cluster = OtaRequestorSpec.new
    client = OtaRequestorClientSpec.new(im, OtaBdxFake.new(Bytes.empty), cluster)
    header = Matter::Protocol::OtaImage::Header.new
    header.software_version = 11_u32
    staged = OtaRequestorClientSpec::StagedUpdate.new(header, token,
      "bdx://0000000000001234/image", 1024_u64)
    session = ota_controller_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    im.action = OtaProviderSpec::ApplyAction::AwaitNextAction
    client.request_apply(session, peer, 0_u16, staged)
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::DelayedOnApply)
    im.action = OtaProviderSpec::ApplyAction::Proceed
    im.delay = 60_u32
    client.request_apply(session, peer, 0_u16, staged)
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::DelayedOnApply)
    im.action = OtaProviderSpec::ApplyAction::Discontinue
    client.request_apply(session, peer, 0_u16, staged)
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::Idle)
  end

  it "allows provider approval for a validated HTTPS image without installing it automatically" do
    im = OtaApplyImFake.new
    client = OtaRequestorClientSpec.new(im, OtaBdxFake.new(Bytes.empty), OtaRequestorSpec.new)
    header = Matter::Protocol::OtaImage::Header.new
    header.software_version = 11_u32
    staged = OtaRequestorClientSpec::StagedUpdate.new(header,
      Bytes[1, 2, 3, 4, 5, 6, 7, 8], "https://updates.example.test/image.ota", 1024_u64)

    client.request_apply(ota_controller_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 0_u16, staged).action
      .should eq(OtaProviderSpec::ApplyAction::Proceed)
    im.applies.size.should eq(1)
  end

  it "invokes the application installer only after an immediate Proceed" do
    im = OtaApplyImFake.new
    cluster = OtaRequestorSpec.new
    client = OtaRequestorClientSpec.new(im, OtaBdxFake.new(Bytes.empty), cluster)
    header = Matter::Protocol::OtaImage::Header.new
    header.software_version = 11_u32
    staged = OtaRequestorClientSpec::StagedUpdate.new(header,
      Bytes[1, 2, 3, 4, 5, 6, 7, 8], "bdx://0000000000001234/image", 1024_u64)
    session = ota_controller_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    sink = IO::Memory.new("candidate".to_slice)
    sink.seek(4)
    called = 0

    client.apply_staged(session, peer, 0_u16, staged, sink) do |image, applied_header|
      image.pos.should eq(0)
      applied_header.software_version.should eq(11_u32)
      called += 1
    end
    called.should eq(1)

    im.delay = 60_u32
    client.apply_staged(session, peer, 0_u16, staged, sink) { |_image, _header| called += 1 }
    called.should eq(1)
    cluster.update_state.should eq(OtaRequestorSpec::UpdateState::DelayedOnApply)
  end
end
