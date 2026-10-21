require "../spec_helper"

private alias OtaProvider = Matter::Cluster::OtaProvider
private alias OtaProviderCode = Matter::InteractionModel::StatusCode

private def ota_query : OtaProvider::QueryImageRequest
  OtaProvider::QueryImageRequest.new(0xFFF1_u16, 0x8001_u16, 10_u32,
    [OtaProvider::DownloadProtocol::BdxSynchronous])
end

private def invoke_ota_provider(cluster : OtaProvider, command : UInt32, request : T,
                                fabric_index : UInt8? = 1_u8) forall T
  cluster.request_peer_node_id = 0x1234_u64
  cluster.invoke_command(command, request.to_tlv(nil), is_case_session: true,
    fabric_index: fabric_index)
end

describe OtaProvider do
  it "declares the Matter 1.6 command IDs and round trips QueryImage TLV" do
    OtaProvider::CLUSTER_ID.should eq(0x0029_u32)
    OtaProvider::CMD_QUERY_IMAGE.should eq(0_u32)
    OtaProvider::CMD_APPLY_UPDATE_REQUEST.should eq(2_u32)
    OtaProvider::CMD_NOTIFY_UPDATE_APPLIED.should eq(4_u32)

    request = ota_query
    parsed = OtaProvider::QueryImageRequest.from_tlv(request.to_tlv(nil))
    parsed.vendor_id.should eq(0xFFF1_u16)
    parsed.product_id.should eq(0x8001_u16)
    parsed.software_version.should eq(10_u32)
    parsed.protocols_supported.should eq([OtaProvider::DownloadProtocol::BdxSynchronous])
  end

  it "responds NotAvailable until an application registers an image source" do
    cluster = OtaProvider.new
    response = invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, ota_query)
      .as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(1_u32)
    body = OtaProvider::QueryImageResponse.from_tlv(response.response.as(TLV::Any))
    body.status.should eq(OtaProvider::QueryStatus::NotAvailable)
    body.image_uri.should be_nil
    body.update_token.should be_nil
  end

  it "passes the authenticated fabric and peer to the application and returns an update" do
    cluster = OtaProvider.new
    observed = [] of OtaProvider::RequestContext
    cluster.on_query_image = ->(context : OtaProvider::RequestContext, _request : OtaProvider::QueryImageRequest) do
      observed << context
      OtaProvider::QueryImageResponse.available(
        "bdx://0000000000005678/image%20v11", 11_u32, "11.0",
        Bytes[1, 2, 3, 4, 5, 6, 7, 8])
    end
    response = invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, ota_query)
      .as(Matter::Cluster::CommandResponse)
    body = OtaProvider::QueryImageResponse.from_tlv(response.response.as(TLV::Any))
    body.status.should eq(OtaProvider::QueryStatus::UpdateAvailable)
    body.image_uri.should eq("bdx://0000000000005678/image%20v11")
    body.software_version.should eq(11_u32)
    observed.map(&.fabric_index).should eq([1_u8])
    observed.map(&.peer_node_id).should eq([0x1234_u64])
  end

  it "rejects unauthenticated queries and malformed update offers" do
    cluster = OtaProvider.new
    cluster.invoke_command(OtaProvider::CMD_QUERY_IMAGE, ota_query.to_tlv(nil))
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::UnsupportedAccess)
    cluster.on_query_image = ->(_context : OtaProvider::RequestContext, _request : OtaProvider::QueryImageRequest) do
      OtaProvider::QueryImageResponse.new(OtaProvider::QueryStatus::UpdateAvailable)
    end
    invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, ota_query)
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::ConstraintError)
  end

  it "requires a newer version and a valid BDX URI in an available response" do
    cluster = OtaProvider.new
    token = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    cluster.on_query_image = ->(_context : OtaProvider::RequestContext, _request : OtaProvider::QueryImageRequest) do
      OtaProvider::QueryImageResponse.available("bdx://0000000000005678/image", 10_u32, "10.0", token)
    end
    invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, ota_query)
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::ConstraintError)

    cluster.on_query_image = ->(_context : OtaProvider::RequestContext, _request : OtaProvider::QueryImageRequest) do
      OtaProvider::QueryImageResponse.available("bdx://000000000000567a/image", 11_u32, "11.0", token)
    end
    invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, ota_query)
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::ConstraintError)

    cluster.on_query_image = ->(_context : OtaProvider::RequestContext, _request : OtaProvider::QueryImageRequest) do
      OtaProvider::QueryImageResponse.available("bdx://0000000000005678/image?x=1", 11_u32, "11.0", token)
    end
    invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, ota_query)
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::ConstraintError)
  end

  it "accepts an HTTPS image only when the requestor supports HTTPS" do
    cluster = OtaProvider.new
    cluster.on_query_image = ->(_context : OtaProvider::RequestContext, _request : OtaProvider::QueryImageRequest) do
      OtaProvider::QueryImageResponse.available("https://updates.example.test/image.bin",
        11_u32, "11.0", Bytes[1, 2, 3, 4, 5, 6, 7, 8])
    end
    request = OtaProvider::QueryImageRequest.new(0xFFF1_u16, 0x8001_u16, 10_u32,
      [OtaProvider::DownloadProtocol::Https])
    response = invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, request)
      .as(Matter::Cluster::CommandResponse)
    OtaProvider::QueryImageResponse.from_tlv(response.response.as(TLV::Any)).image_uri
      .should eq("https://updates.example.test/image.bin")

    invoke_ota_provider(cluster, OtaProvider::CMD_QUERY_IMAGE, ota_query)
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::ConstraintError)
  end

  it "validates an update token and routes ApplyUpdate and NotifyUpdateApplied" do
    cluster = OtaProvider.new
    applied = [] of UInt32
    cluster.on_apply_update = ->(_context : OtaProvider::RequestContext, request : OtaProvider::ApplyUpdateRequest) do
      applied << request.new_version
      OtaProvider::ApplyUpdateResponse.new(OtaProvider::ApplyAction::Proceed, 0_u32)
    end
    notified = [] of UInt32
    cluster.on_notify_update_applied = ->(_context : OtaProvider::RequestContext, request : OtaProvider::NotifyUpdateAppliedRequest) do
      notified << request.software_version
    end
    token = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    response = invoke_ota_provider(cluster, OtaProvider::CMD_APPLY_UPDATE_REQUEST,
      OtaProvider::ApplyUpdateRequest.new(token, 11_u32)).as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(3_u32)
    OtaProvider::ApplyUpdateResponse.from_tlv(response.response.as(TLV::Any)).action
      .should eq(OtaProvider::ApplyAction::Proceed)
    invoke_ota_provider(cluster, OtaProvider::CMD_NOTIFY_UPDATE_APPLIED,
      OtaProvider::NotifyUpdateAppliedRequest.new(token, 11_u32))
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::Success)
    applied.should eq([11_u32])
    notified.should eq([11_u32])

    invoke_ota_provider(cluster, OtaProvider::CMD_APPLY_UPDATE_REQUEST,
      OtaProvider::ApplyUpdateRequest.new(Bytes[1], 11_u32))
      .as(Matter::InteractionModel::Status).status.should eq(OtaProviderCode::ConstraintError)
    applied.should eq([11_u32])
  end

  it "discontinues an unhandled apply request" do
    cluster = OtaProvider.new
    response = invoke_ota_provider(cluster, OtaProvider::CMD_APPLY_UPDATE_REQUEST,
      OtaProvider::ApplyUpdateRequest.new(Bytes[1, 2, 3, 4, 5, 6, 7, 8], 11_u32))
      .as(Matter::Cluster::CommandResponse)
    body = OtaProvider::ApplyUpdateResponse.from_tlv(response.response.as(TLV::Any))
    body.action.should eq(OtaProvider::ApplyAction::Discontinue)
    body.delayed_action_time.should eq(0_u32)
  end
end
