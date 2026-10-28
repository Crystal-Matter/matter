require "log"
require "socket"

require "../codec/message_codec"
require "../error"
require "../protocol/message_type"
require "./btp_session"
require "./packet_transport"

module Matter
  module Transport
    # Platform BLE code implements ATT writes and notifications at this boundary.
    # One read returns one complete BTP fragment. A closed link returns nil.
    abstract class GattFragmentChannel
      abstract def write(frame : Bytes) : Nil
      abstract def read(timeout_span : Time::Span) : Bytes?
      abstract def close : Nil
      abstract def closed? : Bool
    end

    # Carries Matter packets over an already negotiated BTP connection. The
    # GATT adapter owns discovery, handshake negotiation, and ATT subscriptions.
    # BTP provides ordered delivery, so UDP MRP retransmission is not used.
    class BtpMessageTransport < PacketTransport
      Log = ::Log.for("matter.transport.btp_message_transport")

      # The existing exchange API uses an IP-shaped peer key. A BTP connection
      # has exactly one peer; this token never reaches a network socket.
      PEER                        = Socket::IPAddress.new("::1", 5540)
      POLL_INTERVAL               = 25.milliseconds
      STANDALONE_ACK_MESSAGE_TYPE = Protocol::SecureChannelMessageType::StandaloneAck.value
      MIN_PACKET_SIZE             = 8

      getter port : Int32
      getter message_counter : MessageCounter
      getter exchange_manager : ExchangeManager
      getter fragment_size : Int32
      getter window_size : Int32

      @observers : Hash(Int32, Proc(Codec::MessageCodec::Message, Socket::IPAddress, Bool))
      @observers_mutex : Mutex
      @next_observer_id : Int32
      @session : BtpSession
      @session_mutex : Mutex
      @running : Bool
      @receive_fiber : Fiber?

      def initialize(@channel : GattFragmentChannel, role : BtpSession::Role,
                     @fragment_size : Int32, @window_size : Int32)
        @session = BtpSession.new(role, @fragment_size, @window_size)
        @port = 5540
        @session_mutex = Mutex.new
        @message_counter = MessageCounter.new
        @message_counter.reset(Random::Secure.rand(UInt32))
        @exchange_manager = ExchangeManager.new
        @on_message = nil
        @on_group_packet = nil
        @observers = {} of Int32 => Proc(Codec::MessageCodec::Message, Socket::IPAddress, Bool)
        @observers_mutex = Mutex.new
        @next_observer_id = 0
        @running = false
        @receive_fiber = nil
      end

      def add_message_observer(&block : Codec::MessageCodec::Message, Socket::IPAddress -> Bool) : Int32
        @observers_mutex.synchronize do
          @next_observer_id += 1
          @observers[@next_observer_id] = block
          @next_observer_id
        end
      end

      def remove_message_observer(id : Int32) : Nil
        @observers_mutex.synchronize { @observers.delete(id) }
      end

      def group_memberships=(addresses : Array(Socket::IPAddress)) : Nil
        raise Matter::ConfigurationError.new("Matter group multicast is unavailable on BTP") unless addresses.empty?
      end

      def start : Nil
        return if @running
        raise Matter::TransportError.new("BTP GATT channel is closed") if @channel.closed?
        @running = true
        @receive_fiber = spawn { receive_loop }
      end

      def close : Nil
        return if @channel.closed? && !@running
        @running = false
        @session_mutex.synchronize { @session.close unless @session.closed? }
        @channel.close unless @channel.closed?
        @receive_fiber = nil
      end

      def send_message(message : Codec::MessageCodec::Message,
                       peer_address : Socket::IPAddress) : Bytes
        ensure_peer(peer_address)
        if message.packet_header.message_id == 0
          header = message.packet_header
          packet_header = Codec::MessageCodec::PacketHeader.new(
            session_id: header.session_id,
            session_type: header.session_type,
            message_id: @message_counter.next,
            privacy_enhancements: header.privacy_enhancements?,
            control_message: header.control_message?,
            message_extensions: header.message_extensions?,
            source_node_id: header.source_node_id,
            destination_node_id: header.destination_node_id,
            destination_group_id: header.destination_group_id)
          message = Codec::MessageCodec::Message.new(packet_header,
            message.payload_header, message.payload)
        end
        packet = Codec::MessageCodec::Base.encode_message(message.packet_header,
          message.payload_header, message.payload)
        send_raw(packet, peer_address)
        packet
      end

      def cache_unsecured_response(original : Codec::MessageCodec::Message,
                                   peer : Socket::IPAddress, response : Bytes) : Nil
        # BTP transports complete messages reliably and in order. The UDP
        # retransmission cache does not apply to this connection.
      end

      def send_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
        ensure_peer(peer_address)
        frames = @session_mutex.synchronize do
          @session.queue_message(data.to_slice)
          @session.drain_outgoing
        end
        write_frames(frames)
      end

      def send_reliable_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress,
                            session_id : UInt16, exchange_id : UInt16,
                            message_counter : UInt32) : Nil
        send_raw(data, peer_address)
      end

      def acknowledge_reliable(session_id : UInt16, exchange_id : UInt16,
                               message_counter : UInt32,
                               peer : Socket::IPAddress? = nil) : Bool
        false
      end

      def clear_reliable_session(session_id : UInt16) : Nil
      end

      private def receive_loop : Nil
        while @running
          if frame = @channel.read(POLL_INTERVAL)
            message_bytes = nil
            frames = @session_mutex.synchronize do
              message_bytes = @session.receive_packet(frame)
              outgoing = @session.drain_outgoing
              if @session.ack_urgent?
                if ack = @session.send_ack
                  outgoing << ack
                end
              end
              outgoing
            end
            write_frames(frames)
            dispatch_packet(message_bytes.as(Bytes)) if message_bytes
          end
          break if @channel.closed?
          ack = @session_mutex.synchronize { @session.poll }
          @channel.write(ack) if ack
        end
      rescue ex : Matter::Error
        Log.warn(exception: ex) { "BTP session closed after transport error" }
      rescue ex
        Log.error(exception: ex) { "BTP receive loop stopped" }
      ensure
        close
      end

      private def write_frames(frames : Array(Bytes)) : Nil
        frames.each { |frame| @channel.write(frame) }
      end

      private def dispatch_packet(data : Bytes) : Nil
        raise Matter::CodecError.new("Matter packet is truncated") if data.size < MIN_PACKET_SIZE
        packet = Codec::MessageCodec::Base.decode_packet(data)
        if packet.header.session_type == Codec::MessageCodec::SessionType::Group
          raise Matter::ProtocolError.new("Group packets cannot be sent over BTP")
        end
        message = if packet.header.session_id == Codec::MessageCodec::UNSECURED_SESSION_ID
                    Codec::MessageCodec::Base.decode_payload(packet)
                  else
                    dummy_header = Codec::MessageCodec::PayloadHeader.encrypted_placeholder
                    Codec::MessageCodec::Message.new(packet.header, dummy_header,
                      packet.payload, packet.header_bytes)
                  end

        if packet.header.session_id == Codec::MessageCodec::UNSECURED_SESSION_ID
          header = message.payload_header
          @exchange_manager.get_or_create_exchange(
            exchange_id: header.exchange_id,
            protocol_id: header.protocol_id,
            session_id: Codec::MessageCodec::UNSECURED_SESSION_ID,
            peer_address: PEER,
            peer_node_id: packet.header.source_node_id,
            initiator: !header.initiator_message?)
          send_acknowledgment(message) if header.requires_acknowledge?
        end

        observers = @observers_mutex.synchronize { @observers.values.to_a }
        return if observers.any?(&.call(message, PEER))
        @on_message.try(&.call(message, PEER))
      rescue ex : Matter::Error
        Log.warn(exception: ex) { "Dropping malformed Matter packet from BTP" }
      end

      private def send_acknowledgment(message : Codec::MessageCodec::Message) : Nil
        header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: message.payload_header.exchange_id,
          protocol_id: Protocol::ProtocolId::SecureChannel.value,
          message_type: STANDALONE_ACK_MESSAGE_TYPE,
          initiator_message: !message.payload_header.initiator_message?,
          requires_acknowledge: false,
          acknowledged_message_id: message.packet_header.message_id)
        packet_header = Codec::MessageCodec::PacketHeader.new(
          session_id: Codec::MessageCodec::UNSECURED_SESSION_ID,
          session_type: Codec::MessageCodec::SessionType::Unicast,
          message_id: 0_u32)
        send_message(Codec::MessageCodec::Message.new(packet_header, header, Bytes.empty), PEER)
      end

      private def ensure_peer(peer : Socket::IPAddress) : Nil
        raise Matter::TransportError.new("BTP connection has a different peer") unless peer == PEER
        raise Matter::TransportError.new("BTP GATT channel is closed") if @channel.closed?
      end
    end
  end
end
