require "log"
require "socket"

require "../transport/udp_transport"

module Matter
  module Protocol
    # A short-lived cache of encrypted responses keyed by
    # `{session_id, incoming message counter}`.
    #
    # Controllers (notably iOS) retransmit a request when our response is lost.
    # Replaying the stored packet answers the retransmission without re-invoking
    # cluster logic, so a repeated Invoke cannot toggle a relay twice.
    class MrpCache
      Log = ::Log.for("matter.protocol.mrp_cache")

      # How long a response stays replayable.
      RESPONSE_TTL = 10.seconds

      # Upper bound on cached responses; the oldest are dropped first.
      MAX_ENTRIES = 512

      private record Entry, packet : Bytes, created_at : Time::Instant

      @entries : Hash(Tuple(UInt16, UInt32), Entry) = {} of Tuple(UInt16, UInt32) => Entry

      def initialize(@transport : Transport::UDPTransport)
      end

      # Number of cached responses.
      def size : Int32
        @entries.size
      end

      # Answers a duplicate request with the cached response so the peer's
      # retransmission still gets its ACK. Returns whether a response was sent.
      #
      # Only counters the receive window classifies as `Duplicate` reach here: a
      # retransmit older than `Transport::MessageCounter::WINDOW_SIZE` is `Stale`
      # and dropped rather than resent. Within `RESPONSE_TTL` a peer cannot
      # advance the counter that far, so that path is unreachable in practice.
      def resend?(session_id : UInt16, incoming_counter : UInt32, peer : Socket::IPAddress) : Bool
        key = {session_id, incoming_counter}
        cached = @entries[key]?
        return false unless cached

        if Time.instant - cached.created_at <= RESPONSE_TTL
          Log.warn { "MRP duplicate detected: session_id=#{session_id}, message_counter=#{incoming_counter} - resending cached response" }
          @transport.send_raw(cached.packet, peer)
          true
        else
          @entries.delete(key)
          false
        end
      end

      # Stores *packet* as the response to `{session_id, incoming_counter}`.
      def store(session_id : UInt16, incoming_counter : UInt32, packet : Bytes) : Nil
        @entries[{session_id, incoming_counter}] = Entry.new(packet, Time.instant)
        prune
      end

      # Forgets every response cached for *session_id*.
      def clear_session(session_id : UInt16) : Nil
        @entries.reject! { |(cached_session_id, _), _| cached_session_id == session_id }
        @transport.clear_reliable_session(session_id)
      end

      # Forgets every cached response.
      def clear : Nil
        @entries.clear
      end

      # Drops expired entries, then the oldest entries over `MAX_ENTRIES`.
      private def prune(now : Time::Instant = Time.instant) : Nil
        @entries.reject! { |_, entry| now - entry.created_at > RESPONSE_TTL }

        return if @entries.size <= MAX_ENTRIES

        @entries = @entries
          .to_a
          .sort_by! { |(_, entry)| entry.created_at }
          .last(MAX_ENTRIES)
          .to_h
      end
    end
  end
end
