require "../spec_helper"

private alias Btp = Matter::Transport::BtpCodec
private alias Session = Matter::Transport::BtpSession

describe Matter::Transport::BtpSession do
  it "segments a Matter message within the negotiated fragment size" do
    session = Session.new(Session::Role::Central, 20, 4)
    message = Bytes.new(30, &.to_u8)
    session.queue_message(message)
    frames = session.drain_outgoing
    frames.size.should eq(2)
    frames.max_of(&.size).should be <= 20
    first = Btp.decode_packet(frames[0])
    second = Btp.decode_packet(frames[1])
    first.flags.includes?(Btp::Flags::Begin).should be_true
    first.flags.includes?(Btp::Flags::Ack).should be_true # acknowledges handshake response
    first.ack_number.should eq(0_u8)
    first.message_length.should eq(30_u16)
    second.flags.includes?(Btp::Flags::Continue).should be_true
    second.flags.includes?(Btp::Flags::End).should be_true
    (first.payload.to_a + second.payload.to_a).should eq(message.to_a)
  end

  it "reserves the last remote-window slot until an ACK reopens it" do
    session = Session.new(Session::Role::Central, 244, 4)
    6.times { session.queue_message(Bytes[0x01, 0x02]) }
    first = session.drain_outgoing
    first.map { |frame| Btp.decode_packet(frame).sequence_number }.should eq([0_u8, 1_u8, 2_u8])
    # A data-only packet cannot consume the reserved last slot.
    session.drain_outgoing.should be_empty
    session.receive_packet("080201".hexbytes).should be_nil # peer seq 1 acknowledges our seq 2
    remaining = session.drain_outgoing
    remaining.map { |frame| Btp.decode_packet(frame).sequence_number }.should eq([3_u8, 4_u8, 5_u8])
  end

  it "reassembles ordered incoming fragments and rejects a sequence gap" do
    session = Session.new(Session::Role::Peripheral, 20, 6)
    begin_frame = Btp.encode_packet(Btp::Packet.new(Btp::Flags::Begin, 0_u8, nil, 4_u16, Bytes[1, 2]))
    end_frame = Btp.encode_packet(Btp::Packet.new(Btp::Flags::Continue | Btp::Flags::End,
      1_u8, nil, nil, Bytes[3, 4]))
    session.receive_packet(begin_frame).should be_nil
    session.receive_packet(end_frame).should eq(Bytes[1, 2, 3, 4])
    expect_raises(Matter::ProtocolError) { session.receive_packet(end_frame) }
    session.closed?.should be_true
  end

  it "rejects a continuation that exceeds the declared message length" do
    session = Session.new(Session::Role::Peripheral, 20, 6)
    session.receive_packet(Btp.encode_packet(Btp::Packet.new(Btp::Flags::Begin,
      0_u8, nil, 3_u16, Bytes[1, 2])))
    expect_raises(Matter::ProtocolError) do
      session.receive_packet(Btp.encode_packet(Btp::Packet.new(Btp::Flags::Continue | Btp::Flags::End,
        1_u8, nil, nil, Bytes[3, 4])))
    end
    session.closed?.should be_true
  end

  it "sends one standalone ACK when the local receive window gets low" do
    session = Session.new(Session::Role::Peripheral, 20, 6)
    4.times do |index|
      session.receive_packet(Btp.encode_packet(Btp::Packet.new(Btp::Flags::Begin | Btp::Flags::End,
        index.to_u8, nil, 1_u16, Bytes[1])))
    end
    session.ack_urgent?.should be_true
    ack = session.send_ack
    ack.should_not be_nil
    decoded = Btp.decode_packet(ack.as(Bytes))
    decoded.flags.should eq(Btp::Flags::Ack)
    decoded.ack_number.should eq(3_u8)
    session.send_ack.should be_nil
  end

  it "rejects an acknowledgement for an unsent sequence number" do
    session = Session.new(Session::Role::Central, 20, 4)
    session.queue_message(Bytes[1])
    session.drain_outgoing
    expect_raises(Matter::ProtocolError) do
      session.receive_packet(Btp.encode_packet(Btp::Packet.new(Btp::Flags::Ack,
        1_u8, 9_u8, nil, Bytes.empty)))
    end
    session.closed?.should be_true
  end

  it "rejects input beyond its receive window until it sends an ACK" do
    session = Session.new(Session::Role::Peripheral, 20, 2)
    2.times do |index|
      packet = Btp::Packet.new(Btp::Flags::Begin | Btp::Flags::End,
        index.to_u8, nil, 1_u16, Bytes[1])
      session.receive_packet(Btp.encode_packet(packet)).should eq(Bytes[1])
    end
    expect_raises(Matter::ProtocolError, /window/) do
      session.receive_packet(Btp.encode_packet(Btp::Packet.new(Btp::Flags::Begin | Btp::Flags::End,
        2_u8, nil, 1_u16, Bytes[1])))
    end
  end

  it "keeps the receive-window count correct across sequence wraparound" do
    session = Session.new(Session::Role::Peripheral, 20, 255)
    255.times do |index|
      packet = Btp::Packet.new(Btp::Flags::Begin | Btp::Flags::End,
        index.to_u8, nil, 1_u16, Bytes[1])
      session.receive_packet(Btp.encode_packet(packet)).should eq(Bytes[1])
    end
    session.send_ack.should_not be_nil

    255.times do |offset|
      packet = Btp::Packet.new(Btp::Flags::Begin | Btp::Flags::End,
        offset.to_u8 &+ 255_u8, nil, 1_u16, Bytes[1])
      session.receive_packet(Btp.encode_packet(packet)).should eq(Bytes[1])
    end
    expect_raises(Matter::ProtocolError, /window/) do
      session.receive_packet(Btp.encode_packet(Btp::Packet.new(Btp::Flags::Begin | Btp::Flags::End,
        254_u8, nil, 1_u16, Bytes[1])))
    end
  end

  it "waits for the central to acknowledge the peripheral handshake when the window is one" do
    session = Session.new(Session::Role::Peripheral, 20, 1)
    session.queue_message(Bytes[1, 2])
    session.drain_outgoing.should be_empty
    session.receive_packet(Btp.encode_packet(Btp::Packet.new(Btp::Flags::Ack,
      0_u8, 0_u8, nil, Bytes.empty))).should be_nil
    sent = session.drain_outgoing
    sent.size.should eq(1)
    data = Btp.decode_packet(sent.first)
    data.sequence_number.should eq(1_u8)
    data.ack_number.should eq(0_u8)
  end

  it "sends a delayed standalone handshake ACK when no data can carry it" do
    now = Time.instant
    session = Session.new(Session::Role::Central, 20, 4, now: now)
    session.poll(now + 4.seconds).should be_nil
    frame = session.poll(now + 5.seconds).as(Bytes)
    packet = Btp.decode_packet(frame)
    packet.flags.should eq(Btp::Flags::Ack)
    packet.ack_number.should eq(0_u8)
    session.poll(now + 6.seconds).should be_nil
  end

  it "closes when a sent segment is not acknowledged in time" do
    now = Time.instant
    session = Session.new(Session::Role::Central, 20, 4, now: now)
    session.queue_message(Bytes[1])
    session.drain_outgoing(now)
    expect_raises(Matter::TimeoutError, /ACK/) { session.poll(now + 16.seconds) }
    session.closed?.should be_true
  end
end
