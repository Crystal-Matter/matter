require "./btp_codec"
require "./btp_message_transport"

module Matter
  module Transport
    # A connected Matter GATT link that can subscribe to C2 indications after
    # the handshake request has been written to C1.
    abstract class GattHandshakeChannel < GattFragmentChannel
      abstract def att_mtu : Int32?
      abstract def subscribe : Nil
    end

    # Performs Matter BLE BTP v4 negotiation before exposing a packet transport.
    # The platform adapter owns discovery, ATT connectivity, and characteristic
    # selection. It must queue C2 indications for #read, including the handshake
    # response received while #subscribe is in progress.
    module BtpCentralHandshake
      extend self

      SUPPORTED_VERSION   = 4_u8
      DEFAULT_ATT_MTU     =   23
      ATT_HEADER_SIZE     =    3
      MIN_FRAGMENT_SIZE   = BtpSession::MIN_FRAGMENT_SIZE
      MAX_FRAGMENT_SIZE   = BtpSession::MAX_FRAGMENT_SIZE
      DEFAULT_WINDOW_SIZE = 4_u8
      DEFAULT_TIMEOUT     = 15.seconds

      def open(channel : GattHandshakeChannel,
               window_size : UInt8 = DEFAULT_WINDOW_SIZE,
               timeout_span : Time::Span = DEFAULT_TIMEOUT) : BtpMessageTransport
        unless window_size.in?(1_u8..UInt8::MAX)
          raise Matter::ConfigurationError.new("BTP receive window is out of range")
        end
        if timeout_span <= Time::Span.zero
          raise Matter::ConfigurationError.new("BTP handshake timeout must be positive")
        end
        att_mtu = channel.att_mtu || DEFAULT_ATT_MTU
        if att_mtu < DEFAULT_ATT_MTU
          raise Matter::ConfigurationError.new("ATT MTU is below the BLE minimum")
        end
        requested_size = (att_mtu - ATT_HEADER_SIZE).clamp(MIN_FRAGMENT_SIZE, MAX_FRAGMENT_SIZE)
        request = BtpCodec::HandshakeRequest.new([SUPPORTED_VERSION], requested_size.to_u16, window_size)
        channel.write(BtpCodec.encode_handshake_request(request))
        channel.subscribe
        deadline = Time.instant + timeout_span
        loop do
          remaining = deadline - Time.instant
          raise Matter::TimeoutError.new("BTP handshake response timed out") if remaining <= Time::Span.zero
          frame = channel.read(remaining)
          raise Matter::TimeoutError.new("BTP handshake response timed out") unless frame
          next unless frame.size == BtpCodec::HANDSHAKE_RESPONSE_SIZE && frame[0] == BtpCodec::HANDSHAKE_HEADER
          response = BtpCodec.decode_handshake_response(frame)
          unless response.version == SUPPORTED_VERSION
            raise Matter::ProtocolError.new("Unsupported BTP version #{response.version}")
          end
          fragment_size = {requested_size, response.segment_size.to_i, MAX_FRAGMENT_SIZE}.min
          transport = BtpMessageTransport.new(channel, BtpSession::Role::Central,
            fragment_size, {window_size, response.window_size}.min.to_i)
          transport.start
          return transport
        end
      rescue ex
        channel.close unless channel.closed?
        raise ex
      end
    end
  end
end
