require "../cluster/groupcast"
require "../cluster/group_key_management"
require "../fabric_table"
require "../interaction_model/tlv_messages"
require "../protocol/group_message_sender"
require "../session/group_outgoing_counters"

module Matter
  abstract class Device
    # Device-side outbound Groupcast using the node's commissioned fabric and
    # Groupcast membership. The transport and durable counters live below the
    # cluster; no Groupcast key material is copied into application state.
    class GroupcastSender
      Log = ::Log.for("matter.device.groupcast_sender")

      MATTER_EPOCH_UNIX_SECONDS   = 946_684_800_i64
      MICROSECONDS_PER_SECOND     =   1_000_000_u64
      NANOSECONDS_PER_MICROSECOND =       1_000_u64

      def initialize(@fabrics : FabricTable, @groupcast : Cluster::Groupcast,
                     @group_keys : Cluster::GroupKeyManagement,
                     @sender : Protocol::GroupMessageSender)
        raise ConfigurationError.new("Groupcast Sender feature is disabled") unless @groupcast.feature_map.sender?
      end

      # Fan out a command to Sender memberships on the fabric that issued the
      # current CASE command. A stale request context or local state change
      # cannot cause a send after command dispatch has finished.
      def invoke_joined_for_request(source : Cluster::Base, cluster_id : UInt32,
                                    command_id : UInt32, fields : Bytes = Bytes.empty) : Nil
        fabric_index = source.request_fabric_index if source.request_command_active? && source.request_is_case_session?
        raise ConfigurationError.new("Groupcast forwarding requires an active CASE command") unless fabric_index
        @groupcast.membership(fabric_index).each do |entry|
          invoke(fabric_index, entry.group_id, cluster_id, command_id, fields)
        end
      end

      def invoke(fabric_index : UInt8, group_id : UInt16, cluster_id : UInt32,
                 command_id : UInt32, fields : Bytes = Bytes.empty) : Nil
        fabric, key, policy = selection(fabric_index, group_id)
        command_fields = fields.empty? ? nil : TLV::Any.from_slice(fields)
        command = InteractionModel::CommandDataIBTlv.new(
          InteractionModel::CommandPath.new(nil, cluster_id, command_id), command_fields)
        begin
          @sender.invoke(fabric.fabric_id, fabric_index, fabric.node_id, key, [command],
            iana_address: policy.iana_addr?)
        rescue ex
          Log.error(exception: ex) { "Could not send Groupcast Invoke (fabric=#{fabric_index}, group=#{group_id})" }
          @groupcast.record_group_message(fabric_index, group_id,
            Cluster::Groupcast::GroupcastTestResultEnum::SendFailure,
            cluster_id: cluster_id, element_id: command_id, sender: true)
          raise ex
        end
        @groupcast.record_group_message(fabric_index, group_id,
          Cluster::Groupcast::GroupcastTestResultEnum::Success,
          cluster_id: cluster_id, element_id: command_id, sender: true)
      end

      def write(fabric_index : UInt8, group_id : UInt16, cluster_id : UInt32,
                attribute_id : UInt32, value : TLV::Any) : Nil
        fabric, key, policy = selection(fabric_index, group_id)
        attribute = InteractionModel::AttributeDataIB.new(
          InteractionModel::AttributePath.new(nil, cluster_id, attribute_id), value)
        begin
          @sender.write(fabric.fabric_id, fabric_index, fabric.node_id, key, [attribute],
            iana_address: policy.iana_addr?)
        rescue ex
          Log.error(exception: ex) { "Could not send Groupcast Write (fabric=#{fabric_index}, group=#{group_id})" }
          @groupcast.record_group_message(fabric_index, group_id,
            Cluster::Groupcast::GroupcastTestResultEnum::SendFailure,
            cluster_id: cluster_id, element_id: attribute_id, sender: true)
          raise ex
        end
        @groupcast.record_group_message(fabric_index, group_id,
          Cluster::Groupcast::GroupcastTestResultEnum::Success,
          cluster_id: cluster_id, element_id: attribute_id, sender: true)
      end

      private def selection(fabric_index : UInt8, group_id : UInt16)
        fabric = @fabrics.get_fabric(fabric_index) ||
                 raise ConfigurationError.new("Groupcast fabric is not installed")
        membership = @groupcast.membership(fabric_index).find(&.group_id.==(group_id)) ||
                     raise ConfigurationError.new("Groupcast Sender is not joined to Group ID")
        key_set = @group_keys.get_key_set(membership.key_set_id, fabric_index) ||
                  raise ConfigurationError.new("Groupcast key set is unavailable")
        epoch_key = current_epoch_key(key_set) ||
                    raise ConfigurationError.new("Groupcast key set has no active epoch key")
        operational = Session::GroupSecurePacket.derive_operational_key(
          epoch_key, fabric.compressed_fabric_id)
        key = Session::GroupSecurePacket::Key.new(fabric_index, group_id, operational, fabric.fabric_id)
        {fabric, key, membership.mcast_addr_policy}
      end

      private def current_epoch_key(key_set : Cluster::GroupKeyManagement::GroupKeySetStruct) : Bytes?
        now = Time.utc
        seconds = now.to_unix - MATTER_EPOCH_UNIX_SECONDS
        return if seconds < 0
        now_us = seconds.to_u64 * MICROSECONDS_PER_SECOND +
                 now.nanosecond.to_u64 // NANOSECONDS_PER_MICROSECOND
        selected : Bytes? = nil
        selected_start = 0_u64
        {
          {key_set.epoch_key0, key_set.epoch_start_time0},
          {key_set.epoch_key1, key_set.epoch_start_time1},
          {key_set.epoch_key2, key_set.epoch_start_time2},
        }.each do |key, start_time|
          next unless key && start_time && start_time <= now_us && start_time >= selected_start
          selected = key
          selected_start = start_time
        end
        selected
      end
    end
  end
end
