require "../interaction_model/tlv_messages"
require "../protocol/group_message_sender"
require "../session/group_outgoing_counters"
require "./client"
require "./state_store"

module Matter
  module Controller
    # Sends one-way group InvokeRequests using an installed operational key on
    # the selected controller fabric. The controller store must be durable so
    # group message counters cannot be reused after restart.
    class GroupInvoker
      LOCAL_FABRIC_INDEX = 1_u8

      @sender : Protocol::GroupMessageSender

      def initialize(@client : Client, @store : StateStore,
                     sender : Protocol::GroupMessageSender? = nil)
        @store.load
        @sender = sender || Protocol::GroupMessageSender.new(@client.transport,
          Session::GroupOutgoingCounters.new(@store.backend))
      end

      # Derive and retain only the operational key for the current epoch. Call
      # this again on key rotation. Provision the same epoch key and Group ID
      # on the receiving devices through GroupKeyManagement.
      def install_epoch_key(fabric_id : UInt64, root_public_key : Bytes,
                            group_id : UInt16, epoch_key : Bytes) : Nil
        raise Matter::ConfigurationError.new("Group ID zero is reserved") if group_id == 0_u16
        state = @store.load
        fabric = state.fabrics.find do |entry|
          entry.fabric_id == fabric_id && entry.root_public_key == root_public_key
        end || raise Matter::ConfigurationError.new("Controller fabric is not installed")
        compressed = Bytes.new(8)
        IO::ByteFormat::BigEndian.encode(fabric.compressed_fabric_id, compressed)
        operational_key = Session::GroupSecurePacket.derive_operational_key(epoch_key, compressed)
        state.group_keys.reject! do |entry|
          entry.fabric_id == fabric_id && entry.root_public_key == root_public_key && entry.group_id == group_id
        end
        state.group_keys << GroupKeyInfo.new(fabric_id, root_public_key.dup, group_id, operational_key)
        @store.save(state)
      end

      def remove_group_key(fabric_id : UInt64, root_public_key : Bytes,
                           group_id : UInt16) : Nil
        state = @store.load
        state.group_keys.reject! do |entry|
          entry.fabric_id == fabric_id && entry.root_public_key == root_public_key && entry.group_id == group_id
        end
        @store.save(state)
      end

      def invoke(fabric_id : UInt64, group_id : UInt16, cluster_id : UInt32,
                 command_id : UInt32, fields : Bytes = Bytes.empty,
                 root_public_key : Bytes? = nil,
                 controller_node_id : UInt64? = nil) : Nil
        state = @store.load
        fabric = state.fabric_for(fabric_id, root_public_key, controller_node_id)
        entry = state.group_keys.find do |candidate|
          candidate.fabric_id == fabric.fabric_id &&
            candidate.root_public_key == fabric.root_public_key && candidate.group_id == group_id
        end || raise Matter::ConfigurationError.new("No group key installed for selected fabric and Group ID")
        key = Session::GroupSecurePacket::Key.new(LOCAL_FABRIC_INDEX, group_id,
          entry.operational_key, fabric.fabric_id)
        path = InteractionModel::CommandPath.new(nil, cluster_id, command_id)
        command_fields = fields.empty? ? nil : TLV::Any.from_slice(fields)
        command = InteractionModel::CommandDataIBTlv.new(path, command_fields)
        @sender.invoke(fabric.fabric_id, LOCAL_FABRIC_INDEX, fabric.controller_node_id,
          key, [command])
      end
    end
  end
end
