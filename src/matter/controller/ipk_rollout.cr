require "../cluster/joint_fabric_datastore"
require "../crypto/crypto"

module Matter
  module Controller
    # Host-side preflight for a Joint Fabric IPK update that evicts an epoch.
    # The wire-level Datastore UpdateKeySet command intentionally has no such
    # gate; callers can use this wrapper when coordinating a safe rollout.
    module IpkRollout
      alias Datastore = Cluster::JointFabricDatastore

      struct AdministratorAcknowledgment
        getter node_id : UInt64
        getter fabric_id : UInt64
        getter root_digest : Bytes
        getter key_set_digest : Bytes

        def initialize(@node_id : UInt64, @fabric_id : UInt64,
                       @root_digest : Bytes, @key_set_digest : Bytes)
        end
      end

      # The remote Administrator's trusted host issues this only after it has
      # durably installed the exact current KeySet0. GKM KeySetRead omits key
      # bytes, so a remote read alone cannot establish this acknowledgment.
      def self.acknowledgment(node_id : UInt64, fabric_id : UInt64, root_cert : Bytes,
                              key_set : Datastore::DatastoreGroupKeySetStruct) : AdministratorAcknowledgment
        AdministratorAcknowledgment.new(node_id, fabric_id,
          Crypto.compute_sha256(root_cert),
          Crypto.compute_sha256(key_set.to_slice))
      end

      # Check the Anchor's current Datastore immediately before evicting an
      # epoch. Every ordinary node must have a committed KeySet0 delivery and
      # every other Administrator must acknowledge this exact current key set.
      def self.preflight_eviction!(store : Datastore, fabric_id : UInt64, root_cert : Bytes,
                                   candidate : Datastore::DatastoreGroupKeySetStruct,
                                   acknowledgments : Array(AdministratorAcknowledgment)) : Nil
        if fabric_id == 0_u64 || root_cert.empty? || store.anchor_root_ca != root_cert ||
           store.anchor_node_id == 0_u64
          raise Matter::ConfigurationError.new("IPK rollout Anchor fabric identity is invalid")
        end
        unless candidate.group_key_set_id == 0_u16
          raise Matter::ConfigurationError.new("IPK rollout requires KeySet0")
        end
        current_entries = store.group_key_set_list.select(&.group_key_set_id.==(0_u16))
        unless current_entries.size == 1
          raise Matter::ConfigurationError.new("Anchor Datastore needs exactly one current KeySet0")
        end
        current = current_entries.first
        current_keys = epoch_keys(current)
        candidate_keys = epoch_keys(candidate)
        if current_keys.empty? || candidate_keys.empty?
          raise Matter::ConfigurationError.new("IPK rollout requires complete current and candidate epochs")
        end
        return if current_keys.all? { |key| candidate_keys.any?(&.==(key)) }

        node_ids = store.node_list.map(&.node_id)
        if node_ids.uniq.size != node_ids.size
          raise Matter::ConfigurationError.new("Anchor Datastore has duplicate ordinary nodes")
        end
        node_ids.each do |node_id|
          entries = store.node_key_set_list.select { |entry| entry.node_id == node_id && entry.group_key_set_id == 0_u16 }
          unless entries.size == 1 && entries.first.status_entry.state == Datastore::DatastoreStateEnum::Committed
            raise Matter::ConfigurationError.new("IPK rollout waits for ordinary node #{node_id} KeySet0 delivery")
          end
        end

        admin_ids = store.admin_list.map(&.node_id).reject(&.==(store.anchor_node_id))
        if admin_ids.uniq.size != admin_ids.size || acknowledgments.map(&.node_id).uniq!.size != acknowledgments.size
          raise Matter::ConfigurationError.new("IPK rollout has duplicate Administrator records")
        end
        expected_root = Crypto.compute_sha256(root_cert)
        expected_key_set = Crypto.compute_sha256(current.to_slice)
        admin_ids.each do |node_id|
          ack = acknowledgments.find(&.node_id.==(node_id))
          unless ack && ack.fabric_id == fabric_id && ack.root_digest == expected_root &&
                 ack.key_set_digest == expected_key_set
            raise Matter::ConfigurationError.new("IPK rollout waits for Administrator #{node_id} acknowledgment")
          end
        end
      end

      # Host-side serialized update. The host must prevent concurrent direct
      # UpdateKeySet calls between this preflight and command execution.
      def self.update_key_set_safely(store : Datastore, fabric_id : UInt64, root_cert : Bytes,
                                     candidate : Datastore::DatastoreGroupKeySetStruct,
                                     acknowledgments : Array(AdministratorAcknowledgment)) : InteractionModel::Status
        preflight_eviction!(store, fabric_id, root_cert, candidate, acknowledgments)
        store.update_key_set(Datastore::UpdateKeySetRequest.new(candidate))
      end

      private def self.epoch_keys(key_set : Datastore::DatastoreGroupKeySetStruct) : Array(Bytes)
        [key_set.epoch_key0, key_set.epoch_key1, key_set.epoch_key2].compact
      end
    end
  end
end
