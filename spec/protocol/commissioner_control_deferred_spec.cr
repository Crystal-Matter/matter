require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private alias ReverseControl = Matter::Cluster::CommissionerControl
private REVERSE_PEER            = Socket::IPAddress.new("127.0.0.1", 5540)
private REVERSE_OPEN_COMMAND_ID = 0x02_u32

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

describe "reverse commissioning response handoff" do
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

  it "retries an unsent reverse-window response without starting commissioning early or twice" do
    handler, transport, session, control = reverse_fixture
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
      ReverseControl::RequestCommissioningApprovalRequest.new(9_u64, 1_u16, 1_u16).to_slice,
      1_u32, 110_u16)
    transport.fail_next = true
    reverse_invoke(handler, session, ReverseControl::CMD_COMMISSION_NODE,
      ReverseControl::CommissionNodeRequest.new(9_u64).to_slice,
      2_u32, 111_u16)
    control.take_pending_commissions(session.object_id.to_u64, 111_u16).should be_empty
    # The failed ciphertext must not be replayable from the MRP cache, and an
    # approval is not consumed until the reverse-window response is sent.
    reverse_invoke(handler, session, ReverseControl::CMD_COMMISSION_NODE,
      ReverseControl::CommissionNodeRequest.new(9_u64).to_slice,
      3_u32, 112_u16)
    transport.sent_packets.size.should eq(2)
    response = reverse_response(transport.sent_packets.last[0], session)
    response.invoke_responses.first.command_status.should be_nil
    data = response.invoke_responses.first.command_data.as(Matter::InteractionModel::CommandDataIBTlv)
    data.command_path.command.should eq(REVERSE_OPEN_COMMAND_ID)
    window = ReverseControl::ReverseOpenCommissioningWindowResponse.from_tlv(data.command_fields.as(TLV::Any))
    window.discriminator.should eq(reverse_window.discriminator)
    select
    when sent_count = started.receive
      sent_count.should eq(2)
    when timeout(1.second)
      fail "successful retry did not start reverse commissioning"
    end

    reverse_invoke(handler, session, ReverseControl::CMD_COMMISSION_NODE,
      ReverseControl::CommissionNodeRequest.new(9_u64).to_slice,
      4_u32, 113_u16)
    repeat = reverse_response(transport.sent_packets.last[0], session)
    repeat.invoke_responses.first.command_status.as(Matter::InteractionModel::CommandStatusIB)
      .status.status.should eq(Matter::InteractionModel::StatusCode::Failure.value)
    select
    when started.receive
      fail "an already delivered response restarted reverse commissioning"
    when timeout(20.milliseconds)
    end
    handler.close
  end
end
