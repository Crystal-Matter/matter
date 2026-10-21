require "../interaction_model/tlv_messages"
require "../session/group_outgoing_counters"
require "../session/group_secure_packet"
require "../transport/group_multicast"

module Matter
  module Protocol
    # Sends InvokeRequests as one-way, private groupcast datagrams.
    class GroupMessageSender
      def initialize(@transport : Transport::UDPTransport,
                     @counters : Session::GroupOutgoingCounters)
      end

      def invoke(fabric_id : UInt64, fabric_index : UInt8, source_node_id : UInt64,
                 key : Session::GroupSecurePacket::Key,
                 commands : Array(InteractionModel::CommandDataIBTlv)) : Nil
        raise ArgumentError.new("Group key is for another fabric") unless key.fabric_index == fabric_index
        raise ArgumentError.new("At least one command is required") if commands.empty?
        raise ArgumentError.new("Group command paths must omit endpoint") if commands.any?(&.command_path.endpoint)
        request = InteractionModel::InvokeRequestMessage.new(commands,
          suppress_response: true, timed_request: false)
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: Random::Secure.rand(UInt16),
          protocol_id: 1_u16,
          message_type: IMHandler::MSG_INVOKE_REQUEST,
          initiator_message: true,
          requires_acknowledge: false)
        packet = Session::GroupSecurePacket.new([key]).encode(key, source_node_id,
          @counters.next_data, payload_header, request.to_slice)
        @transport.send_raw(packet,
          Transport::GroupMulticast.address(fabric_id, key.group_id.id))
      end
    end
  end
end
