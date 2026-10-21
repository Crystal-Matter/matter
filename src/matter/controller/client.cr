require "log"
require "socket"

require "../codec/message_codec"
require "../crypto/crypto"
require "../datatype/node_id"
require "../session/context"
require "../session/secure_message"
require "../transport/udp_transport"

module Matter
  module Controller
    class Client
      Log = ::Log.for("matter.controller.client")

      PROTOCOL_SECURE_CHANNEL    = 0x0000_u16
      PROTOCOL_INTERACTION_MODEL = 0x0001_u16

      MSG_STANDALONE_ACK      = 0x10_u8
      MSG_REPORT_DATA         = 0x05_u8
      MAX_CACHED_ACKS         = Transport::MessageCounter::WINDOW_SIZE
      MAX_DEFERRED_MESSAGES   = 256
      DEFERRED_CHECK_INTERVAL = 10.milliseconds

      record ReceivedMessage, message : Codec::MessageCodec::Message, peer : Socket::IPAddress

      getter transport : Transport::UDPTransport
      getter crypto : Crypto::CryptoBase

      @sessions = {} of UInt16 => Session::SecureContext
      @ack_packets = {} of {UInt16, UInt32} => Bytes
      @inbox : Channel(ReceivedMessage)
      @deferred_messages : Array(ReceivedMessage)
      @deferred_mutex : Mutex
      @next_exchange_id : UInt16
      @unsecured_source_node_id : DataType::NodeId?

      def initialize(
        port : Int32 = 0,
        @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
        unsecured_source_node_id : UInt64? = nil,
        initial_unsecured_message_counter : UInt32? = nil,
      )
        @transport = Transport::UDPTransport.new(port: port)
        @unsecured_source_node_id = unsecured_source_node_id ? DataType::NodeId.new(unsecured_source_node_id) : nil

        # Avoid re-using old unsecured message IDs across process restarts: peers may
        # keep a dedupe window for unsecured traffic (session_id=0), which can cause
        # commissioning/CASE handshakes to be ignored as duplicates/stale.
        if initial = initial_unsecured_message_counter
          @transport.message_counter.reset(initial)
        else
          @transport.message_counter.reset(Random::Secure.rand(UInt32))
        end
        @inbox = Channel(ReceivedMessage).new(256)
        @deferred_messages = [] of ReceivedMessage
        @deferred_mutex = Mutex.new
        @next_exchange_id = Random.rand(UInt16).to_u16

        @transport.on_message = ->(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) { handle_transport_message(msg, peer) }
        @transport.start
      end

      def close : Nil
        @transport.close
      end

      def register_session(session : Session::SecureContext) : Nil
        @sessions[session.session_id] = session
      end

      def session?(session_id : UInt16) : Session::SecureContext?
        @sessions[session_id]?
      end

      def next_exchange_id : UInt16
        id = @next_exchange_id
        @next_exchange_id = @next_exchange_id &+ 1
        id
      end

      # Send an unsecured (session_id=0) request and return the exchange id.
      def send_unsecured_request(
        peer : Socket::IPAddress,
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        requires_ack : Bool = true,
      ) : UInt16
        exchange = @transport.send_request(
          protocol_id: protocol_id,
          message_type: message_type,
          payload: payload,
          session_id: 0_u16,
          peer_address: peer,
          peer_node_id: nil,
          source_node_id: @unsecured_source_node_id,
          requires_ack: requires_ack
        )
        exchange.exchange_id
      end

      # Send an unsecured (session_id=0) message on an existing exchange.
      def send_unsecured_on_exchange(
        peer : Socket::IPAddress,
        exchange_id : UInt16,
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        initiator_message : Bool = true,
        requires_ack : Bool = true,
        acknowledged_message_id : UInt32? = nil,
      ) : Nil
        unless @transport.exchange_manager.get_exchange(exchange_id, 0_u16, peer, initiator_message)
          raise Matter::ProtocolError.new("unknown exchange_id=#{exchange_id}")
        end

        packet_header = Codec::MessageCodec::PacketHeader.new(
          session_id: 0_u16,
          session_type: Codec::MessageCodec::SessionType::Unicast,
          message_id: 0_u32, # assigned by UDPTransport
          privacy_enhancements: false,
          control_message: false,
          message_extensions: false,
          source_node_id: @unsecured_source_node_id,
          destination_node_id: nil
        )

        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange_id,
          protocol_id: protocol_id,
          message_type: message_type,
          initiator_message: initiator_message,
          requires_acknowledge: requires_ack,
          acknowledged_message_id: acknowledged_message_id
        )

        message = Codec::MessageCodec::Message.new(
          packet_header: packet_header,
          payload_header: payload_header,
          payload: payload.to_slice
        )

        @transport.send_message(message, peer)
      end

      # Send an encrypted request on an existing secure session.
      def send_encrypted_request(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        exchange_id : UInt16 = next_exchange_id,
        initiator_message : Bool = true,
        requires_ack : Bool = true,
        acknowledged_message_id : UInt32? = nil,
      ) : UInt16
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange_id,
          protocol_id: protocol_id,
          message_type: message_type,
          initiator_message: initiator_message,
          requires_acknowledge: requires_ack,
          acknowledged_message_id: acknowledged_message_id
        )

        udp_packet, counter = Session::SecureMessage.encode(session, payload_header, payload.to_slice,
          source_node_id: session.local_node_id, destination_node_id: session.peer_node_id, crypto: @crypto)
        if requires_ack
          @transport.send_reliable_raw(udp_packet, peer, session.session_id,
            exchange_id, counter)
        else
          @transport.send_raw(udp_packet, peer)
        end

        exchange_id
      end

      # Wait for the next message matching exchange/protocol/type.
      def wait_for(
        exchange_id : UInt16,
        protocol_id : UInt16,
        message_type : UInt8,
        timeout : Time::Span,
      ) : ReceivedMessage?
        wait_for_any(exchange_id, protocol_id, [message_type], timeout)
      end

      # Wait for one of several valid responses to an exchange. A device may
      # answer a timed Write/Invoke with StatusResponse instead of its normal
      # response when the timed window expires. Messages for other exchanges
      # are retained for their own waiters, with a bounded backlog.
      def wait_for_any(
        exchange_id : UInt16,
        protocol_id : UInt16,
        message_types : Array(UInt8),
        timeout : Time::Span,
      ) : ReceivedMessage?
        deadline = Time.instant + timeout

        loop do
          if deferred = take_deferred do |rec|
               matches?(rec, exchange_id, protocol_id, message_types)
             end
            return deferred
          end

          remaining = deadline - Time.instant
          return if remaining <= 0.seconds

          select
          when rec = @inbox.receive
            ack_encrypted_if_needed(rec)
            return rec if matches?(rec, exchange_id, protocol_id, message_types)
            defer(rec) unless standalone_ack?(rec)
          when timeout({remaining, DEFERRED_CHECK_INTERVAL}.min)
          end
        end
      end

      # Receive the next decrypted message without an exchange filter. Use a
      # dedicated Client when consuming subscriptions so another interaction
      # cannot lose a response to this reader.
      def receive_message(timeout_span : Time::Span) : ReceivedMessage?
        if deferred = take_deferred { true }
          return deferred
        end
        select
        when rec = @inbox.receive
          ack_encrypted_if_needed(rec)
          rec
        when timeout(timeout_span)
          nil
        end
      end

      private def matches?(rec : ReceivedMessage, exchange_id : UInt16,
                           protocol_id : UInt16, message_types : Array(UInt8)) : Bool
        header = rec.message.payload_header
        header.exchange_id == exchange_id && header.protocol_id == protocol_id &&
          message_types.includes?(header.message_type)
      end

      private def standalone_ack?(rec : ReceivedMessage) : Bool
        header = rec.message.payload_header
        header.protocol_id == PROTOCOL_SECURE_CHANNEL && header.message_type == MSG_STANDALONE_ACK
      end

      private def take_deferred(&block : ReceivedMessage -> Bool) : ReceivedMessage?
        @deferred_mutex.synchronize do
          if index = @deferred_messages.index { |rec| block.call(rec) }
            @deferred_messages.delete_at(index)
          end
        end
      end

      private def defer(rec : ReceivedMessage) : Nil
        @deferred_mutex.synchronize do
          if @deferred_messages.size >= MAX_DEFERRED_MESSAGES
            dropped = @deferred_messages.shift
            Log.warn do
              "Dropping oldest deferred controller message " \
              "(exchange=#{dropped.message.payload_header.exchange_id}, protocol=#{dropped.message.payload_header.protocol_id})"
            end
          end
          @deferred_messages << rec
        end
      end

      private def handle_transport_message(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        if msg.packet_header.session_id == 0
          @inbox.send(ReceivedMessage.new(msg, peer))
          return
        end

        session = @sessions[msg.packet_header.session_id]?
        unless session
          Log.debug { "Dropping encrypted message: no session found (session_id=#{msg.packet_header.session_id}, peer=#{peer})" }
          return
        end

        case session.check_peer_message_counter(msg.packet_header.message_id)
        when Transport::MessageCounter::CheckResult::Duplicate
          if ack = @ack_packets[{session.session_id, msg.packet_header.message_id}]?
            @transport.send_raw(ack, peer)
          end
          return
        when Transport::MessageCounter::CheckResult::Stale
          return
        end
        decrypted_message = decrypt_message(session, msg)
        if ack = decrypted_message.payload_header.acknowledged_message_id
          @transport.acknowledge_reliable(session.session_id,
            decrypted_message.payload_header.exchange_id, ack)
        end
        @inbox.send(ReceivedMessage.new(decrypted_message, peer))
      rescue ex
        Log.error(exception: ex) { "Controller: failed handling inbound message (peer=#{peer} session_id=#{msg.packet_header.session_id} data_hex=#{msg.payload.hexstring})" }
      end

      private def decrypt_message(session : Session::SecureContext, msg : Codec::MessageCodec::Message) : Codec::MessageCodec::Message
        Session::SecureMessage.decode(session,
          Codec::MessageCodec::Packet.new(msg.packet_header, msg.payload, msg.header_bytes), @crypto)
      end

      private def ack_encrypted_if_needed(rec : ReceivedMessage) : Nil
        msg = rec.message
        return unless msg.payload_header.requires_acknowledge?
        return if msg.packet_header.session_id == 0
        # ReportData uses the Interaction Model StatusResponse ladder. Sending
        # an MRP ACK here as well would advance a chunked publisher twice.
        return if msg.payload_header.protocol_id == PROTOCOL_INTERACTION_MODEL &&
                  msg.payload_header.message_type == MSG_REPORT_DATA

        session = @sessions[msg.packet_header.session_id]?
        return unless session

        send_standalone_ack(session, rec.peer, msg)
      end

      private def send_standalone_ack(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        original : Codec::MessageCodec::Message,
      ) : Nil
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: original.payload_header.exchange_id,
          protocol_id: PROTOCOL_SECURE_CHANNEL,
          message_type: MSG_STANDALONE_ACK,
          initiator_message: !original.payload_header.initiator_message?,
          requires_acknowledge: false,
          acknowledged_message_id: original.packet_header.message_id
        )

        udp_packet, _ = Session::SecureMessage.encode(session, payload_header, Bytes.empty,
          source_node_id: session.local_node_id, destination_node_id: session.peer_node_id, crypto: @crypto)
        @ack_packets.shift if @ack_packets.size >= MAX_CACHED_ACKS
        @ack_packets[{session.session_id, original.packet_header.message_id}] = udp_packet
        @transport.send_raw(udp_packet, peer)
      end
    end
  end
end
