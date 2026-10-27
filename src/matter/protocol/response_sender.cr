require "log"
require "socket"

require "../codec/message_codec"
require "../session/context"
require "../session/secure_message"
require "../session/pase/definitions"
require "../transport/udp_transport"
require "./message_type"
require "./bdx/transfer"
require "./mrp_cache"
require "./im_handler"

module Matter
  module Protocol
    # Encrypts and sends the node's outbound protocol messages.
    #
    # Every send either answers an exchange a controller opened, or opens one
    # of ours for a subscription report. Callers must hold the
    # `SessionRegistry` lock: the exchange id counter here and the message
    # counter on each session are shared with inbound message handling.
    class ResponseSender
      Log = ::Log.for("matter.protocol.response_sender")

      # The id of the next exchange we initiate. Random at boot so it cannot
      # collide with the exchanges a controller opens.
      property next_exchange_id : UInt16 = Random.rand(UInt16).to_u16

      # Fired once a new encrypted IM packet has been handed to the transport.
      # MRP retransmissions reuse cached bytes and do not invoke this callback.
      property on_im_message_sent : Proc(Nil)?

      # A host-owned transport fault hook can discard a fully encoded IM
      # response before it enters the packet transport. A discarded packet is
      # neither queued for reliable retransmission nor cached for MRP replay.
      property on_im_response_packet : Proc(Codec::MessageCodec::Message, UInt8, Bytes, Bool)?

      def initialize(@transport : Transport::PacketTransport, @mrp_cache : MrpCache)
      end

      def configure_mrp_peer(peer : Socket::IPAddress, session : Session::SecureContext) : Nil
        @transport.configure_mrp_peer(peer, session.session_id,
          session.peer_mrp_idle_interval_ms, session.peer_mrp_active_interval_ms,
          session.peer_mrp_active_threshold_ms)
      end

      def mark_mrp_peer_active(peer : Socket::IPAddress, session : Session::SecureContext) : Nil
        @transport.mark_mrp_peer_active(peer, session.session_id)
      end

      def configure_unsecured_mrp_peer(peer : Socket::IPAddress,
                                       idle_interval_ms : UInt32?, active_interval_ms : UInt32?,
                                       active_threshold_ms : UInt16? = nil) : Nil
        @transport.configure_mrp_peer(peer, Codec::MessageCodec::UNSECURED_SESSION_ID,
          idle_interval_ms, active_interval_ms, active_threshold_ms)
      end

      # A large IM payload is allowed only on the authenticated session's
      # currently live TCP connection. The same device may still serve UDP.
      def im_payload_limit(session : Session::SecureContext, peer : Socket::IPAddress) : Int32
        if session.tcp_session? && session.accepts_peer?(peer) && @transport.tcp_peer?(peer)
          IMHandler::MAX_TCP_REPORT_PAYLOAD_SIZE
        else
          IMHandler::MAX_REPORT_PAYLOAD_SIZE
        end
      end

      # Sends an Interaction Model message on the exchange *original_msg*
      # arrived on.
      #
      # With *cache_for_mrp*, the encrypted packet is remembered against the
      # request's message counter so a retransmission of that request is
      # answered from the cache instead of re-running cluster logic.
      def send_im_response(
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
        message_type : UInt8,
        payload : Bytes,
        cache_for_mrp : Bool = false,
      ) : Nil
        if payload.size > im_payload_limit(session, peer)
          raise Matter::ProtocolError.new("IM response exceeds transport payload limit")
        end
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: original_msg.payload_header.exchange_id,
          protocol_id: ProtocolId::InteractionModel.value,
          message_type: message_type,
          initiator_message: !original_msg.payload_header.initiator_message?,
          requires_acknowledge: true,
          acknowledged_message_id: original_msg.payload_header.requires_acknowledge? ? original_msg.packet_header.message_id : nil
        )
        udp_packet, counter = Session::SecureMessage.encode(session, payload_header, payload,
          source_node_id: original_msg.packet_header.destination_node_id || session.local_node_id,
          destination_node_id: original_msg.packet_header.source_node_id)

        if @on_im_response_packet.try(&.call(original_msg, message_type, udp_packet)) == true
          raise Matter::TransportError.new("Encoded IM response discarded before transport enqueue")
        end

        configure_mrp_peer(peer, session)
        @transport.send_reliable_raw(udp_packet, peer, session.session_id,
          payload_header.exchange_id, counter)
        if cache_for_mrp && !session.tcp_session? && original_msg.packet_header.session_id != Codec::MessageCodec::UNSECURED_SESSION_ID
          @mrp_cache.store(original_msg.packet_header.session_id, original_msg.packet_header.message_id, udp_packet.dup)
        end
        @on_im_message_sent.try(&.call)
      end

      # Sends one BDX message on the same encrypted exchange as the request.
      # The reply is cached so an MRP retransmission cannot advance a stream
      # twice or leave the peer waiting for a block already produced.
      def send_bdx_response(
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
        message_type : UInt8,
        payload : Bytes,
        append_to_cache : Bool = false,
      ) : Nil
        send_bdx_payload(original_msg, peer, session, ProtocolId::Bdx.value,
          message_type, payload, append_to_cache)
      end

      # Opens or continues a device-initiated BDX exchange on a CASE session.
      def send_bdx_request(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        exchange_id : UInt16,
        message_type : UInt8,
        payload : Bytes,
      ) : Nil
        header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange_id,
          protocol_id: ProtocolId::Bdx.value,
          message_type: message_type,
          initiator_message: true,
          requires_acknowledge: true)
        packet, counter = Session::SecureMessage.encode(session, header, payload,
          source_node_id: session.local_node_id, destination_node_id: session.peer_node_id)
        configure_mrp_peer(peer, session)
        @transport.send_reliable_raw(packet, peer, session.session_id, exchange_id, counter)
      end

      def send_bdx_status(
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
        status : Bdx::Transfer::StatusCode,
      ) : Nil
        report = Session::Pase::Definitions::StatusReport.new(
          general_status: Session::Pase::Definitions::StatusReport::GENERAL_STATUS_FAILURE,
          protocol_id: ProtocolId::Bdx.value,
          protocol_status: status.value)
        send_bdx_payload(original_msg, peer, session, ProtocolId::SecureChannel.value,
          SecureChannelMessageType::StatusReport.value, report.to_bytes)
      end

      private def send_bdx_payload(
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes,
        append_to_cache : Bool = false,
      ) : Nil
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: original_msg.payload_header.exchange_id,
          protocol_id: protocol_id,
          message_type: message_type,
          initiator_message: !original_msg.payload_header.initiator_message?,
          requires_acknowledge: true,
          acknowledged_message_id: original_msg.payload_header.requires_acknowledge? ? original_msg.packet_header.message_id : nil)
        packet, counter = Session::SecureMessage.encode(session, payload_header, payload,
          source_node_id: session.local_node_id, destination_node_id: session.peer_node_id)
        unless session.tcp_session?
          if append_to_cache
            @mrp_cache.append(original_msg.packet_header.session_id,
              original_msg.packet_header.message_id, packet.dup)
          else
            @mrp_cache.store(original_msg.packet_header.session_id,
              original_msg.packet_header.message_id, packet.dup)
          end
        end
        configure_mrp_peer(peer, session)
        @transport.send_reliable_raw(packet, peer, session.session_id,
          payload_header.exchange_id, counter)
      end

      # Acknowledges *original_msg* when there is no response to carry the ACK.
      def send_encrypted_ack(
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
        cache_for_mrp : Bool = false,
      ) : Nil
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: original_msg.payload_header.exchange_id,
          protocol_id: ProtocolId::SecureChannel.value,
          message_type: SecureChannelMessageType::StandaloneAck.value,
          initiator_message: !original_msg.payload_header.initiator_message?,
          requires_acknowledge: false,
          acknowledged_message_id: original_msg.packet_header.message_id
        )
        udp_packet, _ = Session::SecureMessage.encode(session, payload_header, Bytes.empty,
          source_node_id: session.local_node_id, destination_node_id: session.peer_node_id)
        if cache_for_mrp
          @mrp_cache.store(original_msg.packet_header.session_id,
            original_msg.packet_header.message_id, udp_packet.dup)
        end
        @transport.send_raw(udp_packet, peer)
      end

      # Sends a ReportData on a new exchange of ours, as a subscription update
      # is not a response to anything.
      def send_report(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        payload : Bytes,
      ) : UInt16
        if payload.size > im_payload_limit(session, peer)
          raise Matter::ProtocolError.new("Subscription update exceeds transport payload limit")
        end
        exchange_id = @next_exchange_id
        @next_exchange_id = @next_exchange_id &+ 1

        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange_id,
          protocol_id: ProtocolId::InteractionModel.value,
          message_type: InteractionModel::MessageType::ReportData.value,
          initiator_message: true,
          requires_acknowledge: true
        )
        udp_packet, counter = Session::SecureMessage.encode(session, payload_header, payload,
          source_node_id: session.local_node_id)
        configure_mrp_peer(peer, session)
        @transport.send_reliable_raw(udp_packet, peer, session.session_id,
          exchange_id, counter)
        @on_im_message_sent.try(&.call)
        exchange_id
      end

      # Sends an unencrypted Secure Channel message: the PASE and CASE
      # handshakes run before there is a session to encrypt with.
      def send_secure_channel_response(
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        session_id : UInt16? = nil,
      ) : Nil
        packet_header = Codec::MessageCodec::PacketHeader.new(
          session_id: session_id || original_msg.packet_header.session_id,
          session_type: Codec::MessageCodec::SessionType::Unicast,
          message_id: 0_u32, # Set by the transport
          privacy_enhancements: false,
          control_message: false,
          message_extensions: false,
          source_node_id: original_msg.packet_header.destination_node_id,
          destination_node_id: original_msg.packet_header.source_node_id
        )

        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: original_msg.payload_header.exchange_id,
          protocol_id: ProtocolId::SecureChannel.value,
          message_type: message_type,
          initiator_message: !original_msg.payload_header.initiator_message?,
          requires_acknowledge: false
        )

        packet = @transport.send_message(
          Codec::MessageCodec::Message.new(
            packet_header: packet_header,
            payload_header: payload_header,
            payload: payload.to_slice
          ),
          peer
        )
        @transport.cache_unsecured_response(original_msg, peer, packet)
      end
    end
  end
end
