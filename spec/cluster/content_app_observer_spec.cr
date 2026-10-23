require "../spec_helper"

private alias Observer = Matter::Cluster::ContentAppObserver
private alias IMCode = Matter::InteractionModel::StatusCode

describe Observer do
  it "advertises the revision-one request and typed response" do
    cluster = build(Observer)
    cluster.cluster_id.id.should eq(0x0510_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.should be_empty
    accepted_command_ids(cluster).should eq([Observer::CMD_CONTENT_APP_MESSAGE])
    generated_command_ids(cluster).should eq([Observer::CMD_CONTENT_APP_MESSAGE_RESPONSE])

    request = Observer::ContentAppMessageRequest.new("hello")
    request.to_tlv(nil).as_structure.keys.should eq([0_u8])
    Observer::ContentAppMessageRequest.from_tlv(request.to_tlv(nil)).encoding_hint.should be_nil
    encoded = Observer::ContentAppMessageRequest.new("hello", "application/json")
    encoded.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])

    response = Observer::ContentAppMessageResponse.new(Observer::Status::UnexpectedData)
    response.to_tlv(nil).as_structure.keys.should eq([0_u8])
    Observer::ContentAppMessageResponse.from_tlv(response.to_tlv(nil)).data.should be_nil
  end

  it "passes authenticated sender identity to the host and returns its response" do
    cluster = build(Observer)
    observed = [] of Tuple(String, String?, UInt8, UInt64)
    cluster.on_content_app_message do |request, fabric, node|
      observed << {request.data, request.encoding_hint, fabric, node}
      Observer::ContentAppMessageResponse.new(Observer::Status::Success, "ack", "text/plain")
    end
    cluster.request_peer_node_id = 0x1234_u64

    result = invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE,
      Observer::ContentAppMessageRequest.new("play", "application/json"),
      is_case_session: true, fabric_index: 2_u8).as(Matter::Cluster::CommandResponse)
    result.command_id.should eq(Observer::CMD_CONTENT_APP_MESSAGE_RESPONSE)
    response = Observer::ContentAppMessageResponse.from_tlv(result.response.as(TLV::Any))
    response.status.should eq(Observer::Status::Success)
    response.data.should eq("ack")
    response.encoding_hint.should eq("text/plain")
    observed.should eq([{"play", "application/json", 2_u8, 0x1234_u64}])
  end

  it "rejects unauthenticated or unscoped messages before invoking the host" do
    cluster = build(Observer)
    calls = 0
    cluster.on_content_app_message do |_request, _fabric, _node|
      calls += 1
      Observer::ContentAppMessageResponse.new(Observer::Status::Success)
    end
    request = Observer::ContentAppMessageRequest.new("hello")
    expect_status(invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE, request), IMCode::UnsupportedAccess)
    expect_status(invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE, request,
      is_case_session: true, fabric_index: 1_u8), IMCode::UnsupportedAccess)
    cluster.request_peer_node_id = 0x1234_u64
    expect_status(invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE, request,
      is_case_session: true), IMCode::UnsupportedAccess)
    calls.should eq(0)
  end

  it "enforces request and host-response string limits without a false success" do
    cluster = build(Observer)
    cluster.request_peer_node_id = 0x1234_u64
    request = Observer::ContentAppMessageRequest.new("hello")
    expect_status(invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE, request,
      is_case_session: true, fabric_index: 1_u8), IMCode::InvalidInState)

    calls = 0
    cluster.on_content_app_message do |_request, _fabric, _node|
      calls += 1
      Observer::ContentAppMessageResponse.new(Observer::Status::UnexpectedData)
    end
    oversized_data = Observer::ContentAppMessageRequest.new("x" * 501)
    expect_status(invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE, oversized_data,
      is_case_session: true, fabric_index: 1_u8), IMCode::ConstraintError)
    oversized_hint = Observer::ContentAppMessageRequest.new("ok", "x" * 101)
    expect_status(invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE, oversized_hint,
      is_case_session: true, fabric_index: 1_u8), IMCode::ConstraintError)
    calls.should eq(0)

    cluster.on_content_app_message do |_request, _fabric, _node|
      Observer::ContentAppMessageResponse.new(Observer::Status::Success, "x" * 501)
    end
    expect_status(invoke(cluster, Observer::CMD_CONTENT_APP_MESSAGE, request,
      is_case_session: true, fabric_index: 1_u8), IMCode::Failure)
  end
end
