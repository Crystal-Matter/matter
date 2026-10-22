require "../cluster/access_control"
require "../cluster/group_key_management"
require "../interaction_model/tlv_messages"
require "../session/group_secure_packet"

module Matter
  module Protocol
    # Executes authenticated group Invoke and Write requests without creating an exchange
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
        return unless payload_header.protocol_id == 1_u16
        return unless payload_header.initiator_message?
        return if payload_header.requires_acknowledge?
        return if payload_header.acknowledged_message_id

        group_id = header.destination_group_id.try(&.id)
        return unless group_id
        group = @group_keys.operational_group_table(decoded.fabric_index).find { |entry| entry.group_id == group_id }
        return unless group
        acl = @clusters[{0_u16, Cluster::AccessControl::CLUSTER_ID}]?.as?(Cluster::AccessControl)
        return unless acl
        case payload_header.message_type
        when IMHandler::MSG_INVOKE_REQUEST
          handle_invoke(message.payload, group, acl, group_id, decoded.fabric_index)
        when IMHandler::MSG_WRITE_REQUEST
          handle_write(message.payload, group, acl, group_id, decoded.fabric_index)
        end
      rescue ex
        Log.debug(exception: ex) { "Dropping group interaction" }
      end

      private def handle_invoke(payload : Bytes, group : Cluster::GroupKeyManagement::GroupInfoMapStruct,
                                acl : Cluster::AccessControl, group_id : UInt16, fabric_index : UInt8) : Nil
        request = IMHandler.parse_invoke_request(payload, allow_group_path: true)
        return unless request
        return if request.timed_request
        # A group CommandPath carries the Group ID in the packet header; its
        # Endpoint field is absent (Core §8.9.4.2). Reject the whole action.
        return if request.invoke_requests.any?(&.command_path.endpoint)

        request.invoke_requests.each do |command|
          path = command.command_path
          group.endpoints.each do |endpoint|
            cluster = @clusters[{endpoint, path.cluster}]?
            next unless cluster
            metadata = cluster.commands.find { |item| item.id.id == path.command }
            next unless metadata
            next unless acl.check_access(
                          subject: group_id.to_u64,
                          fabric_index: fabric_index,
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
                  nil, false, fabric_index)
              ensure
                cluster.request_auth_mode = nil
                cluster.request_group_id = nil
              end
            end
          end
        end
      end

      private def handle_write(payload : Bytes, group : Cluster::GroupKeyManagement::GroupInfoMapStruct,
                               acl : Cluster::AccessControl, group_id : UInt16, fabric_index : UInt8) : Nil
        request = IMHandler.parse_write_request(payload)
        # The SDK's chip-tool emits SuppressResponse=false for a group write.
        # The sender below emits true as Core requires; accepting either here
        # remains safe because group interactions never produce a response.
        return if request.nil? || request.timed_request || request.more_chunked_messages
        attributes = request.write_requests
        return if attributes.nil? || attributes.empty?
        # The Group ID is carried by the packet header, so all attribute paths
        # apply to matching member endpoints and have no node or endpoint tag.
        return if attributes.any? do |item|
                    item.path.node || item.path.endpoint_raw || item.path.cluster.nil? ||
                    item.path.attribute.nil? || item.data_version
                  end

        attributes.each do |attribute|
          path = attribute.path
          cluster_id = path.cluster.as(UInt32)
          attribute_id = path.attribute.as(UInt32)
          group.endpoints.each do |endpoint|
            cluster = @clusters[{endpoint, cluster_id}]?
            next unless cluster
            metadata = cluster.get_attribute_metadata(attribute_id)
            next if metadata.nil? || !metadata.writable? || metadata.timed?
            next unless acl.check_access(
                          subject: group_id.to_u64,
                          fabric_index: fabric_index,
                          privilege: metadata.write_access,
                          cluster: cluster_id,
                          endpoint: endpoint,
                          auth_mode: InteractionModel::EntryAuthMode::Group)

            cluster.with_request_context do
              cluster.request_auth_mode = InteractionModel::EntryAuthMode::Group
              cluster.request_group_id = group_id
              cluster.request_fabric_index = fabric_index
              cluster.request_peer_subject_ids = nil
              cluster.request_peer_node_id = nil
              cluster.request_peer_address = nil
              cluster.request_peer_icac = nil
              cluster.request_fabric_filtered = true
              begin
                cluster.write_attribute(attribute_id, attribute.data)
              ensure
                cluster.request_auth_mode = nil
                cluster.request_group_id = nil
              end
            end
          end
        end
      end
    end
  end
end
