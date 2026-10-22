require "socket"

require "../codec/message_codec"
require "./exchange"
require "./message_counter"

module Matter
  module Transport
    # A connection that carries complete Matter packets. UDP and BTP keep
    # their own framing and retransmission policy behind this boundary.
    abstract class PacketTransport
      abstract def port : Int32
      abstract def message_counter : MessageCounter
      abstract def exchange_manager : ExchangeManager

      property on_message : Proc(Codec::MessageCodec::Message, Socket::IPAddress, Nil)?
      property on_group_packet : Proc(Bytes, Socket::IPAddress, Nil)?

      abstract def add_message_observer(&block : Codec::MessageCodec::Message, Socket::IPAddress -> Bool) : Int32
      abstract def remove_message_observer(id : Int32) : Nil
      abstract def group_memberships=(addresses : Array(Socket::IPAddress)) : Nil
      abstract def start : Nil
      abstract def close : Nil
      abstract def send_message(message : Codec::MessageCodec::Message, peer_address : Socket::IPAddress) : Bytes
      abstract def cache_unsecured_response(original : Codec::MessageCodec::Message,
                                            peer : Socket::IPAddress, response : Bytes) : Nil
      abstract def send_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
      abstract def send_reliable_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress,
                                     session_id : UInt16, exchange_id : UInt16,
                                     message_counter : UInt32) : Nil
      abstract def acknowledge_reliable(session_id : UInt16, exchange_id : UInt16,
                                        message_counter : UInt32,
                                        peer : Socket::IPAddress? = nil) : Bool
      abstract def clear_reliable_session(session_id : UInt16) : Nil

      # Stream transports override this for their connection-local route.
      # A UDP or BTP peer is not a Matter TCP connection token.
      def tcp_peer?(peer : Socket::IPAddress) : Bool
        false
      end
    end
  end
end
