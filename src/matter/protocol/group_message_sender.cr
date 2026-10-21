require "../interaction_model/tlv_messages"
require "../session/group_outgoing_counters"
require "../session/group_secure_packet"
require "../transport/group_multicast"

module Matter
  module Protocol
    # Sends Invoke and Write requests as one-way, private groupcast datagrams.
    class GroupMessageSender
      def initialize(@transport : Transport::UDPTransport,
                     @counters : Session::GroupOutgoingCounters)
      end

      def invoke(fabric_id : UInt64, fabric_index : UInt8, source_node_id : UInt64,
                 key : Session::GroupSecurePacket::Key,
                 commands : Array(InteractionModel::CommandDataIBTlv)) : Nil
        raise ArgumentError.new("At least one command is required") if commands.empty?
        raise ArgumentError.new("Group command paths must omit endpoint") if commands.any?(&.command_path.endpoint)
        request = InteractionModel::InvokeRequestMessage.new(commands,
          suppress_response: true, timed_request: false)
        send_message(fabric_id, fabric_index, source_node_id, key,
          IMHandler::MSG_INVOKE_REQUEST, request.to_slice)
      end

      def write(fabric_id : UInt64, fabric_index : UInt8, source_node_id : UInt64,
                key : Session::GroupSecurePacket::Key,
                attributes : Array(InteractionModel::AttributeDataIB)) : Nil
        raise ArgumentError.new("At least one attribute is required") if attributes.empty?
        if attributes.any? do |item|
             item.path.node || item.path.endpoint_raw || item.path.cluster.nil? ||
             item.path.attribute.nil? || item.data_version
           end
          raise ArgumentError.new("Group attribute paths must omit node, endpoint, and data version")
        end
        request = InteractionModel::WriteRequestMessage.new(true, false, attributes)
        send_message(fabric_id, fabric_index, source_node_id, key,
          IMHandler::MSG_WRITE_REQUEST, request.to_slice)
      end

      private def send_message(fabric_id : UInt64, fabric_index : UInt8, source_node_id : UInt64,
                               key : Session::GroupSecurePacket::Key, message_type : UInt8,
                               payload : Bytes) : Nil
        raise ArgumentError.new("Group key is for another fabric") unless key.fabric_index == fabric_index
        raise ArgumentError.new("Group key is not bound to the multicast fabric") unless key.fabric_id == fabric_id
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: Random::Secure.rand(UInt16),
          protocol_id: 1_u16,
          message_type: message_type,
          initiator_message: true,
          requires_acknowledge: false)
        packet = Session::GroupSecurePacket.new([key]).encode(key, source_node_id,
          @counters.next_data, payload_header, payload)
        @transport.send_raw(packet,
          Transport::GroupMulticast.address(fabric_id, key.group_id.id))
      end
    end
  end
end
