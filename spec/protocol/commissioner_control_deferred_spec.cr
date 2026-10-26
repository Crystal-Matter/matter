require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private alias ReverseControl = Matter::Cluster::CommissionerControl
private REVERSE_PEER            = Socket::IPAddress.new("127.0.0.1", 5540)
private REVERSE_OPEN_COMMAND_ID = 0x02_u32
private CHUNK_PADDING_COMMANDS  =        6

private class ReverseChunkPadding < Matter::Cluster::Base
  cluster 0xFFF1_FC70, revision: 1

  struct PadResponse
    include TLV::Serializable

    @[TLV::Field(tag: 0)]
    getter value : String

    def initialize(@value : String)
    end
  end

  command 0x00, :pad, response: PadResponse, response_id: 0x01, access: :manage

  def pad : PadResponse
    PadResponse.new("P" * 350)
  end
end

private class ReverseFailingTransport < Matter::Spec::CaptureTransport
  property? fail_next : Bool = false

  protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
    if @fail_next
      @fail_next = false
      raise IO::Error.new("synthetic response send failure")
    end
    super
  end
end

private def reverse_fixture
  transport = ReverseFailingTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(transport,
    setup_pin: 20202021_u32, discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  # This focused transport fixture tests the handoff itself; ACL policy is
  # covered by the cluster's Manage privilege and separate ACL tests.
  handler.clusters.delete({0_u16, Matter::Cluster::AccessControl::CLUSTER_ID})
  session = Matter::Spec::ProtocolMessages.case_session(241_u16)
  handler.sessions[session.session_id] = session
  control = ReverseControl.new(Matter::DataType::EndpointNumber.new(0_u16))
  handler.clusters[{0_u16, ReverseControl::CLUSTER_ID}] = control
  {handler, transport, session, control}
end

private def reverse_invoke(handler : Matter::Protocol::MessageHandler,
                           session : Matter::Session::SecureContext,
                           command_id : UInt32, fields : Bytes,
                           counter : UInt32, exchange : UInt16) : Nil
  path = Matter::InteractionModel::CommandPath.new(0_u16, ReverseControl::CLUSTER_ID, command_id)
  request = Matter::InteractionModel::InvokeRequestMessage.new([
    Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.from_slice(fields)),
  ])
  inbound = Matter::Spec::ProtocolMessages.from_peer(session,
    Matter::InteractionModel::MessageType::InvokeRequest.value,
    request.to_slice, counter, exchange)
  handler.handle_message(inbound, REVERSE_PEER)
end

private def reverse_window : ReverseControl::ReverseOpenCommissioningWindowResponse
  ReverseControl::ReverseOpenCommissioningWindowResponse.new(
    180_u16, Bytes.new(97, 0_u8), 3840_u16, 1000_u32, Bytes.new(16, 0_u8))
end

private def reverse_response(wire : Bytes, session : Matter::Session::SecureContext) : Matter::InteractionModel::InvokeResponseMessage
  packet = Matter::Codec::MessageCodec::Base.decode_packet(wire)
  header = wire[0, wire.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    packet.header.message_id, header[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key,
    packet.payload, nonce, header)
  payload = Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload
  Matter::InteractionModel::InvokeResponseMessage.from_slice(payload)
end

private def reverse_chunked_invoke(handler : Matter::Protocol::MessageHandler,
                                   session : Matter::Session::SecureContext,
                                   request_id : UInt64, exchange : UInt16,
                                   counter : UInt32 = 2_u32) : Nil
  padding = Array.new(CHUNK_PADDING_COMMANDS) do
    path = Matter::InteractionModel::CommandPath.new(0_u16, ReverseChunkPadding::CLUSTER_ID,
      ReverseChunkPadding::CMD_PAD)
    Matter::InteractionModel::CommandDataIBTlv.new(path)
  end
  path = Matter::InteractionModel::CommandPath.new(0_u16, ReverseControl::CLUSTER_ID,
    ReverseControl::CMD_COMMISSION_NODE)
  padding << Matter::InteractionModel::CommandDataIBTlv.new(path,
    TLV::Any.from_slice(ReverseControl::CommissionNodeRequest.new(request_id).to_slice))
  request = Matter::InteractionModel::InvokeRequestMessage.new(padding)
  inbound = Matter::Spec::ProtocolMessages.from_peer(session,
    Matter::InteractionModel::MessageType::InvokeRequest.value,
    request.to_slice, counter, exchange)
  handler.handle_message(inbound, REVERSE_PEER)
end

private def reverse_chunked_fixture(request_id : UInt64, approval_exchange : UInt16,
                                    invoke_exchange : UInt16)
  handler, transport, session, control = reverse_fixture
  handler.clusters[{0_u16, ReverseChunkPadding::CLUSTER_ID}] =
    ReverseChunkPadding.new(Matter::DataType::EndpointNumber.new(0_u16))
  started = Channel(Int32).new(1)
  control.configure_host(
    ->(approval : ReverseControl::ApprovalRequest) do
      control.resolve_approval(approval, Matter::InteractionModel::StatusCode::Success)
      nil
    end,
    ->(_approval : ReverseControl::ApprovalRequest, _request : ReverseControl::CommissionNodeRequest) do
      ReverseControl::PreparedWindow.new(reverse_window, -> { started.send(transport.sent_packets.size); nil })
        .as(ReverseControl::PreparedWindow?)
    end)
  reverse_invoke(handler, session, ReverseControl::CMD_REQUEST_COMMISSIONING_APPROVAL,
    ReverseControl::RequestCommissioningApprovalRequest.new(request_id, 0xFFF1_u16, 1_u16).to_slice,
    1_u32, approval_exchange)
  reverse_chunked_invoke(handler, session, request_id, invoke_exchange)
  {handler, transport, session, control, started}
end

describe "reverse commissioning response handoff" do
  it "waits for the final InvokeResponse chunk before starting reverse commissioning" do
    handler, transport, session, _, started = reverse_chunked_fixture(77_u64, 120_u16, 121_u16)

    response = reverse_response(transport.sent_packets.last[0], session)
    response.more_chunked_messages.should be_true
    response.invoke_responses.compact_map(&.command_data).map(&.command_path.command)
      .should_not contain(REVERSE_OPEN_COMMAND_ID)
    select
    when started.receive
      fail "reverse commissioning started before its response chunk"
    when timeout(20.milliseconds)
    end

    counter = 3_u32
    while response.more_chunked_messages == true
      status = Matter::Spec::ProtocolMessages.status_response(session, counter, 121_u16)
      handler.handle_message(status, REVERSE_PEER)
      counter += 1_u32
      response = reverse_response(transport.sent_packets.last[0], session)
      if response.more_chunked_messages == true
        select
        when started.receive
          fail "reverse commissioning started before the final response chunk"
        when timeout(20.milliseconds)
        end
      end
    end
    response.invoke_responses.compact_map(&.command_data).map(&.command_path.command)
      .should contain(REVERSE_OPEN_COMMAND_ID)
    select
    when sent_count = started.receive
      sent_count.should eq(transport.sent_packets.size)
    when timeout(1.second)
      fail "final response chunk did not start reverse commissioning"
    end
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, counter, 121_u16), REVERSE_PEER)
    select
    when started.receive
      fail "a duplicate completion started reverse commissioning twice"
    when timeout(20.milliseconds)
    end
    handler.close
  end

  it "discards reverse commissioning if a chunk is rejected before the window response" do
    handler, transport, session, control, started = reverse_chunked_fixture(78_u64, 122_u16, 123_u16)
    reverse_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true
    sent_count = transport.sent_packets.size

    status = Matter::Spec::ProtocolMessages.status_response(session, 3_u32, 123_u16,
      Matter::InteractionModel::StatusCode::Failure.value)
    handler.handle_message(status, REVERSE_PEER)
    transport.sent_packets.size.should eq(sent_count)
    control.take_pending_commissions(session.object_id.to_u64, 123_u16).should be_empty
    select
    when started.receive
      fail "rejected response chunk started reverse commissioning"
    when timeout(20.milliseconds)
    end
    handler.close
  end

  it "discards reverse commissioning when a later InvokeResponse chunk cannot be sent" do
    handler, transport, session, control, started = reverse_chunked_fixture(79_u64, 124_u16, 125_u16)
    reverse_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true
    sent_count = transport.sent_packets.size

    transport.fail_next = true
    status = Matter::Spec::ProtocolMessages.status_response(session, 3_u32, 125_u16)
    handler.handle_message(status, REVERSE_PEER)
    transport.sent_packets.size.should eq(sent_count)
    control.take_pending_commissions(session.object_id.to_u64, 125_u16).should be_empty
    select
    when started.receive
      fail "failed response chunk started reverse commissioning"
    when timeout(20.milliseconds)
    end
    handler.close
  end

  it "does not release an old commission through a replacement encrypted session" do
    handler, transport, session, control, started = reverse_chunked_fixture(80_u64, 126_u16, 127_u16)
    reverse_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true
    sent_count = transport.sent_packets.size

    replacement = Matter::Spec::ProtocolMessages.case_session(session.session_id)
    handler.sessions[session.session_id] = replacement
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(replacement, 3_u32, 127_u16), REVERSE_PEER)

    transport.sent_packets.size.should eq(sent_count + 1)
    Matter::Spec::ProtocolMessages.decode_message_type(transport.sent_packets.last[0], replacement)
      .should_not eq(Matter::InteractionModel::MessageType::InvokeResponse.value)
    control.take_pending_commissions(session.object_id.to_u64, 127_u16).should be_empty
    select
    when started.receive
      fail "replacement session released an old commission"
    when timeout(20.milliseconds)
    end
    handler.close
  end

  it "discards a stalled commission after the invoke chunk acknowledgement timeout" do
    handler, transport, session, control, started = reverse_chunked_fixture(81_u64, 128_u16, 129_u16)
    reverse_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true
    sent_count = transport.sent_packets.size

    handler.subscriptions.tick(monotonic_now: Time.monotonic + 31.seconds)
    control.take_pending_commissions(session.object_id.to_u64, 129_u16).should be_empty
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, 3_u32, 129_u16), REVERSE_PEER)
    transport.sent_packets.size.should eq(sent_count + 1)
    Matter::Spec::ProtocolMessages.decode_message_type(transport.sent_packets.last[0], session)
      .should_not eq(Matter::InteractionModel::MessageType::InvokeResponse.value)
    select
    when started.receive
      fail "timed out invoke released a commission"
    when timeout(20.milliseconds)
    end
    handler.close
  end

  it "keeps new deferred work when a chunked invoke replaces the same session and exchange" do
    handler, transport, session, _, started = reverse_chunked_fixture(82_u64, 130_u16, 131_u16)
    reverse_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true

    reverse_invoke(handler, session, ReverseControl::CMD_REQUEST_COMMISSIONING_APPROVAL,
      ReverseControl::RequestCommissioningApprovalRequest.new(83_u64, 0xFFF1_u16, 1_u16).to_slice,
      3_u32, 132_u16)
    reverse_chunked_invoke(handler, session, 83_u64, 131_u16, 4_u32)

    response = reverse_response(transport.sent_packets.last[0], session)
    response.more_chunked_messages.should be_true
    counter = 5_u32
    while response.more_chunked_messages == true
      handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, counter, 131_u16), REVERSE_PEER)
      counter += 1_u32
      response = reverse_response(transport.sent_packets.last[0], session)
    end
    select
    when started.receive
    when timeout(1.second)
      fail "replacement invoke's deferred commission was discarded"
    end
    select
    when started.receive
      fail "displaced invoke also started commissioning"
    when timeout(20.milliseconds)
    end
    handler.close
  end

  it "runs commissioning only after the matching encrypted response is sent and the protocol lock is released" do
    handler, transport, session, control = reverse_fixture
    started = Channel(Int32).new(1)
    approvals = [] of ReverseControl::ApprovalRequest
    control.configure_host(
      ->(approval : ReverseControl::ApprovalRequest) do
        approvals << approval
        control.resolve_approval(approval, Matter::InteractionModel::StatusCode::Success)
        nil
      end,
      ->(_approval : ReverseControl::ApprovalRequest, _request : ReverseControl::CommissionNodeRequest) do
        ReverseControl::PreparedWindow.new(reverse_window, -> { started.send(transport.sent_packets.size); nil })
          .as(ReverseControl::PreparedWindow?)
      end)
    reverse_invoke(handler, session, ReverseControl::CMD_REQUEST_COMMISSIONING_APPROVAL,
      ReverseControl::RequestCommissioningApprovalRequest.new(1_u64, 0xFFF1_u16, 1_u16).to_slice,
      1_u32, 50_u16)
    reverse_invoke(handler, session, ReverseControl::CMD_COMMISSION_NODE,
      ReverseControl::CommissionNodeRequest.new(1_u64).to_slice,
      2_u32, 51_u16)
    select
    when sent_count = started.receive
      sent_count.should eq(2)
    when timeout(1.second)
      fail "deferred commissioning did not start"
    end
    control.take_pending_commissions(session.object_id.to_u64, 51_u16).should be_empty
    handler.close
  end

  it "does not release work for another exchange or another secure session object" do
    handler, transport, session, control = reverse_fixture
    started = Channel(Nil).new(1)
    approvals = [] of ReverseControl::ApprovalRequest
    control.configure_host(
      ->(approval : ReverseControl::ApprovalRequest) { approvals << approval; nil },
      ->(_approval : ReverseControl::ApprovalRequest, _request : ReverseControl::CommissionNodeRequest) do
        ReverseControl::PreparedWindow.new(reverse_window, -> { started.send(nil); nil })
          .as(ReverseControl::PreparedWindow?)
      end)
    control.request_is_case_session = true
    control.request_fabric_index = 1_u8
    control.request_peer_node_id = 0x2222_u64
    control.request_session_identity = session.object_id.to_u64
    control.request_exchange_id = 99_u16
    control.request_commissioning_approval(ReverseControl::RequestCommissioningApprovalRequest.new(7_u64, 1_u16, 1_u16))
    control.resolve_approval(approvals.first, Matter::InteractionModel::StatusCode::Success)
    control.commission_node(ReverseControl::CommissionNodeRequest.new(7_u64))
      .as(ReverseControl::ReverseOpenCommissioningWindowResponse)

    # This response belongs to exchange 100; it must not release exchange 99.
    reverse_invoke(handler, session, ReverseControl::CMD_REQUEST_COMMISSIONING_APPROVAL,
      ReverseControl::RequestCommissioningApprovalRequest.new(8_u64, 1_u16, 1_u16).to_slice,
      1_u32, 100_u16)
    select
    when started.receive
      fail "wrong exchange started reverse commissioning"
    when timeout(20.milliseconds)
    end
    # A replacement session can reuse the same 16-bit wire ID and exchange.
    other = Matter::Spec::ProtocolMessages.case_session(session.session_id)
    control.take_pending_commissions(other.object_id.to_u64, 99_u16).should be_empty
    control.take_pending_commissions(session.object_id.to_u64, 99_u16).size.should eq(1)
    transport.sent_packets.size.should eq(1)
    handler.close
  end

  it "discards deferred work when the matching InvokeResponse send fails" do
    handler, transport, session, control = reverse_fixture
    started = Channel(Nil).new(1)
    control.configure_host(
      ->(approval : ReverseControl::ApprovalRequest) do
        control.resolve_approval(approval, Matter::InteractionModel::StatusCode::Success)
        nil
      end,
      ->(_approval : ReverseControl::ApprovalRequest, _request : ReverseControl::CommissionNodeRequest) do
        ReverseControl::PreparedWindow.new(reverse_window, -> { started.send(nil); nil })
          .as(ReverseControl::PreparedWindow?)
      end)
    reverse_invoke(handler, session, ReverseControl::CMD_REQUEST_COMMISSIONING_APPROVAL,
      ReverseControl::RequestCommissioningApprovalRequest.new(9_u64, 1_u16, 1_u16).to_slice,
      1_u32, 110_u16)
    transport.fail_next = true
    reverse_invoke(handler, session, ReverseControl::CMD_COMMISSION_NODE,
      ReverseControl::CommissionNodeRequest.new(9_u64).to_slice,
      2_u32, 111_u16)
    control.take_pending_commissions(session.object_id.to_u64, 111_u16).should be_empty
    # The failed ciphertext must not be replayable from the MRP cache.
    reverse_invoke(handler, session, ReverseControl::CMD_COMMISSION_NODE,
      ReverseControl::CommissionNodeRequest.new(9_u64).to_slice,
      2_u32, 111_u16)
    transport.sent_packets.size.should eq(1)
    select
    when started.receive
      fail "failed send started reverse commissioning"
    when timeout(20.milliseconds)
    end
    handler.close
  end
end
