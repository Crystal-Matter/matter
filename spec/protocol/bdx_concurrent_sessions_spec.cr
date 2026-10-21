require "../spec_helper"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/message_handler"

private alias ConcurrentBdx = Matter::Protocol::Bdx
private BDX_CONCURRENT_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private class ConcurrentReadOnOff < Matter::Cluster::OnOff
  property on_read : Proc(Nil)?

  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    @on_read.try(&.call)
    super
  end
end

private def concurrent_bdx_response(packet_bytes : Bytes, session : Matter::Session::SecureContext)
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
  node_id = session.local_node_id.as(Matter::DataType::NodeId).id
  nonce = Matter::Session::SecureMessage.build_nonce(node_id,
    packet.header.message_id, header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key,
    packet.payload, nonce, header_bytes)
  Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
end

describe "BDX concurrent CASE sessions" do
  it "serves another session while an application BDX source callback is blocked" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    bdx_session = Matter::Spec::ProtocolMessages.case_session(281_u16)
    read_session = Matter::Spec::ProtocolMessages.case_session(282_u16)
    handler.sessions[bdx_session.session_id] = bdx_session
    handler.sessions[read_session.session_id] = read_session

    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster = ConcurrentReadOnOff.new(Matter::DataType::EndpointNumber.new(1_u16))
    endpoint.add_cluster(cluster)
    handler.node.add_endpoint(endpoint)

    callback_entered = Channel(Nil).new(1)
    release_callback = Channel(Nil).new(1)
    read_entered = Channel(Nil).new(1)
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, _init : ConcurrentBdx::Wire::Init) do
      callback_entered.send(nil)
      release_callback.receive
      ConcurrentBdx::Responder::Source.new(IO::Memory.new(Bytes[1]), 1_u64).as(ConcurrentBdx::Responder::Source?)
    end
    cluster.on_read = -> do
      read_entered.send(nil)
      nil
    end

    init = ConcurrentBdx::Wire::Init.new(ConcurrentBdx::Wire::Opcode::ReceiveInit,
      ConcurrentBdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x61])
    bdx_message = Matter::Spec::ProtocolMessages.from_peer(bdx_session,
      init.opcode.value, init.to_slice, 1_u32, 7_u16,
      protocol_id: Matter::Protocol::ProtocolId::Bdx.value)
    inbound = transport.on_message
    inbound.should_not be_nil
    inbound.try(&.call(bdx_message, BDX_CONCURRENT_PEER))
    callback_started = false
    select
    when callback_entered.receive
      callback_started = true
    when timeout(2.seconds)
    end
    callback_started.should be_true

    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)
    read = Matter::InteractionModel::ReadRequestMessage.new(attribute_requests: [path])
    read_message = Matter::Spec::ProtocolMessages.from_peer(read_session,
      Matter::InteractionModel::MessageType::ReadRequest.value,
      read.to_slice, 1_u32, 8_u16)
    inbound.try(&.call(read_message, BDX_CONCURRENT_PEER))

    read_progressed = false
    select
    when read_entered.receive
      read_progressed = true
    when timeout(2.seconds)
    end
    release_callback.send(nil)
    handler.close

    read_progressed.should be_true
    response_session_ids = transport.sent_packets.map do |packet, _|
      Matter::Codec::MessageCodec::Base.decode_packet(packet).header.session_id
    end
    response_session_ids.should contain(read_session.peer_session_id)
  end

  it "removes a CASE session promptly while its BDX authorization callback waits" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    session = Matter::Spec::ProtocolMessages.case_session(283_u16)
    handler.sessions[session.session_id] = session
    callback_entered = Channel(Nil).new(1)
    release_callback = Channel(Nil).new(1)
    deleted = Channel(Bool).new(1)
    stream = IO::Memory.new(Bytes[1])
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, _init : ConcurrentBdx::Wire::Init) do
      callback_entered.send(nil)
      release_callback.receive
      ConcurrentBdx::Responder::Source.new(stream, 1_u64).as(ConcurrentBdx::Responder::Source?)
    end

    init = ConcurrentBdx::Wire::Init.new(ConcurrentBdx::Wire::Opcode::ReceiveInit,
      ConcurrentBdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x61])
    message = Matter::Spec::ProtocolMessages.from_peer(session,
      init.opcode.value, init.to_slice, 1_u32, 9_u16,
      protocol_id: Matter::Protocol::ProtocolId::Bdx.value)
    transport.on_message.try(&.call(message, BDX_CONCURRENT_PEER))
    select
    when callback_entered.receive
    when timeout(2.seconds)
      raise "BDX callback did not start"
    end

    spawn { deleted.send(handler.delete_session(session.session_id)) }
    removed_while_blocked = false
    select
    when removed_while_blocked = deleted.receive
    when timeout(2.seconds)
    end
    release_callback.send(nil)
    deadline = Time.instant + 2.seconds
    until stream.closed? || Time.instant >= deadline
      sleep 1.millisecond
    end
    handler.close

    removed_while_blocked.should be_true
    stream.closed?.should be_true
    transport.sent_packets.should be_empty
  end

  it "rejects excess queued BDX work with an encrypted busy status" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    session = Matter::Spec::ProtocolMessages.case_session(284_u16)
    handler.sessions[session.session_id] = session
    callback_entered = Channel(Nil).new(1)
    release_callback = Channel(Nil).new(1)
    first = true
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, _init : ConcurrentBdx::Wire::Init) do
      if first
        first = false
        callback_entered.send(nil)
        release_callback.receive
      end
      nil.as(ConcurrentBdx::Responder::Source?)
    end

    init = ConcurrentBdx::Wire::Init.new(ConcurrentBdx::Wire::Opcode::ReceiveInit,
      ConcurrentBdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x61])
    inbound = transport.on_message
    (1..(Matter::Protocol::MessageHandler::BDX_QUEUE_LIMIT + 2)).each do |number|
      message = Matter::Spec::ProtocolMessages.from_peer(session,
        init.opcode.value, init.to_slice, number.to_u32, number.to_u16,
        protocol_id: Matter::Protocol::ProtocolId::Bdx.value)
      inbound.try(&.call(message, BDX_CONCURRENT_PEER))
      if number == 1
        select
        when callback_entered.receive
        when timeout(2.seconds)
          raise "BDX callback did not start"
        end
      end
    end

    deadline = Time.instant + 2.seconds
    until transport.sent_packets.size == 1 || Time.instant >= deadline
      sleep 1.millisecond
    end
    response = concurrent_bdx_response(transport.sent_packets.first[0], session)
    report = Matter::Session::Pase::Definitions::StatusReport.from_bytes(response.payload)
    report.protocol_status.should eq(ConcurrentBdx::Transfer::StatusCode::ResponderBusy.value)
    release_callback.send(nil)
    handler.close
  end

  it "returns from shutdown when an application callback does not return" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    session = Matter::Spec::ProtocolMessages.case_session(285_u16)
    handler.sessions[session.session_id] = session
    callback_entered = Channel(Nil).new(1)
    release_callback = Channel(Nil).new(1)
    closed = Channel(Nil).new(1)
    stream = IO::Memory.new(Bytes[1])
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, _init : ConcurrentBdx::Wire::Init) do
      callback_entered.send(nil)
      release_callback.receive
      ConcurrentBdx::Responder::Source.new(stream, 1_u64).as(ConcurrentBdx::Responder::Source?)
    end

    init = ConcurrentBdx::Wire::Init.new(ConcurrentBdx::Wire::Opcode::ReceiveInit,
      ConcurrentBdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x61])
    message = Matter::Spec::ProtocolMessages.from_peer(session,
      init.opcode.value, init.to_slice, 1_u32, 10_u16,
      protocol_id: Matter::Protocol::ProtocolId::Bdx.value)
    transport.on_message.try(&.call(message, BDX_CONCURRENT_PEER))
    select
    when callback_entered.receive
    when timeout(2.seconds)
      raise "BDX callback did not start"
    end

    spawn do
      handler.close
      closed.send(nil)
    end
    shutdown_returned = false
    select
    when closed.receive
      shutdown_returned = true
    when timeout(2.seconds)
    end
    release_callback.send(nil)
    deadline = Time.instant + 2.seconds
    until stream.closed? || Time.instant >= deadline
      sleep 1.millisecond
    end

    shutdown_returned.should be_true
    stream.closed?.should be_true
    transport.sent_packets.should be_empty
  end
end
