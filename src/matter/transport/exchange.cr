require "../codec/message_codec"

module Matter
  module Transport
    # One bidirectional conversation, identified by its exchange id.
    #
    # The node answers every message that asks to be acknowledged inline, so an
    # exchange is bookkeeping rather than a queue: who the peer is, which
    # protocol and session it belongs to, and when it was last used, so idle
    # exchanges can be swept.
    class Exchange
      enum State
        Active
        Closed
        Failed
      end

      getter exchange_id : UInt16
      getter protocol_id : UInt32
      getter? initiator : Bool
      getter state : State
      getter peer_address : Socket::IPAddress?
      getter peer_node_id : DataType::NodeId?
      getter session_id : UInt16

      # How long an exchange may sit idle before the sweep reclaims it.
      IDLE_TIMEOUT = 30.seconds

      @last_activity : Time

      def initialize(
        @exchange_id : UInt16,
        protocol_id : UInt16 | UInt32,
        @session_id : UInt16,
        @initiator : Bool,
        @peer_address : Socket::IPAddress? = nil,
        @peer_node_id : DataType::NodeId? = nil,
      )
        @protocol_id = protocol_id.to_u32
        @state = State::Active
        @last_activity = Time.utc
      end

      # Mark exchange as closed
      def close : Nil
        @state = State::Closed
      end

      # Mark exchange as failed
      def fail : Nil
        @state = State::Failed
      end

      # Update activity timestamp
      def touch : Nil
        @last_activity = Time.utc
      end

      # Whether the exchange may be reclaimed: it is no longer active, or
      # nothing has been sent or received on it for `IDLE_TIMEOUT`.
      def stale?(now : Time = Time.utc) : Bool
        return true if @state != State::Active

        now - @last_activity > IDLE_TIMEOUT
      end
    end

    # Manages multiple exchanges
    class ExchangeManager
      @exchanges : Hash(UInt16, Exchange)
      @next_exchange_id : UInt16

      def initialize
        @exchanges = Hash(UInt16, Exchange).new
        @next_exchange_id = Random.rand(UInt16).to_u16
      end

      # Create new exchange as initiator
      def create_exchange(
        protocol_id : UInt16 | UInt32,
        session_id : UInt16,
        peer_address : Socket::IPAddress,
        peer_node_id : DataType::NodeId? = nil,
      ) : Exchange
        exchange_id = @next_exchange_id
        @next_exchange_id = @next_exchange_id &+ 1 # Wrap-around safe

        exchange = Exchange.new(
          exchange_id: exchange_id,
          protocol_id: protocol_id,
          session_id: session_id,
          initiator: true,
          peer_address: peer_address,
          peer_node_id: peer_node_id
        )

        @exchanges[exchange_id] = exchange
        exchange
      end

      # Get or create exchange for received message
      def get_or_create_exchange(
        exchange_id : UInt16,
        protocol_id : UInt16 | UInt32,
        session_id : UInt16,
        peer_address : Socket::IPAddress,
        peer_node_id : DataType::NodeId? = nil,
        initiator : Bool = false,
      ) : Exchange
        if exchange = @exchanges[exchange_id]?
          exchange.touch
          return exchange
        end

        # Create new exchange for incoming message
        exchange = Exchange.new(
          exchange_id: exchange_id,
          protocol_id: protocol_id,
          session_id: session_id,
          initiator: initiator,
          peer_address: peer_address,
          peer_node_id: peer_node_id
        )

        @exchanges[exchange_id] = exchange
        exchange
      end

      # Get exchange by ID
      def get_exchange(exchange_id : UInt16) : Exchange?
        @exchanges[exchange_id]?
      end

      # Close and remove exchange
      def close_exchange(exchange_id : UInt16) : Nil
        if exchange = @exchanges[exchange_id]?
          exchange.close
          @exchanges.delete(exchange_id)
        end
      end

      # Drops exchanges that are closed, failed, or long idle. Without this the
      # table only ever grows.
      def cleanup_stale_exchanges(now : Time = Time.utc) : Nil
        @exchanges.reject! { |_exchange_id, exchange| exchange.stale?(now) }
      end

      # Get count of active exchanges
      def active_count : Int32
        @exchanges.count { |_id, ex| ex.state == Exchange::State::Active }
      end
    end
  end
end
