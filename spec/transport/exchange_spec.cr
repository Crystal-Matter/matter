require "../spec_helper"
require "../../src/matter/transport/exchange"

describe Matter::Transport::Exchange do
  describe "#initialize" do
    it "creates active exchange" do
      exchange = Matter::Transport::Exchange.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        initiator: true
      )

      exchange.exchange_id.should eq(1_u16)
      exchange.protocol_id.should eq(0_u16)
      exchange.session_id.should eq(100_u16)
      exchange.initiator?.should be_true
      exchange.state.should eq(Matter::Transport::Exchange::State::Active)
    end

    it "stores peer information" do
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)
      peer_node_id = Matter::DataType::NodeId.new(12345_u64)

      exchange = Matter::Transport::Exchange.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        initiator: false,
        peer_address: peer_address,
        peer_node_id: peer_node_id
      )

      exchange.peer_address.should eq(peer_address)
      exchange.peer_node_id.should eq(peer_node_id)
      exchange.initiator?.should be_false
    end
  end

  describe "#close" do
    it "marks exchange as closed" do
      exchange = Matter::Transport::Exchange.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        initiator: true
      )

      exchange.close

      exchange.state.should eq(Matter::Transport::Exchange::State::Closed)
    end
  end

  describe "#fail" do
    it "marks exchange as failed" do
      exchange = Matter::Transport::Exchange.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        initiator: true
      )

      exchange.fail

      exchange.state.should eq(Matter::Transport::Exchange::State::Failed)
    end
  end

  describe "#stale?" do
    it "is fresh while active and recently used" do
      exchange = Matter::Transport::Exchange.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        initiator: true
      )

      exchange.stale?.should be_false
    end

    it "goes stale once idle for longer than the idle timeout" do
      exchange = Matter::Transport::Exchange.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        initiator: true
      )

      idle_timeout = Matter::Transport::Exchange::IDLE_TIMEOUT
      exchange.stale?(Time.utc + idle_timeout - 1.second).should be_false
      exchange.stale?(Time.utc + idle_timeout + 1.second).should be_true
    end

    it "is refreshed by traffic" do
      exchange = Matter::Transport::Exchange.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        initiator: true
      )

      idle_timeout = Matter::Transport::Exchange::IDLE_TIMEOUT
      later = Time.utc + idle_timeout + 1.second

      Timecop.travel(later) { exchange.touch }

      exchange.stale?(later).should be_false
    end

    it "is stale as soon as it is closed or failed" do
      closed = Matter::Transport::Exchange.new(1_u16, 0_u16, 100_u16, true)
      closed.close
      closed.stale?.should be_true

      failed = Matter::Transport::Exchange.new(2_u16, 0_u16, 100_u16, true)
      failed.fail
      failed.stale?.should be_true
    end
  end
end

describe Matter::Transport::ExchangeManager do
  describe "#create_exchange" do
    it "retains vendor-qualified protocol IDs" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)
      exchange = manager.create_exchange(0x1234_5678_u32, 100_u16, peer_address)
      exchange.protocol_id.should eq(0x1234_5678_u32)
    end

    it "creates new exchange as initiator" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      exchange = manager.create_exchange(
        protocol_id: 0_u16,
        session_id: 100_u16,
        peer_address: peer_address
      )

      exchange.should_not be_nil
      exchange.initiator?.should be_true
      exchange.protocol_id.should eq(0_u16)
      exchange.session_id.should eq(100_u16)
      exchange.peer_address.should eq(peer_address)
    end

    it "generates unique exchange IDs" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      exchange1 = manager.create_exchange(0_u16, 100_u16, peer_address)
      exchange2 = manager.create_exchange(0_u16, 100_u16, peer_address)
      exchange3 = manager.create_exchange(0_u16, 100_u16, peer_address)

      exchange1.exchange_id.should_not eq(exchange2.exchange_id)
      exchange2.exchange_id.should_not eq(exchange3.exchange_id)
      exchange1.exchange_id.should_not eq(exchange3.exchange_id)
    end
  end

  describe "#get_or_create_exchange" do
    it "creates new exchange if not exists" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      exchange = manager.get_or_create_exchange(
        exchange_id: 42_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        peer_address: peer_address,
        initiator: false
      )

      exchange.exchange_id.should eq(42_u16)
      exchange.initiator?.should be_false
    end

    it "returns existing exchange if found" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      exchange1 = manager.get_or_create_exchange(
        exchange_id: 42_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        peer_address: peer_address
      )

      exchange2 = manager.get_or_create_exchange(
        exchange_id: 42_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        peer_address: peer_address
      )

      exchange1.should be(exchange2) # Same object
    end

    it "updates activity on existing exchange, so traffic keeps it out of the sweep" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      exchange = manager.get_or_create_exchange(
        exchange_id: 42_u16,
        protocol_id: 0_u16,
        session_id: 100_u16,
        peer_address: peer_address
      )

      later = Time.utc + Matter::Transport::Exchange::IDLE_TIMEOUT + 1.second
      exchange.stale?(later).should be_true

      Timecop.travel(later) do
        manager.get_or_create_exchange(
          exchange_id: 42_u16,
          protocol_id: 0_u16,
          session_id: 100_u16,
          peer_address: peer_address
        )
      end

      exchange.stale?(later).should be_false
    end
  end

  describe "#get_exchange" do
    it "returns exchange if exists" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      created = manager.create_exchange(0_u16, 100_u16, peer_address)
      found = manager.get_exchange(created.exchange_id)

      found.should eq(created)
    end

    it "returns nil if not exists" do
      manager = Matter::Transport::ExchangeManager.new

      found = manager.get_exchange(999_u16)

      found.should be_nil
    end
  end

  describe "#close_exchange" do
    it "closes and removes exchange" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      exchange = manager.create_exchange(0_u16, 100_u16, peer_address)
      manager.close_exchange(exchange.exchange_id)

      manager.get_exchange(exchange.exchange_id).should be_nil
      exchange.state.should eq(Matter::Transport::Exchange::State::Closed)
    end

    it "handles closing non-existent exchange" do
      manager = Matter::Transport::ExchangeManager.new

      # Should not raise
      manager.close_exchange(999_u16)
    end
  end

  describe "#active_count" do
    it "counts active exchanges" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      manager.active_count.should eq(0)

      ex1 = manager.create_exchange(0_u16, 100_u16, peer_address)
      manager.active_count.should eq(1)

      ex2 = manager.create_exchange(0_u16, 100_u16, peer_address)
      manager.active_count.should eq(2)

      ex1.close
      manager.active_count.should eq(1)

      ex2.fail
      manager.active_count.should eq(0)
    end
  end

  describe "#cleanup_stale_exchanges" do
    it "removes failed exchanges" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      exchange = manager.create_exchange(0_u16, 100_u16, peer_address)
      exchange.fail

      manager.cleanup_stale_exchanges

      manager.get_exchange(exchange.exchange_id).should be_nil
    end

    it "reclaims idle exchanges so the table cannot grow without bound" do
      manager = Matter::Transport::ExchangeManager.new
      peer_address = Socket::IPAddress.new("192.168.1.100", 5540)

      idle = manager.create_exchange(0_u16, 100_u16, peer_address)
      later = Time.utc + Matter::Transport::Exchange::IDLE_TIMEOUT + 1.second

      # A second exchange that saw traffic just before the sweep survives it.
      busy = manager.create_exchange(0_u16, 100_u16, peer_address)
      Timecop.travel(later) { busy.touch }

      manager.cleanup_stale_exchanges(later)

      manager.get_exchange(idle.exchange_id).should be_nil
      manager.get_exchange(busy.exchange_id).should_not be_nil
    end
  end
end
