require "../../src/matter/transport/udp_transport"

module Matter
  module Spec
    # A `Transport::UDPTransport` that binds no socket and records what would
    # have gone out on the wire.
    #
    # Specs that exercise the protocol layer need a transport, not a network;
    # binding a real UDP socket is both slow and unavailable in some sandboxes.
    class CaptureTransport < Transport::UDPTransport
      getter sent_packets : Array(Tuple(Bytes, Socket::IPAddress)) = [] of Tuple(Bytes, Socket::IPAddress)

      def self.new_for_spec : self
        transport = allocate
        transport.initialize_for_spec
        transport
      end

      protected def initialize_for_spec : Nil
        @port = 0
        @on_message = nil
        @running = false
        @receive_fiber = nil
        @message_counter = Transport::MessageCounter.new
        @unsecured_counters = {} of Tuple(UInt64?, Socket::IPAddress) => Tuple(Transport::MessageCounter, Time::Instant)
        initialize_unsecured_replay
        @last_unsecured_counter_sweep = Time.instant
        @exchange_manager = Transport::ExchangeManager.new
        initialize_reliable_messages
        @sent_packets = [] of Tuple(Bytes, Socket::IPAddress)
      end

      def start : Nil
      end

      def stop : Nil
      end

      def close : Nil
        clear_reliable
      end

      protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
        @sent_packets << {data.to_slice.dup, peer_address}
      end
    end
  end
end
