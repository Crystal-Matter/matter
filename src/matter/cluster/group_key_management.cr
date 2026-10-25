require "./cluster"
require "log"

module Matter
  module Cluster
    # Group Key Management Cluster (0x003F)
    # Matter Core Specification §11.2
    #
    # Manages group keys for secure group communication:
    # - Group key sets for shared encryption keys
    # - Mapping between groups and key sets
    # - Identity Protection Keys (IPK) for CASE session establishment
    # - Operational group keys for group messaging
    #
    # Key Features:
    # - Fabric-scoped: All data isolated per fabric
    # - IPK Protection: KeySet 0 (IPK) cannot be removed
    # - Strict Validation: Epoch keys must be ordered, security policies enforced
    # - Cryptographic Operations: HKDF-based key derivation for operational keys
    class GroupKeyManagement < Base
      cluster 0x003F, revision: 3, persist_state: false

      feature :cache_and_sync, bit: 0 # Currently provisional/disabled
      feature :groupcast, bit: 1      # Opt-in with the Root Node Groupcast server

      DEFAULT_MAX_GROUPS_PER_FABRIC     = 12_u16
      DEFAULT_MAX_GROUP_KEYS_PER_FABRIC =  3_u16

      # Epoch keys are AES-128 keys (Matter Core §11.2.6.3)
      EPOCH_KEY_LENGTH = 16

      # Key set 0 holds the Identity Protection Key and can never be removed.
      IPK_KEY_SET_ID = 0_u16

      # Group 0 is reserved (Matter Core §11.2.6.4)
      RESERVED_GROUP_ID = 0_u16

      # Security policy for group key sets
      # Matter Core Spec §11.2.6.3.1
      enum GroupKeySecurityPolicyEnum : UInt8
        TrustFirst   = 0 # Only valid option in current Matter spec
        CacheAndSync = 1 # Provisional, not currently supported
      end

      # Multicast policy for group addressing
      # Matter Core Spec §11.2.6.3.2
      enum GroupKeyMulticastPolicyEnum : UInt8
        PerGroupId = 0 # One IPv6 multicast address per group (required)
        AllNodes   = 1 # Not supported
      end

      # Group Key Set structure
      # Contains epoch keys and their lifecycle timestamps
      # Matter Core Spec §11.2.6.3
      class EpochKeyLengthError < ArgumentError
      end

      struct GroupKeySetStruct
        include TLV::Serializable

        # Unique identifier for this key set (0 = IPK, others = operational)
        @[TLV::Field(tag: 0)]
        property group_key_set_id : UInt16

        # Security policy (MUST be TrustFirst in current spec)
        @[TLV::Field(tag: 1)]
        property group_key_security_policy : GroupKeySecurityPolicyEnum

        # Epoch key 0 (most recent, required, 16 bytes)
        @[TLV::Field(tag: 2)]
        property epoch_key0 : Bytes?

        # Epoch start time for key 0 (microseconds since epoch)
        @[TLV::Field(tag: 3)]
        property epoch_start_time0 : UInt64?

        # Epoch key 1 (second newest, optional, 16 bytes)
        @[TLV::Field(tag: 4)]
        property epoch_key1 : Bytes?

        # Epoch start time for key 1
        @[TLV::Field(tag: 5)]
        property epoch_start_time1 : UInt64?

        # Epoch key 2 (third newest, optional, 16 bytes)
        @[TLV::Field(tag: 6)]
        property epoch_key2 : Bytes?

        # Epoch start time for key 2
        @[TLV::Field(tag: 7)]
        property epoch_start_time2 : UInt64?

        # Deprecated in Matter 1.6; retained for decoding legacy key sets.
        @[TLV::Field(tag: 8, optional: true)]
        property group_key_multicast_policy : GroupKeyMulticastPolicyEnum?

        def initialize(
          @group_key_set_id : UInt16,
          @group_key_security_policy : GroupKeySecurityPolicyEnum = GroupKeySecurityPolicyEnum::TrustFirst,
          @epoch_key0 : Bytes? = nil,
          @epoch_start_time0 : UInt64? = nil,
          @epoch_key1 : Bytes? = nil,
          @epoch_start_time1 : UInt64? = nil,
          @epoch_key2 : Bytes? = nil,
          @epoch_start_time2 : UInt64? = nil,
          @group_key_multicast_policy : GroupKeyMulticastPolicyEnum? = nil,
        )
        end

        # Validate that this key set meets all Matter spec requirements
        def validate! : Nil
          # Validation 1: Epoch keys must be exactly 16 bytes if present
          validate_key_length!(epoch_key0, "epoch_key0")
          validate_key_length!(epoch_key1, "epoch_key1")
          validate_key_length!(epoch_key2, "epoch_key2")

          # Validation 2: Epoch keys and start times must be paired
          # (both null or both set)
          validate_key_time_pairing!("key0", epoch_key0, epoch_start_time0)
          validate_key_time_pairing!("key1", epoch_key1, epoch_start_time1)
          validate_key_time_pairing!("key2", epoch_key2, epoch_start_time2)

          # KeySetWrite requires the first epoch. Later epochs cannot leave a
          # gap, even when their own key/time fields are paired correctly.
          unless epoch_key0 && epoch_start_time0
            raise ArgumentError.new("EpochKey0 and EpochStartTime0 must be set")
          end
          if epoch_key2 && epoch_key1.nil?
            raise ArgumentError.new("EpochKey1 must be set when EpochKey2 is set")
          end

          # Validation 3: Epoch start times cannot be 0 if set
          validate_nonzero_time!(epoch_start_time0, "epoch_start_time0")
          validate_nonzero_time!(epoch_start_time1, "epoch_start_time1")
          validate_nonzero_time!(epoch_start_time2, "epoch_start_time2")

          # Validation 4: Epoch start times must be strictly ordered if set
          # (start0 < start1 < start2)
          validate_epoch_ordering!

          # Validation 5: Security policy must be TrustFirst
          # (CacheAndSync not currently supported)
          if group_key_security_policy != GroupKeySecurityPolicyEnum::TrustFirst
            raise ArgumentError.new("Only TrustFirst security policy is supported")
          end

          # Validation 6: Multicast policy must be PerGroupId if set
          if mcast = group_key_multicast_policy
            if mcast != GroupKeyMulticastPolicyEnum::PerGroupId
              raise ArgumentError.new("Only PerGroupId multicast policy is supported")
            end
          end
        end

        private def validate_key_length!(key : Bytes?, name : String) : Nil
          return unless key
          unless key.size == EPOCH_KEY_LENGTH
            raise EpochKeyLengthError.new("#{name} must be exactly #{EPOCH_KEY_LENGTH} bytes, got #{key.size}")
          end
        end

        private def validate_key_time_pairing!(name : String, key : Bytes?, time : UInt64?) : Nil
          if key.nil? != time.nil?
            raise ArgumentError.new("#{name} and its start time must both be set or both be null")
          end
        end

        private def validate_nonzero_time!(time : UInt64?, name : String) : Nil
          return unless time
          if time == 0
            raise ArgumentError.new("#{name} cannot be 0")
          end
        end

        private def validate_epoch_ordering! : Nil
          times = [] of UInt64
          times << epoch_start_time0.as(UInt64) if epoch_start_time0
          times << epoch_start_time1.as(UInt64) if epoch_start_time1
          times << epoch_start_time2.as(UInt64) if epoch_start_time2

          # Check strict ordering: each time must be less than the next
          (0...times.size - 1).each do |i|
            unless times[i] < times[i + 1]
              raise ArgumentError.new("Epoch start times must be strictly ordered (start0 < start1 < start2)")
            end
          end
        end
      end

      # Group Key Map entry (TLV-serializable for attribute encoding)
      # Maps a group ID to a key set ID within a fabric
      # Matter Core Spec §11.2.6.4
      struct GroupKeyMapStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 1)]
        property group_id : UInt16

        @[TLV::Field(tag: 2)]
        property group_key_set_id : UInt16

        @[TLV::Field(tag: 254)]
        property fabric_index : UInt8

        def initialize(@group_id : UInt16, @group_key_set_id : UInt16, @fabric_index : UInt8 = 0)
          validate!
        end

        def validate! : Nil
          if group_id == RESERVED_GROUP_ID
            raise ArgumentError.new("Group ID 0 is reserved and invalid")
          end
        end
      end

      # Incoming fabric-scoped entries omit FabricIndex; the authenticated
      # accessing fabric supplies it. Stored/read entries use GroupKeyMapStruct.
      private struct GroupKeyMapWriteStruct
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        property group_id : UInt16

        @[TLV::Field(tag: 2)]
        property group_key_set_id : UInt16

        @[TLV::Field(tag: 254, optional: true)]
        property fabric_index : UInt8?

        def initialize(@group_id : UInt16, @group_key_set_id : UInt16, @fabric_index : UInt8? = nil)
        end
      end

      # Group Info Map entry (TLV-serializable for attribute encoding)
      # Represents a group with its endpoints and name
      # Matter Core Spec §11.2.6.5
      struct GroupInfoMapStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 1)]
        property group_id : UInt16

        @[TLV::Field(tag: 2)]
        property endpoints : Array(UInt16)

        @[TLV::Field(tag: 3, optional: true)]
        property group_name : String?

        @[TLV::Field(tag: 254)]
        property fabric_index : UInt8

        def initialize(
          @group_id : UInt16,
          @endpoints : Array(UInt16) = [] of UInt16,
          @group_name : String? = nil,
          @fabric_index : UInt8 = 0,
        )
        end
      end

      # Matter 1.6 §11.2.6.5. A missing entry means the fabric has not adopted
      # Groupcast yet. The incoming FabricIndex is ignored in favor of CASE.
      struct GroupcastAdoptionStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property? groupcast_adopted : Bool

        @[TLV::Field(tag: 254, optional: true)]
        property fabric_index : UInt8?

        def initialize(@groupcast_adopted : Bool, @fabric_index : UInt8? = nil)
        end
      end

      # KeySetWrite command request
      # Matter Core Spec §11.2.8.1
      struct KeySetWriteRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_key_set : GroupKeySetStruct

        def initialize(@group_key_set : GroupKeySetStruct)
        end
      end

      # KeySetRead command request
      # Matter Core Spec §11.2.8.2
      struct KeySetReadRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_key_set_id : UInt16

        def initialize(@group_key_set_id : UInt16)
        end
      end

      # KeySetRead command response
      # Returns the key set without actual key material (secure)
      # Matter Core Spec §11.2.8.2
      struct KeySetReadResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_key_set : GroupKeySetStruct

        def initialize(@group_key_set : GroupKeySetStruct)
        end
      end

      # KeySetRemove command request
      # Matter Core Spec §11.2.8.3
      struct KeySetRemoveRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_key_set_id : UInt16

        def initialize(@group_key_set_id : UInt16)
        end
      end

      # KeySetReadAllIndices command response
      # Returns list of all key set IDs for the accessing fabric
      # Matter Core Spec §11.2.8.4
      struct KeySetReadAllIndicesResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_key_set_i_ds : Array(UInt16)

        def initialize(@group_key_set_i_ds : Array(UInt16) = [] of UInt16)
        end
      end

      # GroupKeyMap and GroupTable are fabric-scoped: reads are filtered to the
      # accessing fabric and a GroupKeyMap write replaces only that fabric's
      # entries (`group_key_map=`). Persistence is hand-written below (key
      # sets are stored alongside).
      attribute 0x0000, :group_key_map, Array(GroupKeyMapStruct), computed: true, writable: true, write_access: :manage, fabric_scoped: true
      attribute 0x0001, :group_table, Array(GroupInfoMapStruct), computed: true, fabric_scoped: true

      # A GroupKeyMap write needs a fabric and stays within its limits (Matter Core §11.2.7.1).
      before_write :group_key_map do |entries|
        if request_fabric_index.nil?
          InteractionModel::Status.unsupported_access
        elsif entries.any? { |entry| entry.group_id == RESERVED_GROUP_ID || entry.group_key_set_id == IPK_KEY_SET_ID }
          InteractionModel::Status.constraint_error
        elsif entries.size > @max_groups_per_fabric
          InteractionModel::Status.resource_exhausted
        end
      end
      attribute 0x0002, :max_groups_per_fabric, UInt16, default: DEFAULT_MAX_GROUPS_PER_FABRIC, fixed: true
      attribute 0x0003, :max_group_keys_per_fabric, UInt16, default: DEFAULT_MAX_GROUP_KEYS_PER_FABRIC, fixed: true
      attribute 0x0004, :groupcast_adoption, Array(GroupcastAdoptionStruct), computed: true,
        writable: true, read_access: :administer, write_access: :administer,
        fabric_scoped: true, requires: :groupcast

      command 0x00, :key_set_write, request: KeySetWriteRequest, access: :administer
      command 0x01, :key_set_read, request: KeySetReadRequest, response: KeySetReadResponse, response_id: 0x02, access: :administer
      command 0x03, :key_set_remove, request: KeySetRemoveRequest, access: :administer
      command 0x04, :key_set_read_all_indices, response: KeySetReadAllIndicesResponse, response_id: 0x05, access: :administer

      @group_key_map = [] of GroupKeyMapStruct
      @group_table = [] of GroupInfoMapStruct
      @groupcast_adoption = [] of GroupcastAdoptionStruct

      # Internal storage (fabric-scoped)
      # Key: fabricIndex, Value: GroupKeySetStruct (with actual keys stored)
      @key_sets : Hash(UInt8, Hash(UInt16, GroupKeySetStruct))

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @feature_map : Feature = Feature::None,
        @max_groups_per_fabric : UInt16 = DEFAULT_MAX_GROUPS_PER_FABRIC,
        @max_group_keys_per_fabric : UInt16 = DEFAULT_MAX_GROUP_KEYS_PER_FABRIC,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @key_sets = Hash(UInt8, Hash(UInt16, GroupKeySetStruct)).new
      end

      # Replaces the accessing fabric's GroupKeyMap entries.
      def group_key_map=(entries : Array(GroupKeyMapStruct)) : Nil
        fabric_index = accessing_fabric_index
        if groupcast_adopted?(fabric_index)
          raise Matter::ClusterError.new("GroupKeyMap is read-only after Groupcast adoption", InteractionModel::StatusCode::InvalidInState)
        end
        entries.map! do |entry|
          entry.fabric_index = fabric_index
          entry
        end
        @group_key_map.reject! { |entry| entry.fabric_index == fabric_index }
        @group_key_map.concat(entries)
        increment_version_and_notify(ATTR_GROUP_KEY_MAP)
      end

      # ------------------------------------------------------------------------
      # Commands: thin wrappers supplying the accessing fabric to the handlers
      # ------------------------------------------------------------------------

      def key_set_write(request : KeySetWriteRequest) : InteractionModel::Status
        handle_key_set_write(request, accessing_fabric_index)
        InteractionModel::Status.success
      rescue ex : EpochKeyLengthError
        raise Matter::ClusterError.new(ex.message || "Invalid epoch key length", InteractionModel::StatusCode::ConstraintError)
      end

      def key_set_read(request : KeySetReadRequest) : KeySetReadResponse
        handle_key_set_read(request, accessing_fabric_index) ||
          raise Matter::ClusterError.new("Key set #{request.group_key_set_id} not found", InteractionModel::StatusCode::NotFound)
      end

      def key_set_remove(request : KeySetRemoveRequest) : InteractionModel::Status
        handle_key_set_remove(request, accessing_fabric_index)
        InteractionModel::Status.success
      end

      def key_set_read_all_indices : KeySetReadAllIndicesResponse
        handle_key_set_read_all_indices(accessing_fabric_index)
      end

      # Key sets are fabric-scoped, so the commands need a fabric-bound session.
      private def accessing_fabric_index : UInt8
        request_fabric_index || raise Matter::ClusterError.new("Group key commands require a fabric-scoped session", InteractionModel::StatusCode::UnsupportedAccess)
      end

      # The fabric-scoped lists hold only the accessing fabric's entries; a
      # read outside a fabric sees none.
      def group_key_map(fabric_index : UInt8?) : Array(GroupKeyMapStruct)
        return [] of GroupKeyMapStruct if fabric_index && groupcast_adopted?(fabric_index)
        operational_group_key_map(fabric_index)
      end

      def group_table(fabric_index : UInt8?) : Array(GroupInfoMapStruct)
        return [] of GroupInfoMapStruct if fabric_index && groupcast_adopted?(fabric_index)
        operational_group_table(fabric_index)
      end

      def operational_group_key_map(fabric_index : UInt8?) : Array(GroupKeyMapStruct)
        @group_key_map.select { |entry| entry.fabric_index == fabric_index }
      end

      def operational_group_table(fabric_index : UInt8?) : Array(GroupInfoMapStruct)
        @group_table.select { |entry| entry.fabric_index == fabric_index }
      end

      def groupcast_adoption(fabric_index : UInt8?) : Array(GroupcastAdoptionStruct)
        @groupcast_adoption.select { |entry| entry.fabric_index == fabric_index }
      end

      def groupcast_adopted?(fabric_index : UInt8) : Bool
        @groupcast_adoption.any? { |entry| entry.fabric_index == fabric_index && entry.groupcast_adopted? }
      end

      def groupcast_adoption=(entries : Array(GroupcastAdoptionStruct)) : Nil
        fabric_index = accessing_fabric_index
        if entries.size > 1
          raise Matter::ClusterError.new("Only one GroupcastAdoption entry is allowed per fabric", InteractionModel::StatusCode::ConstraintError)
        end
        @groupcast_adoption.reject! { |entry| entry.fabric_index == fabric_index }
        entries.each do |entry|
          @groupcast_adoption << GroupcastAdoptionStruct.new(entry.groupcast_adopted?, fabric_index)
        end
        increment_version_and_notify(ATTR_GROUPCAST_ADOPTION)
        notify_changed(ATTR_GROUP_KEY_MAP)
        notify_changed(ATTR_GROUP_TABLE)
      end

      # Groupcast owns the operational mapping even after adoption makes the
      # legacy GKM attributes appear empty on the wire. This is the source used
      # for authenticated group packets and local multicast joins.
      def replace_groupcast_membership(group_id : UInt16, endpoints : Array(UInt16),
                                       key_set_id : UInt16, fabric_index : UInt8) : Nil
        @group_key_map.reject! { |entry| entry.fabric_index == fabric_index && entry.group_id == group_id }
        @group_table.reject! { |entry| entry.fabric_index == fabric_index && entry.group_id == group_id }
        unless endpoints.empty?
          @group_key_map << GroupKeyMapStruct.new(group_id, key_set_id, fabric_index)
          @group_table << GroupInfoMapStruct.new(group_id, endpoints.dup, nil, fabric_index)
        end
        increment_version_and_notify(ATTR_GROUP_KEY_MAP)
        notify_changed(ATTR_GROUP_TABLE)
      end

      # KeySetWrite command handler
      # Matter Core Spec §11.2.8.1
      #
      # Creates or updates a group key set. Performs extensive validation:
      # - Validates key set structure (epoch ordering, key lengths, etc.)
      # - Enforces max_group_keys_per_fabric limit
      # - Prevents creation of duplicate key set IDs within fabric
      # - Security policy must be TrustFirst
      def handle_key_set_write(cmd : KeySetWriteRequest, fabric_index : UInt8) : Nil
        key_set = cmd.group_key_set

        # Validate the key set structure
        key_set.validate!

        # Ensure fabric key sets storage exists
        @key_sets[fabric_index] ||= Hash(UInt16, GroupKeySetStruct).new

        fabric_key_sets = @key_sets[fabric_index]

        # Check resource limits: max_group_keys_per_fabric
        # Don't count the key set being updated
        existing_count = fabric_key_sets.keys.count { |id| id != key_set.group_key_set_id }
        if existing_count >= max_group_keys_per_fabric
          raise Matter::ClusterError.new("Cannot exceed max_group_keys_per_fabric (#{max_group_keys_per_fabric})", InteractionModel::StatusCode::ResourceExhausted)
        end

        # Store the key set (create or update)
        fabric_key_sets[key_set.group_key_set_id] = key_set
        increment_version
      end

      # KeySetRead command handler
      # Matter Core Spec §11.2.8.2
      #
      # Returns a key set by ID, but with actual key material removed for security.
      # Returns null if key set not found for this fabric.
      def handle_key_set_read(cmd : KeySetReadRequest, fabric_index : UInt8) : KeySetReadResponse?
        fabric_key_sets = @key_sets[fabric_index]?
        return unless fabric_key_sets

        key_set = fabric_key_sets[cmd.group_key_set_id]?
        return unless key_set

        # Return key set with actual key bytes removed (security requirement)
        sanitized = GroupKeySetStruct.new(
          group_key_set_id: key_set.group_key_set_id,
          group_key_security_policy: key_set.group_key_security_policy,
          epoch_key0: nil, # Remove actual key material
          epoch_start_time0: key_set.epoch_start_time0,
          epoch_key1: nil,
          epoch_start_time1: key_set.epoch_start_time1,
          epoch_key2: nil,
          epoch_start_time2: key_set.epoch_start_time2
        )

        KeySetReadResponse.new(sanitized)
      end

      # KeySetRemove command handler
      # Matter Core Spec §11.2.8.3
      #
      # Removes a key set by ID. Special rules:
      # - Cannot remove key set 0 (IPK - Identity Protection Key)
      # - Removes any group key map entries referencing this key set
      # - Returns error if key set not found
      def handle_key_set_remove(cmd : KeySetRemoveRequest, fabric_index : UInt8) : Nil
        # IPK Protection: Cannot remove key set 0 (Identity Protection Key)
        if cmd.group_key_set_id == IPK_KEY_SET_ID
          raise Matter::ClusterError.new("Cannot remove key set 0 (IPK)", InteractionModel::StatusCode::ConstraintError)
        end

        fabric_key_sets = @key_sets[fabric_index]?
        unless fabric_key_sets
          raise Matter::ClusterError.new("Key set #{cmd.group_key_set_id} not found", InteractionModel::StatusCode::NotFound)
        end

        unless fabric_key_sets.has_key?(cmd.group_key_set_id)
          raise Matter::ClusterError.new("Key set #{cmd.group_key_set_id} not found", InteractionModel::StatusCode::NotFound)
        end

        # Remove the key set
        fabric_key_sets.delete(cmd.group_key_set_id)

        # Remove any group key map entries referencing this key set
        @group_key_map.reject! do |entry|
          entry.fabric_index == fabric_index &&
            entry.group_key_set_id == cmd.group_key_set_id
        end
        increment_version_and_notify(ATTR_GROUP_KEY_MAP)
      end

      # KeySetReadAllIndices command handler
      # Matter Core Spec §11.2.8.4
      #
      # Returns list of all key set IDs for the accessing fabric.
      def handle_key_set_read_all_indices(fabric_index : UInt8) : KeySetReadAllIndicesResponse
        fabric_key_sets = @key_sets[fabric_index]?
        return KeySetReadAllIndicesResponse.new([] of UInt16) unless fabric_key_sets

        key_set_ids = fabric_key_sets.keys.sort!
        KeySetReadAllIndicesResponse.new(key_set_ids)
      end

      # Add or update a group key map entry
      # Links a group to a key set within a fabric
      #
      # Validations:
      # - Group ID must not be 0
      # - Key set must exist in the fabric
      # - Must not exceed max_groups_per_fabric
      def add_group_key_map(
        group_id : UInt16,
        group_key_set_id : UInt16,
        fabric_index : UInt8,
      ) : Nil
        # Validate group ID
        if group_id == RESERVED_GROUP_ID
          raise Matter::ClusterError.new("Group ID 0 is invalid", InteractionModel::StatusCode::ConstraintError)
        end

        # Validate that key set exists
        fabric_key_sets = @key_sets[fabric_index]?
        unless fabric_key_sets && fabric_key_sets.has_key?(group_key_set_id)
          raise Matter::ClusterError.new("Key set #{group_key_set_id} does not exist", InteractionModel::StatusCode::NotFound)
        end

        # Check if mapping already exists (update case)
        existing_index = @group_key_map.index do |entry|
          entry.fabric_index == fabric_index && entry.group_id == group_id
        end

        if existing_index
          # Update existing mapping
          @group_key_map[existing_index] = GroupKeyMapStruct.new(
            group_id, group_key_set_id, fabric_index
          )
        else
          # Check resource limit: max_groups_per_fabric
          fabric_groups = @group_key_map.count { |e| e.fabric_index == fabric_index }
          if fabric_groups >= max_groups_per_fabric
            raise Matter::ClusterError.new("Cannot exceed max_groups_per_fabric (#{max_groups_per_fabric})", InteractionModel::StatusCode::ResourceExhausted)
          end

          # Add new mapping
          @group_key_map << GroupKeyMapStruct.new(group_id, group_key_set_id, fabric_index)
        end
        increment_version_and_notify(ATTR_GROUP_KEY_MAP)
      end

      # Handles a complete list replacement or chip-tool's empty-list clear
      # followed by list-item appends. FabricIndex on the wire is ignored.
      def write_group_key_map(value : TLV::Any, fabric_index : UInt8) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state if groupcast_adopted?(fabric_index)
        if list = value.as_list?
          return InteractionModel::Status.resource_exhausted if list.size > max_groups_per_fabric
          entries = list.map { |item| GroupKeyMapWriteStruct.from_tlv(item) }
          return InteractionModel::Status.constraint_error if entries.any? { |entry| entry.group_id == 0 || entry.group_key_set_id == 0 }
          return InteractionModel::Status.constraint_error if entries.map(&.group_id).to_set.size != entries.size
          return InteractionModel::Status.not_found if entries.any? { |entry| !get_key_set(entry.group_key_set_id, fabric_index) }
          self.group_key_map = entries.map { |entry| GroupKeyMapStruct.new(entry.group_id, entry.group_key_set_id, fabric_index) }
        elsif value.as_structure?
          entry = GroupKeyMapWriteStruct.from_tlv(value)
          return InteractionModel::Status.constraint_error if entry.group_key_set_id == IPK_KEY_SET_ID
          add_group_key_map(entry.group_id, entry.group_key_set_id, fabric_index)
        else
          return InteractionModel::Status.invalid_data_type
        end
        InteractionModel::Status.success
      rescue ex : Matter::ClusterError
        ex.to_status
      rescue TLV::DeserializationError | TypeCastError | ArgumentError
        InteractionModel::Status.invalid_data_type
      end

      # Remove a group key map entry
      def remove_group_key_map(group_id : UInt16, fabric_index : UInt8) : Nil
        @group_key_map.reject! do |entry|
          entry.fabric_index == fabric_index && entry.group_id == group_id
        end
        increment_version_and_notify(ATTR_GROUP_KEY_MAP)
      end

      # Add a group to the group table
      # Called by Groups cluster when AddGroup command is executed
      #
      # Membership can be provisioned before its GroupKeyMap entry. A mapped
      # operational key is required only when receiving group messages.
      def add_group(
        group_id : UInt16,
        endpoint_id : UInt16,
        group_name : String?,
        fabric_index : UInt8,
      ) : Nil
        # Find or create group info
        existing = @group_table.find do |entry|
          entry.fabric_index == fabric_index && entry.group_id == group_id
        end

        if existing
          # Add endpoint to existing group if not already present
          unless existing.endpoints.includes?(endpoint_id)
            # Reconstruct with updated endpoints (struct immutability)
            new_endpoints = existing.endpoints + [endpoint_id]
            @group_table.reject! do |entry|
              entry.fabric_index == fabric_index && entry.group_id == group_id
            end
            @group_table << GroupInfoMapStruct.new(
              group_id, new_endpoints, existing.group_name, fabric_index
            )
          end
        else
          # Check resource limit
          fabric_groups = @group_table.count { |e| e.fabric_index == fabric_index }
          if fabric_groups >= max_groups_per_fabric
            raise Matter::ClusterError.new("Cannot exceed max_groups_per_fabric (#{max_groups_per_fabric})", InteractionModel::StatusCode::ResourceExhausted)
          end

          # Create new group
          @group_table << GroupInfoMapStruct.new(
            group_id, [endpoint_id], group_name, fabric_index
          )
        end
        increment_version_and_notify(ATTR_GROUP_TABLE)
      end

      # Remove an endpoint from a group
      # Called by Groups cluster when RemoveGroup command is executed
      def remove_group(group_id : UInt16, endpoint_id : UInt16, fabric_index : UInt8) : Nil
        existing_index = @group_table.index do |entry|
          entry.fabric_index == fabric_index && entry.group_id == group_id
        end
        return unless existing_index

        existing = @group_table[existing_index]

        # Remove endpoint from group
        new_endpoints = existing.endpoints.reject { |endpoint| endpoint == endpoint_id }

        if new_endpoints.empty?
          # Remove entire group if no endpoints remain
          @group_table.delete_at(existing_index)
        else
          # Update group with remaining endpoints
          @group_table[existing_index] = GroupInfoMapStruct.new(
            group_id, new_endpoints, existing.group_name, fabric_index
          )
        end
        increment_version_and_notify(ATTR_GROUP_TABLE)
      end

      # Indexes with stored keys or group mappings, including crashed removals.
      def fabric_indices : Array(UInt8)
        (@key_sets.keys + @group_key_map.map(&.fabric_index) +
          @group_table.map(&.fabric_index) +
          @groupcast_adoption.compact_map(&.fabric_index)).uniq
      end

      # Remove all groups for a fabric (fabric removal).
      def remove_fabric(fabric_index : UInt8) : Nil
        @key_sets.delete(fabric_index)
        @group_key_map.reject! { |entry| entry.fabric_index == fabric_index }
        @group_table.reject! { |entry| entry.fabric_index == fabric_index }
        @groupcast_adoption.reject! { |entry| entry.fabric_index == fabric_index }
        increment_version_and_notify(ATTR_GROUP_KEY_MAP)
        notify_changed(ATTR_GROUP_TABLE)
        notify_changed(ATTR_GROUPCAST_ADOPTION) if @feature_map.groupcast?
      end

      # Get a key set by ID (for cryptographic operations)
      # Returns the actual key set with key material
      def get_key_set(group_key_set_id : UInt16, fabric_index : UInt8) : GroupKeySetStruct?
        fabric_key_sets = @key_sets[fabric_index]?
        return unless fabric_key_sets

        fabric_key_sets[group_key_set_id]?
      end

      # Check if a group exists for a fabric
      def group_exists?(group_id : UInt16, fabric_index : UInt8) : Bool
        @group_table.any? do |entry|
          entry.fabric_index == fabric_index && entry.group_id == group_id
        end
      end

      # Get all key set IDs for a fabric (for testing)
      def get_key_set_ids(fabric_index : UInt8) : Array(UInt16)
        fabric_key_sets = @key_sets[fabric_index]?
        return [] of UInt16 unless fabric_key_sets

        fabric_key_sets.keys.sort!
      end

      # ------------------------------------------------------------------------
      # Persistence support
      # ------------------------------------------------------------------------

      struct PersistedKeySet
        include Storage::Record

        getter group_key_set_id : UInt16
        getter group_key_security_policy : GroupKeySecurityPolicyEnum
        getter epoch_key0 : Bytes?
        getter epoch_start_time0 : UInt64?
        getter epoch_key1 : Bytes?
        getter epoch_start_time1 : UInt64?
        getter epoch_key2 : Bytes?
        getter epoch_start_time2 : UInt64?
        getter group_key_multicast_policy : GroupKeyMulticastPolicyEnum?

        def initialize(
          @group_key_set_id : UInt16,
          @group_key_security_policy : GroupKeySecurityPolicyEnum,
          @epoch_key0 : Bytes?,
          @epoch_start_time0 : UInt64?,
          @epoch_key1 : Bytes?,
          @epoch_start_time1 : UInt64?,
          @epoch_key2 : Bytes?,
          @epoch_start_time2 : UInt64?,
          @group_key_multicast_policy : GroupKeyMulticastPolicyEnum?,
        )
        end

        def self.from_key_set(key_set : GroupKeySetStruct) : PersistedKeySet
          new(
            group_key_set_id: key_set.group_key_set_id,
            group_key_security_policy: key_set.group_key_security_policy,
            epoch_key0: key_set.epoch_key0,
            epoch_start_time0: key_set.epoch_start_time0,
            epoch_key1: key_set.epoch_key1,
            epoch_start_time1: key_set.epoch_start_time1,
            epoch_key2: key_set.epoch_key2,
            epoch_start_time2: key_set.epoch_start_time2,
            group_key_multicast_policy: key_set.group_key_multicast_policy
          )
        end

        def to_key_set : GroupKeySetStruct
          GroupKeySetStruct.new(
            group_key_set_id: @group_key_set_id,
            group_key_security_policy: @group_key_security_policy,
            epoch_key0: @epoch_key0,
            epoch_start_time0: @epoch_start_time0,
            epoch_key1: @epoch_key1,
            epoch_start_time1: @epoch_start_time1,
            epoch_key2: @epoch_key2,
            epoch_start_time2: @epoch_start_time2,
            group_key_multicast_policy: @group_key_multicast_policy
          )
        end
      end

      private struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter key_sets : Hash(UInt8, Array(PersistedKeySet))
        getter group_key_map : Array(GroupKeyMapStruct)
        getter group_table : Array(GroupInfoMapStruct)
        getter groupcast_adoption : Array(GroupcastAdoptionStruct) = [] of GroupcastAdoptionStruct

        def initialize(
          @data_version : UInt32,
          @key_sets : Hash(UInt8, Array(PersistedKeySet)),
          @group_key_map : Array(GroupKeyMapStruct),
          @group_table : Array(GroupInfoMapStruct),
          @groupcast_adoption : Array(GroupcastAdoptionStruct) = [] of GroupcastAdoptionStruct,
        )
        end
      end

      def save_state : Storage::Document?
        key_sets = Hash(UInt8, Array(PersistedKeySet)).new
        @key_sets.each do |fabric_index, sets|
          key_sets[fabric_index] = sets.values.map { |key_set| PersistedKeySet.from_key_set(key_set) }
        end

        PersistedState.new(
          data_version: @data_version,
          key_sets: key_sets,
          group_key_map: @group_key_map,
          group_table: @group_table,
          groupcast_adoption: @groupcast_adoption
        ).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)

        @key_sets.clear
        state.key_sets.each do |fabric_index, key_sets|
          fabric_key_sets = (@key_sets[fabric_index] ||= Hash(UInt16, GroupKeySetStruct).new)
          key_sets.each do |key_set|
            fabric_key_sets[key_set.group_key_set_id] = key_set.to_key_set
          end
        end

        @group_key_map = state.group_key_map
        @group_table = state.group_table
        @groupcast_adoption = state.groupcast_adoption

        @data_version = state.data_version
      rescue ex
        Log.error(exception: ex) { "GroupKeyManagement restore_state failed; starting fresh" }
      end
    end
  end
end
