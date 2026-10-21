require "../spec_helper"
require "../../src/matter/protocol/bdx/transfer"

private alias BdxTransfer = Matter::Protocol::Bdx::Transfer
private alias BdxWire = Matter::Protocol::Bdx::Wire

describe BdxTransfer do
  it "downloads with a receiver-driven transfer and acknowledges the final block" do
    source = IO::Memory.new(Bytes[1, 2, 3, 4, 5])
    sink = IO::Memory.new
    sender = BdxTransfer.sender(source, 4_u16, BdxTransfer::Drive::Receiver, length: 5_u64)
    receiver = BdxTransfer.receiver(sink, 4_u16, BdxTransfer::Drive::Receiver, length: 5_u64)

    sender.start.should be_nil
    query = receiver.start.as(BdxWire::BlockCounterMessage)
    query.counter.should eq 0_u32
    block = sender.receive(query).as(BdxWire::BlockData)
    block.opcode.should eq BdxWire::Opcode::Block
    block.data.should eq Bytes[1, 2, 3, 4]
    query = receiver.receive(block).as(BdxWire::BlockCounterMessage)
    query.counter.should eq 1_u32
    eof = sender.receive(query).as(BdxWire::BlockData)
    eof.opcode.should eq BdxWire::Opcode::BlockEOF
    eof.data.should eq Bytes[5]
    ack = receiver.receive(eof).as(BdxWire::BlockCounterMessage)
    ack.opcode.should eq BdxWire::Opcode::BlockAckEOF
    sender.receive(ack).should be_nil
    sender.complete?.should be_true
    receiver.complete?.should be_true
    sink.to_slice.should eq Bytes[1, 2, 3, 4, 5]
  end

  it "uploads with a sender-driven transfer and accepts a zero-byte EOF" do
    source = IO::Memory.new(Bytes[1, 2, 3, 4])
    sink = IO::Memory.new
    sender = BdxTransfer.sender(source, 4_u16, BdxTransfer::Drive::Sender, length: 4_u64)
    receiver = BdxTransfer.receiver(sink, 4_u16, BdxTransfer::Drive::Sender, length: 4_u64)

    receiver.start.should be_nil
    block = sender.start.as(BdxWire::BlockData)
    block.opcode.should eq BdxWire::Opcode::Block
    ack = receiver.receive(block).as(BdxWire::BlockCounterMessage)
    ack.opcode.should eq BdxWire::Opcode::BlockAck
    eof = sender.receive(ack).as(BdxWire::BlockData)
    eof.opcode.should eq BdxWire::Opcode::BlockEOF
    eof.data.should be_empty
    final_ack = receiver.receive(eof).as(BdxWire::BlockCounterMessage)
    sender.receive(final_ack).should be_nil
    sender.complete?.should be_true
    receiver.complete?.should be_true
    sink.to_slice.should eq Bytes[1, 2, 3, 4]
  end

  it "rejects out-of-order counters and an early EOF against definite length" do
    sink = IO::Memory.new
    receiver = BdxTransfer.receiver(sink, 4_u16, BdxTransfer::Drive::Sender, length: 5_u64)
    receiver.start.should be_nil
    expect_raises(BdxTransfer::Error) do
      receiver.receive(BdxWire::BlockData.new(BdxWire::Opcode::Block, 1_u32, Bytes[1]))
    end

    receiver = BdxTransfer.receiver(IO::Memory.new, 4_u16, BdxTransfer::Drive::Sender, length: 5_u64)
    receiver.start.should be_nil
    expect_raises(BdxTransfer::Error) do
      receiver.receive(BdxWire::BlockData.new(BdxWire::Opcode::BlockEOF, 0_u32, Bytes[1]))
    end

    sender = BdxTransfer.sender(IO::Memory.new(Bytes[1]), 4_u16,
      BdxTransfer::Drive::Sender, length: 5_u64)
    sender.start.as(BdxWire::BlockData).opcode.should eq BdxWire::Opcode::Block
    expect_raises(BdxTransfer::Error) do
      sender.receive(BdxWire::BlockCounterMessage.new(BdxWire::Opcode::BlockAck, 0_u32))
    end
  end
end
