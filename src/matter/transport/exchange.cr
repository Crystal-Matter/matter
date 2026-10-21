require "../codec/message_codec"
require "../error"

module Matter
  module Transport
    # One bidirectional conversation, identified within a session, peer, and
    # initiator direction by its exchange id.
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
      getter initial_message_type : UInt8?

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
        @initial_message_type : UInt8? = nil,
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
      # The exchange ID is chosen by an initiator within a session. A device
      # can receive the same numeric ID from another peer or direction while
      # its own controller exchange is still active.
      alias Key = Tuple(UInt16, UInt16, Bool, Socket::IPAddress)

      MAX_EXCHANGE_IDS   = UInt16::MAX.to_i + 1
      IPV4_MAPPED_PREFIX = "::ffff:"

      @exchanges : Hash(Key, Exchange)
      @next_exchange_id : UInt16

      def initialize
        @exchanges = Hash(Key, Exchange).new
        @next_exchange_id = Random.rand(UInt16).to_u16
      end

      # Create new exchange as initiator
      def create_exchange(
        protocol_id : UInt16 | UInt32,
        session_id : UInt16,
        peer_address : Socket::IPAddress,
        peer_node_id : DataType::NodeId? = nil,
        initial_message_type : UInt8? = nil,
      ) : Exchange
        MAX_EXCHANGE_IDS.times do
          exchange_id = @next_exchange_id
          @next_exchange_id = @next_exchange_id &+ 1
          key = exchange_key(session_id, exchange_id, true, peer_address)
          next if @exchanges.has_key?(key)

          exchange = Exchange.new(
            exchange_id: exchange_id,
            protocol_id: protocol_id,
            session_id: session_id,
            initiator: true,
            peer_address: peer_address,
            peer_node_id: peer_node_id,
            initial_message_type: initial_message_type
          )

          @exchanges[key] = exchange
          return exchange
        end
        raise Matter::ProtocolError.new("No exchange IDs are available for this session and peer")
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
        key = exchange_key(session_id, exchange_id, initiator, peer_address)
        if exchange = @exchanges[key]?
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

        @exchanges[key] = exchange
        exchange
      end

      # Use the scoped lookup when the same ID may exist on multiple sessions
      # or peers. The legacy lookup rejects ambiguity instead of guessing.
      def get_exchange(exchange_id : UInt16) : Exchange?
        matches = @exchanges.values.select { |exchange| exchange.exchange_id == exchange_id }
        raise Matter::ProtocolError.new("Ambiguous exchange ID #{exchange_id}") if matches.size > 1
        matches.first?
      end

      def get_exchange(exchange_id : UInt16, session_id : UInt16,
                       peer_address : Socket::IPAddress, initiator : Bool) : Exchange?
        @exchanges[exchange_key(session_id, exchange_id, initiator, peer_address)]?
      end

      # Close and remove an exchange. An unscoped close also rejects ambiguity.
      def close_exchange(exchange_id : UInt16) : Nil
        exchange = get_exchange(exchange_id)
        return unless exchange
        peer = exchange.peer_address
        raise Matter::ProtocolError.new("Exchange has no peer address") unless peer
        close_exchange(exchange_id, exchange.session_id, peer, exchange.initiator?)
      end

      def close_exchange(exchange_id : UInt16, session_id : UInt16,
                         peer_address : Socket::IPAddress, initiator : Bool) : Nil
        if exchange = @exchanges.delete(exchange_key(session_id, exchange_id, initiator, peer_address))
          exchange.close
        end
      end

      private def exchange_key(session_id : UInt16, exchange_id : UInt16, initiator : Bool,
                               peer_address : Socket::IPAddress) : Key
        address = peer_address.address
        peer = if address.starts_with?(IPV4_MAPPED_PREFIX)
                 Socket::IPAddress.new(address[IPV4_MAPPED_PREFIX.size..], peer_address.port)
               else
                 peer_address
               end
        {session_id, exchange_id, initiator, peer}
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
