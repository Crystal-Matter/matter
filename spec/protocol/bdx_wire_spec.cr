require "../spec_helper"
require "../../src/matter/protocol/bdx/wire"

private alias BdxWire = Matter::Protocol::Bdx::Wire

describe BdxWire do
  it "round trips a bounded ReceiveInit with a wide offset and definite length" do
    init = BdxWire::Init.new(
      BdxWire::Opcode::ReceiveInit,
      BdxWire::TransferControl::ReceiverDrive,
      1024_u16,
      "firmware.bin".to_slice,
      start_offset: 0x1_0000_0000_u64,
      length: 4096_u64,
    )

    wire = init.to_slice
    wire[0, 4].should eq Bytes[0x20, 0x13, 0x00, 0x04]
    BdxWire::Init.decode(BdxWire::Opcode::ReceiveInit, wire).should eq init
  end

  it "round trips ReceiveAccept, BlockQuery, BlockEOF and BlockAckEOF" do
    accept = BdxWire::Accept.new(BdxWire::Opcode::ReceiveAccept,
      BdxWire::TransferControl::SenderDrive, 512_u16, length: 513_u64)
    BdxWire::Accept.decode(BdxWire::Opcode::ReceiveAccept, accept.to_slice).should eq accept

    query = BdxWire::BlockCounterMessage.new(BdxWire::Opcode::BlockQuery, 0_u32)
    query.to_slice.should eq Bytes[0, 0, 0, 0]
    BdxWire::BlockCounterMessage.decode(BdxWire::Opcode::BlockQuery, query.to_slice).should eq query

    eof = BdxWire::BlockData.new(BdxWire::Opcode::BlockEOF, 1_u32, Bytes[0xaa])
    eof.to_slice.should eq Bytes[1, 0, 0, 0, 0xaa]
    BdxWire::BlockData.decode(BdxWire::Opcode::BlockEOF, eof.to_slice, max_block_size: 512).should eq eof
    ack = BdxWire::BlockCounterMessage.new(BdxWire::Opcode::BlockAckEOF, 1_u32)
    BdxWire::BlockCounterMessage.decode(BdxWire::Opcode::BlockAckEOF, ack.to_slice).should eq ack
    skip = BdxWire::BlockCounterMessage.new(BdxWire::Opcode::BlockQueryWithSkip, 2_u32,
      0x1_0000_0000_u64)
    skip.to_slice.should eq Bytes[2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]
    BdxWire::BlockCounterMessage.decode(BdxWire::Opcode::BlockQueryWithSkip, skip.to_slice).should eq skip
  end

  it "rejects malformed or unsupported control and block payloads" do
    expect_raises(Matter::CodecError) do
      BdxWire::Init.decode(BdxWire::Opcode::SendInit, Bytes[0, 0, 0, 0, 2, 0, 1])
    end
    expect_raises(Matter::CodecError) do
      BdxWire::Accept.decode(BdxWire::Opcode::ReceiveAccept, Bytes[0x41, 0, 1, 0])
    end
    expect_raises(Matter::CodecError) do
      BdxWire::BlockData.decode(BdxWire::Opcode::Block, Bytes[0, 0, 0, 0], max_block_size: 512)
    end
    expect_raises(Matter::CodecError) do
      BdxWire::BlockData.decode(BdxWire::Opcode::BlockEOF, Bytes[0, 0, 0, 0, 1, 2], max_block_size: 1)
    end
    expect_raises(Matter::CodecError) do
      BdxWire::BlockCounterMessage.decode(BdxWire::Opcode::BlockAck, Bytes[0, 0, 0, 0, 1])
    end
    expect_raises(Matter::CodecError) do
      BdxWire::Init.decode(BdxWire::Opcode::ReceiveInit, Bytes[0x20, 0x80, 1, 0, 0, 0])
    end
  end

  it "parses the provisional asynchronous Accept mode without selecting it for a transfer" do
    accept = BdxWire::Accept.decode(BdxWire::Opcode::ReceiveAccept, Bytes[0x40, 0, 0x00, 0x04])
    accept.transfer_control.should eq BdxWire::TransferControl::Async
    accept.max_block_size.should eq 1024_u16
  end
end
