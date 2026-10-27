require "../spec_helper"
require "../../src/matter/transport/message_counter"

describe Matter::Transport::MessageCounter do
  describe "#next" do
    it "refuses to emit a counter outside a reserved range even at wrap" do
      counter = Matter::Transport::MessageCounter.new(UInt32::MAX - 1_u32)
      counter.limit_messages(2_u32)

      counter.next.should eq(UInt32::MAX)
      counter.next.should eq(0_u32)
      expect_raises(Matter::SessionError) { counter.next }
    end

    it "generates sequential message IDs" do
      counter = Matter::Transport::MessageCounter.new(0_u32)

      counter.next.should eq(1_u32)
      counter.next.should eq(2_u32)
      counter.next.should eq(3_u32)
    end

    it "wraps around at UInt32 max" do
      counter = Matter::Transport::MessageCounter.new(UInt32::MAX - 1)

      counter.next.should eq(UInt32::MAX)
      counter.next.should eq(0_u32)
      counter.next.should eq(1_u32)
    end

    it "starts from specified value" do
      counter = Matter::Transport::MessageCounter.new(100_u32)

      counter.next.should eq(101_u32)
      counter.next.should eq(102_u32)
    end
  end

  describe "#valid?" do
    it "accepts first message" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(1_u32).should be_true
    end

    it "accepts messages in order" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(1_u32).should be_true
      counter.valid?(2_u32).should be_true
      counter.valid?(3_u32).should be_true
    end

    it "rejects duplicate messages" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(1_u32).should be_true
      counter.valid?(2_u32).should be_true
      counter.valid?(1_u32).should be_false # Duplicate
      counter.valid?(2_u32).should be_false # Duplicate
    end

    it "accepts messages that arrive out of order within window" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(10_u32).should be_true
      counter.valid?(12_u32).should be_true
      counter.valid?(11_u32).should be_true # Out of order but within window
      counter.valid?(13_u32).should be_true
    end

    it "rejects messages outside window" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(100_u32).should be_true
      counter.valid?(101_u32).should be_true

      # Message too old (outside 64-message window)
      counter.valid?(35_u32).should be_false
      counter.valid?(30_u32).should be_false
    end

    it "handles messages that skip ahead" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(1_u32).should be_true
      counter.valid?(50_u32).should be_true  # Big jump
      counter.valid?(100_u32).should be_true # Even bigger jump (max = 100, window = [36, 100])

      # Message 25 is now outside window (100 - 64 = 36, so < 36 is outside)
      counter.valid?(25_u32).should be_false
      counter.valid?(35_u32).should be_false

      # Message 36 is at window edge - should be accepted
      counter.valid?(36_u32).should be_true
    end

    it "cleans up old entries from window" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(1_u32).should be_true
      counter.valid?(2_u32).should be_true

      # Jump ahead - should clean window
      counter.valid?(100_u32).should be_true

      # Old messages should be rejected
      counter.valid?(1_u32).should be_false
      counter.valid?(2_u32).should be_false

      # Messages within new window should work
      counter.valid?(99_u32).should be_true
      counter.valid?(101_u32).should be_true
    end

    it "handles edge case at window boundary" do
      counter = Matter::Transport::MessageCounter.new

      counter.valid?(100_u32).should be_true

      # Exactly at window edge (100 - 64 = 36)
      counter.valid?(36_u32).should be_true

      # Just outside window
      counter.valid?(35_u32).should be_false
    end
  end

  describe "#check" do
    it "rejects secure-session rollover when rollover is disabled" do
      counter = Matter::Transport::MessageCounter.new(rollover: false)
      counter.check(UInt32::MAX).accept?.should be_true
      counter.check(0_u32).stale?.should be_true
    end

    it "accepts rollover and rejects duplicate and stale counters across it" do
      counter = Matter::Transport::MessageCounter.new
      counter.check(UInt32::MAX - 1_u32).accept?.should be_true
      counter.check(UInt32::MAX).accept?.should be_true
      counter.check(0_u32).accept?.should be_true
      counter.check(1_u32).accept?.should be_true
      counter.check(UInt32::MAX).duplicate?.should be_true
      counter.check(UInt32::MAX - 65_u32).stale?.should be_true
    end

    it "recognizes a duplicate zero counter" do
      counter = Matter::Transport::MessageCounter.new
      counter.check(0_u32).accept?.should be_true
      counter.check(0_u32).duplicate?.should be_true
    end
  end

  describe "#peek" do
    it "checks without committing before authentication" do
      counter = Matter::Transport::MessageCounter.new
      counter.peek(100_u32).accept?.should be_true
      counter.peek(1_u32).accept?.should be_true
      counter.max_received.should be_nil
    end

    it "does not advance the window" do
      counter = Matter::Transport::MessageCounter.new
      counter.check(10_u32).accept?.should be_true

      counter.peek(11_u32).accept?.should be_true
      counter.peek(11_u32).accept?.should be_true # still unseen, so not a duplicate
      counter.max_received.should eq(10_u32)

      counter.check(11_u32).accept?.should be_true
      counter.check(11_u32).duplicate?.should be_true
      counter.max_received.should eq(11_u32)
    end
  end

  describe "#restore_received" do
    it "keeps a restored floor across UInt32 rollover" do
      counter = Matter::Transport::MessageCounter.new
      counter.restore_received(UInt32::MAX)

      counter.check(UInt32::MAX).stale?.should be_true
      counter.check(UInt32::MAX - 1_u32).stale?.should be_true
      counter.check(0_u32).accept?.should be_true
      counter.check(0_u32).duplicate?.should be_true
    end

    it "installs a floor so the restored counter and older ones are stale" do
      counter = Matter::Transport::MessageCounter.new
      counter.restore_received(100_u32)

      counter.max_received.should eq(100_u32)
      counter.check(99_u32).stale?.should be_true
      counter.check(100_u32).stale?.should be_true
      counter.check(101_u32).accept?.should be_true
      counter.check(101_u32).duplicate?.should be_true
    end
  end

  describe "#maximum" do
    it "raises at exhaustion when rollover is disabled" do
      counter = Matter::Transport::MessageCounter.new(0_u32, rollover: false)
      counter.maximum = 2_u32

      counter.next.should eq(1_u32)
      counter.next.should eq(2_u32)
      expect_raises(Matter::SessionError, /renegotiated/) { counter.next }
      counter.counter.should eq(2_u32)
    end

    it "wraps to zero at the maximum when rollover is enabled" do
      counter = Matter::Transport::MessageCounter.new(0_u32)
      counter.maximum = 2_u32

      counter.next.should eq(1_u32)
      counter.next.should eq(2_u32)
      counter.next.should eq(0_u32)
    end
  end

  describe "#mark_received" do
    it "marks message as received" do
      counter = Matter::Transport::MessageCounter.new

      counter.mark_received(1_u32)
      counter.valid?(1_u32).should be_false # Already marked
      counter.valid?(2_u32).should be_true  # Not marked yet
    end
  end

  describe "#reset" do
    it "resets counter to zero" do
      counter = Matter::Transport::MessageCounter.new(100_u32)
      counter.next
      counter.valid?(50_u32)

      counter.reset

      counter.counter.should eq(0_u32)
      counter.next.should eq(1_u32)
      counter.valid?(50_u32).should be_true # Window cleared
    end

    it "resets counter to specified value" do
      counter = Matter::Transport::MessageCounter.new

      counter.reset(500_u32)

      counter.counter.should eq(500_u32)
      counter.next.should eq(501_u32)
    end
  end

  describe "replay attack protection" do
    it "prevents replay attacks with old message IDs" do
      counter = Matter::Transport::MessageCounter.new

      # Legitimate message sequence
      (1..100).each do |i|
        counter.valid?(i.to_u32).should be_true
      end

      # Attacker tries to replay old messages
      counter.valid?(1_u32).should be_false
      counter.valid?(10_u32).should be_false
      counter.valid?(30_u32).should be_false

      # Only recent messages are accepted
      counter.valid?(99_u32).should be_false # Duplicate
      counter.valid?(101_u32).should be_true # New message
    end
  end

  describe "window size" do
    it "maintains exactly WINDOW_SIZE recent messages" do
      counter = Matter::Transport::MessageCounter.new
      window_size = Matter::Transport::MessageCounter::WINDOW_SIZE

      # Fill window
      counter.valid?(100_u32).should be_true
      (101_u32...(100 + window_size).to_u32).each do |i|
        counter.valid?(i).should be_true
      end

      # Messages at window edge should work
      counter.valid?(100_u32).should be_false # Duplicate
      counter.valid?(101_u32).should be_false # Duplicate

      # Move window forward
      counter.valid?((100 + window_size).to_u32).should be_true

      # Message 100 should now be outside window
      counter.valid?(100_u32).should be_false
    end
  end
end
