require "../cluster/access_control"
require "../cluster/group_key_management"
require "../interaction_model/tlv_messages"
require "../session/group_secure_packet"

module Matter
  module Protocol
    # Executes authenticated group InvokeRequests without creating an exchange
    # or emitting a response. Group membership and Group ACL are both required.
    class GroupInteractionRouter
      Log = ::Log.for("matter.protocol.group_interaction_router")

      def initialize(@clusters : Hash(Tuple(UInt16, UInt32), Cluster::Base),
                     @group_keys : Cluster::GroupKeyManagement)
      end

      def handle(decoded : Session::GroupSecurePacket::Decoded) : Nil
        message = decoded.message
        header = message.packet_header
        payload_header = message.payload_header
        return unless header.session_type.group? && header.privacy_enhancements?
        return if header.control_message?
        return unless payload_header.protocol_id == 1_u16 && payload_header.message_type == IMHandler::MSG_INVOKE_REQUEST
        return unless payload_header.initiator_message?
        return if payload_header.requires_acknowledge?
        return if payload_header.acknowledged_message_id

        group_id = header.destination_group_id.try(&.id)
        return unless group_id
        group = @group_keys.group_table(decoded.fabric_index).find { |entry| entry.group_id == group_id }
        return unless group
        acl = @clusters[{0_u16, Cluster::AccessControl::CLUSTER_ID}]?.as?(Cluster::AccessControl)
        return unless acl
        request = IMHandler.parse_invoke_request(message.payload, allow_group_path: true)
        return unless request
        return if request.timed_request
        # A group CommandPath carries the Group ID in the packet header; its
        # Endpoint field is absent (Core §8.9.4.2). Reject the whole action.
        return if request.invoke_requests.any?(&.command_path.endpoint)

        request.invoke_requests.each do |command|
          path = command.command_path
          group.endpoints.each do |endpoint|
            next unless group.endpoints.includes?(endpoint)
            cluster = @clusters[{endpoint, path.cluster}]?
            next unless cluster
            metadata = cluster.commands.find { |item| item.id.id == path.command }
            next unless metadata
            next unless acl.check_access(
                          subject: group_id.to_u64,
                          fabric_index: decoded.fabric_index,
                          privilege: metadata.access,
                          cluster: path.cluster,
                          endpoint: endpoint,
                          auth_mode: InteractionModel::EntryAuthMode::Group)

            cluster.with_request_context do
              cluster.request_auth_mode = InteractionModel::EntryAuthMode::Group
              cluster.request_group_id = group_id
              cluster.request_peer_subject_ids = nil
              # A shared group key does not authenticate an individual Node ID.
              cluster.request_peer_node_id = nil
              cluster.request_peer_address = nil
              cluster.request_peer_icac = nil
              cluster.request_fabric_filtered = true
              begin
                cluster.invoke_command(path.command, command.command_fields,
                  nil, false, decoded.fabric_index)
              ensure
                cluster.request_auth_mode = nil
                cluster.request_group_id = nil
              end
            end
          end
        end
      rescue ex
        Log.debug(exception: ex) { "Dropping group invoke" }
      end
    end
  end
end
