require "../spec_helper"
require "../../src/matter/protocol/bdx/responder"

private alias Bdx = Matter::Protocol::Bdx

private def bdx_case_session(id : UInt16 = 1_u16) : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: id, peer_session_id: 2_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 1_u8), decryption_key: Bytes.new(16, 2_u8),
    peer_node_id: Matter::DataType::NodeId.new(0x123_u64),
    case_session: true, fabric_index: 1_u8)
end

describe Bdx::Responder do
  it "downloads a named source only after its CASE authorization callback accepts it" do
    responder = Bdx::Responder.new
    responder.on_download = ->(session : Matter::Session::SecureContext, init : Bdx::Wire::Init) do
      if session.fabric_index == 1_u8 && init.file_designator == Bytes[0x66]
        Bdx::Responder::Source.new(IO::Memory.new(Bytes[1, 2, 3]), 3_u64)
      end
    end
    session = bdx_case_session
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x66])
    result = responder.receive(session, 17_u16, init.opcode, init.to_slice)
    result.message.as(Bdx::Wire::Accept).opcode.should eq(Bdx::Wire::Opcode::ReceiveAccept)
    result = responder.receive(session, 17_u16, Bdx::Wire::Opcode::BlockQuery,
      Bdx::Wire::BlockCounterMessage.new(Bdx::Wire::Opcode::BlockQuery, 0_u32).to_slice)
    result.message.as(Bdx::Wire::BlockData).data.should eq(Bytes[1, 2])
    result = responder.receive(session, 17_u16, Bdx::Wire::Opcode::BlockQuery,
      Bdx::Wire::BlockCounterMessage.new(Bdx::Wire::Opcode::BlockQuery, 1_u32).to_slice)
    result.message.as(Bdx::Wire::BlockData).opcode.should eq(Bdx::Wire::Opcode::BlockEOF)
    responder.receive(session, 17_u16, Bdx::Wire::Opcode::BlockAckEOF,
      Bdx::Wire::BlockCounterMessage.new(Bdx::Wire::Opcode::BlockAckEOF, 1_u32).to_slice).ack_only?.should be_true
    responder.active_count.should eq(0)
  end

  it "defaults to sender drive when the peer offers both modes" do
    responder = Bdx::Responder.new
    responder.on_download = ->(_session : Matter::Session::SecureContext, _init : Bdx::Wire::Init) do
      Bdx::Responder::Source.new(IO::Memory.new(Bytes[1]), 1_u64).as(Bdx::Responder::Source?)
    end
    both = Bdx::Wire::TransferControl::SenderDrive | Bdx::Wire::TransferControl::ReceiverDrive
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit, both, 2_u16, Bytes[0x66])
    result = responder.receive(bdx_case_session, 19_u16, init.opcode, init.to_slice)
    result.message.as(Bdx::Wire::Accept).transfer_control.should eq(Bdx::Wire::TransferControl::SenderDrive)
    result.follow_up.as(Bdx::Wire::BlockData).opcode.should eq(Bdx::Wire::Opcode::BlockEOF)
  end

  it "keeps an active transfer when its peer sends a malformed duplicate init" do
    responder = Bdx::Responder.new
    stream = IO::Memory.new(Bytes[1, 2])
    responder.on_download = ->(_session : Matter::Session::SecureContext, _init : Bdx::Wire::Init) do
      Bdx::Responder::Source.new(stream, 2_u64).as(Bdx::Responder::Source?)
    end
    session = bdx_case_session
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x66])
    responder.receive(session, 17_u16, init.opcode, init.to_slice).message.should be_a(Bdx::Wire::Accept)
    responder.receive(session, 17_u16, init.opcode, Bytes[0]).status
      .should eq(Bdx::Transfer::StatusCode::UnexpectedMessage)
    stream.closed?.should be_false
    query = Bdx::Wire::BlockCounterMessage.new(Bdx::Wire::Opcode::BlockQuery, 0_u32)
    responder.receive(session, 17_u16, query.opcode, query.to_slice).message
      .as(Bdx::Wire::BlockData).data.should eq(Bytes[1, 2])
    responder.close
  end

  it "supports receiver-driven uploads when that is the only proposed mode" do
    responder = Bdx::Responder.new
    sink = IO::Memory.new
    responder.on_upload = ->(_session : Matter::Session::SecureContext, _init : Bdx::Wire::Init) do
      sink.as(IO?)
    end
    session = bdx_case_session
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::SendInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x75], length: 1_u64)
    step = responder.receive(session, 20_u16, init.opcode, init.to_slice)
    step.message.as(Bdx::Wire::Accept).transfer_control.should eq(Bdx::Wire::TransferControl::ReceiverDrive)
    step.follow_up.as(Bdx::Wire::BlockCounterMessage).opcode.should eq(Bdx::Wire::Opcode::BlockQuery)
    eof = Bdx::Wire::BlockData.new(Bdx::Wire::Opcode::BlockEOF, 0_u32, Bytes[9])
    responder.receive(session, 20_u16, eof.opcode, eof.to_slice).message
      .as(Bdx::Wire::BlockCounterMessage).opcode.should eq(Bdx::Wire::Opcode::BlockAckEOF)
    sink.to_slice.should eq(Bytes[9])
    responder.active_count.should eq(0)
  end

  it "rejects unregistered designators, wrong sessions, and unsupported offsets" do
    responder = Bdx::Responder.new
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x66])
    responder.receive(bdx_case_session, 17_u16, init.opcode, init.to_slice).status.should eq(Bdx::Transfer::StatusCode::FileDesignatorUnknown)

    responder.on_download = ->(_session : Matter::Session::SecureContext, _init : Bdx::Wire::Init) do
      Bdx::Responder::Source.new(IO::Memory.new(Bytes[1]), 1_u64).as(Bdx::Responder::Source?)
    end
    offset = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x66], start_offset: 1_u64)
    responder.receive(bdx_case_session, 17_u16, offset.opcode, offset.to_slice).status.should eq(Bdx::Transfer::StatusCode::StartOffsetNotSupported)
    responder.receive(bdx_case_session, 17_u16, init.opcode, init.to_slice).message.should be_a(Bdx::Wire::Accept)
    responder.receive(bdx_case_session(3_u16), 17_u16, Bdx::Wire::Opcode::BlockQuery,
      Bdx::Wire::BlockCounterMessage.new(Bdx::Wire::Opcode::BlockQuery, 0_u32).to_slice).status.should eq(Bdx::Transfer::StatusCode::UnexpectedMessage)
  end

  it "uploads to an authorized stream, rejects excess length, and clears finished state" do
    sink = IO::Memory.new
    responder = Bdx::Responder.new
    responder.on_upload = ->(_session : Matter::Session::SecureContext, init : Bdx::Wire::Init) do
      init.file_designator == Bytes[0x75] ? sink.as(IO) : nil
    end
    session = bdx_case_session
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::SendInit,
      Bdx::Wire::TransferControl::SenderDrive, 3_u16, Bytes[0x75], length: 2_u64)
    responder.receive(session, 18_u16, init.opcode, init.to_slice).message.as(Bdx::Wire::Accept).opcode.should eq(Bdx::Wire::Opcode::SendAccept)
    block = Bdx::Wire::BlockData.new(Bdx::Wire::Opcode::BlockEOF, 0_u32, Bytes[4, 5])
    responder.receive(session, 18_u16, block.opcode, block.to_slice).message.as(Bdx::Wire::BlockCounterMessage).opcode.should eq(Bdx::Wire::Opcode::BlockAckEOF)
    sink.to_slice.should eq(Bytes[4, 5])
    responder.active_count.should eq(0)
  end

  it "closes streams that remain idle past the bounded transfer window" do
    responder = Bdx::Responder.new
    stream = IO::Memory.new(Bytes[1])
    responder.on_download = ->(_session : Matter::Session::SecureContext, _init : Bdx::Wire::Init) do
      Bdx::Responder::Source.new(stream, 1_u64).as(Bdx::Responder::Source?)
    end
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x66])
    responder.receive(bdx_case_session, 17_u16, init.opcode, init.to_slice)
    responder.active_count.should eq(1)
    responder.sweep(Time.instant + Bdx::Responder::IDLE_TIMEOUT + 1.second)
    responder.active_count.should eq(0)
    stream.closed?.should be_true
  end

  it "reserves capacity during authorization and frees a cancelled reservation" do
    responder = Bdx::Responder.new
    entered = Channel(UInt16).new(5)
    release = Channel(Nil).new(5)
    results = Channel(Bdx::Responder::Step).new(5)
    responder.on_download = ->(session : Matter::Session::SecureContext, _init : Bdx::Wire::Init) do
      entered.send(session.session_id)
      release.receive
      Bdx::Responder::Source.new(IO::Memory.new(Bytes[1]), 1_u64).as(Bdx::Responder::Source?)
    end
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x66])
    sessions = (1..5).map { |id| bdx_case_session(id.to_u16) }
    sessions.first(4).each do |session|
      spawn { results.send(responder.receive(session, 17_u16, init.opcode, init.to_slice)) }
    end
    4.times do
      select
      when entered.receive
      when timeout(5.seconds)
        raise "BDX authorization did not start"
      end
    end
    responder.active_count.should eq(4)
    responder.receive(sessions[4], 17_u16, init.opcode, init.to_slice).status
      .should eq(Bdx::Transfer::StatusCode::ResponderBusy)

    responder.forget_session(sessions[0])
    responder.active_count.should eq(3)
    spawn { results.send(responder.receive(sessions[4], 17_u16, init.opcode, init.to_slice)) }
    select
    when resumed = entered.receive
      resumed.should eq(sessions[4].session_id)
    when timeout(5.seconds)
      raise "released BDX capacity was not reused"
    end
    responder.active_count.should eq(4)
    5.times { release.send(nil) }
    responses = Array.new(5) do
      select
      when response = results.receive
        response
      when timeout(5.seconds)
        raise "BDX authorization did not finish"
      end
    end
    responses.count { |step| step.message.is_a?(Bdx::Wire::Accept) }.should eq(4)
    responses.count { |step| step.status == Bdx::Transfer::StatusCode::UnexpectedMessage }.should eq(1)
    responder.close
  end

  it "treats requested length zero as indefinite while enforcing its local cap" do
    responder = Bdx::Responder.new
    responder.max_transfer_bytes = 2_u64
    responder.on_download = ->(_session : Matter::Session::SecureContext, _init : Bdx::Wire::Init) do
      Bdx::Responder::Source.new(IO::Memory.new(Bytes[1, 2, 3]), nil).as(Bdx::Responder::Source?)
    end
    session = bdx_case_session
    init = Bdx::Wire::Init.new(Bdx::Wire::Opcode::ReceiveInit,
      Bdx::Wire::TransferControl::ReceiverDrive, 4_u16, Bytes[0x66], length: 0_u64)
    responder.receive(session, 24_u16, init.opcode, init.to_slice).message.should be_a(Bdx::Wire::Accept)
    query = Bdx::Wire::BlockCounterMessage.new(Bdx::Wire::Opcode::BlockQuery, 0_u32)
    responder.receive(session, 24_u16, query.opcode, query.to_slice).status
      .should eq(Bdx::Transfer::StatusCode::LengthTooLarge)
    responder.active_count.should eq(0)
  end
end
