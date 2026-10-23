require "./cluster"
require "./group_key_management"
require "./access_control"

module Matter
  module Cluster
    # Opt-in Matter 1.6 Groupcast (0x0065). The Groupcast cluster is
    # provisional in 1.6, so ordinary devices keep using legacy Groups.
    # Membership is the persistent owner of endpoint and group policy. GKM
    # retains the operational key mapping even after adoption hides its legacy
    # GroupKeyMap and GroupTable attributes from the accessing fabric.
    class Groupcast < Base
      cluster 0x0065, revision: 1, persist_state: false

      feature :listener, bit: 0
      feature :sender, bit: 1
      feature :per_group, bit: 2

      DEFAULT_MAX_MEMBERSHIP_COUNT   =     10_u16
      DEFAULT_MAX_MCAST_ADDR_COUNT   =      1_u16
      MIN_PER_GROUP_MCAST_ADDR_COUNT =      4_u16
      MAX_GROUP_ID                   = 0xFFF7_u16
      MAX_ENDPOINT                   = 0xFFFE_u16
      MAX_MEMBERSHIP_ENDPOINTS       =        255
      MAX_LEAVE_ENDPOINTS            =         20
      KEY_BYTES                      =         16
      DEFAULT_TEST_DURATION          =     60_u16
      MIN_TEST_DURATION              =     10_u16
      MAX_TEST_DURATION              =   1200_u16

      enum MulticastAddrPolicyEnum : UInt8
        IanaAddr = 0
        PerGroup = 1
      end

      enum GroupcastTestingEnum : UInt8
        DisableTesting        = 0
        EnableListenerTesting = 1
        EnableSenderTesting   = 2
      end

      enum GroupcastTestResultEnum : UInt8
        Success        = 0
        GeneralError   = 1
        MessageReplay  = 2
        FailedAuth     = 3
        NoAvailableKey = 4
        SendFailure    = 5
      end

      struct MembershipStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        @[Storage::Field(key: "endpoints")]
        property endpoints_field : Array(UInt16)?

        @[TLV::Field(tag: 2)]
        property key_set_id : UInt16

        @[TLV::Field(tag: 3, optional: true)]
        @[Storage::Field(key: "has_auxiliary_acl")]
        property has_auxiliary_acl_field : Bool?

        @[TLV::Field(tag: 4)]
        property mcast_addr_policy : MulticastAddrPolicyEnum

        @[TLV::Field(tag: 254, optional: true)]
        property fabric_index : UInt8?

        def initialize(@group_id : UInt16, @endpoints_field : Array(UInt16)?, @key_set_id : UInt16,
                       @has_auxiliary_acl_field : Bool? = false,
                       @mcast_addr_policy : MulticastAddrPolicyEnum = MulticastAddrPolicyEnum::IanaAddr,
                       @fabric_index : UInt8? = nil)
        end

        def endpoints : Array(UInt16)
          @endpoints_field || [] of UInt16
        end

        def has_auxiliary_acl? : Bool
          @has_auxiliary_acl_field || false
        end
      end

      struct JoinGroupRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1)]
        property endpoints : Array(UInt16)

        @[TLV::Field(tag: 2)]
        property key_set_id : UInt16

        @[TLV::Field(tag: 3, optional: true)]
        property key : Bytes?

        @[TLV::Field(tag: 4, optional: true)]
        property use_auxiliary_acl : Bool?

        @[TLV::Field(tag: 5, optional: true)]
        property replace_endpoints : Bool?

        @[TLV::Field(tag: 6, optional: true)]
        property mcast_addr_policy : MulticastAddrPolicyEnum?

        def initialize(@group_id : UInt16, @endpoints : Array(UInt16), @key_set_id : UInt16,
                       @key : Bytes? = nil, @use_auxiliary_acl : Bool? = nil,
                       @replace_endpoints : Bool? = nil,
                       @mcast_addr_policy : MulticastAddrPolicyEnum? = nil)
        end
      end

      struct LeaveGroupRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        property endpoints : Array(UInt16)?

        def initialize(@group_id : UInt16, @endpoints : Array(UInt16)? = nil)
        end
      end

      struct LeaveGroupResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1)]
        property endpoints : Array(UInt16)

        def initialize(@group_id : UInt16, @endpoints : Array(UInt16))
        end
      end

      struct UpdateGroupKeyRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1)]
        property key_set_id : UInt16

        @[TLV::Field(tag: 2, optional: true)]
        property key : Bytes?

        def initialize(@group_id : UInt16, @key_set_id : UInt16, @key : Bytes? = nil)
        end
      end

      struct ConfigureAuxiliaryAclRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1)]
        property? use_auxiliary_acl : Bool

        def initialize(@group_id : UInt16, @use_auxiliary_acl : Bool)
        end
      end

      struct GroupcastTestingRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property test_operation : GroupcastTestingEnum

        @[TLV::Field(tag: 1, optional: true)]
        property duration_seconds : UInt16?

        def initialize(@test_operation : GroupcastTestingEnum, @duration_seconds : UInt16? = nil)
        end
      end

      struct GroupcastTestingEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property source_ip_address : Bytes?

        @[TLV::Field(tag: 1, optional: true)]
        property destination_ip_address : Bytes?

        @[TLV::Field(tag: 2, optional: true)]
        property group_id : UInt16?

        @[TLV::Field(tag: 3, optional: true)]
        property endpoint_id : UInt16?

        @[TLV::Field(tag: 4, optional: true)]
        property cluster_id : UInt32?

        @[TLV::Field(tag: 5, optional: true)]
        property element_id : UInt32?

        @[TLV::Field(tag: 6, optional: true)]
        property access_allowed : Bool?

        @[TLV::Field(tag: 7)]
        property groupcast_test_result : GroupcastTestResultEnum

        def initialize(@groupcast_test_result : GroupcastTestResultEnum,
                       @group_id : UInt16? = nil, @endpoint_id : UInt16? = nil,
                       @cluster_id : UInt32? = nil, @element_id : UInt32? = nil,
                       @access_allowed : Bool? = nil,
                       @source_ip_address : Bytes? = nil,
                       @destination_ip_address : Bytes? = nil)
        end
      end

      attribute 0x0000, :membership, Array(MembershipStruct), computed: true,
        fabric_scoped: true, read_access: :view
      attribute 0x0001, :max_membership_count, UInt16, default: DEFAULT_MAX_MEMBERSHIP_COUNT, fixed: true
      attribute 0x0002, :max_mcast_addr_count, UInt16, default: DEFAULT_MAX_MCAST_ADDR_COUNT, fixed: true
      attribute 0x0003, :used_mcast_addr_count, UInt16, computed: true
      attribute 0x0004, :fabric_under_test, UInt8, computed: true

      command 0x00, :join_group, request: JoinGroupRequest, access: :manage
      command 0x01, :leave_group, request: LeaveGroupRequest, response: LeaveGroupResponse,
        response_id: 0x02, access: :manage
      command 0x03, :update_group_key, request: UpdateGroupKeyRequest, access: :manage
      command 0x04, :configure_auxiliary_acl, request: ConfigureAuxiliaryAclRequest,
        access: :administer, requires: :listener
      command 0x05, :groupcast_testing, request: GroupcastTestingRequest, access: :administer

      event 0x00, :groupcast_testing, priority: :info, access: :administer,
        payload: GroupcastTestingEvent

      @membership = [] of MembershipStruct
      @test_fabric = 0_u8
      @test_operation = GroupcastTestingEnum::DisableTesting
      @test_deadline : Time::Instant? = nil
      @test_generation = 0_u32
      property endpoint_exists : Proc(UInt16, Bool)?
      property on_membership_changed : Proc(Nil)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @group_keys : GroupKeyManagement,
                     @access_control : AccessControl,
                     @feature_map : Feature = Feature::Listener,
                     @max_membership_count : UInt16 = DEFAULT_MAX_MEMBERSHIP_COUNT,
                     @max_mcast_addr_count : UInt16 = DEFAULT_MAX_MCAST_ADDR_COUNT)
        valid_configuration = endpoint_id.number == 0_u16 &&
                              (@feature_map.listener? || @feature_map.sender?) &&
                              @group_keys.feature_map.groupcast? &&
                              (!@feature_map.listener? || @access_control.feature_map.auxiliary?) &&
                              @max_membership_count >= DEFAULT_MAX_MEMBERSHIP_COUNT &&
                              @max_mcast_addr_count >= DEFAULT_MAX_MCAST_ADDR_COUNT &&
                              (!@feature_map.per_group? || @max_mcast_addr_count >= MIN_PER_GROUP_MCAST_ADDR_COUNT)
        raise Matter::ConfigurationError.new("Groupcast needs LN or SD, root GKM GCAST, AUX with LN, and at least four addresses with PGA") unless valid_configuration
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def membership(fabric_index : UInt8?) : Array(MembershipStruct)
        return [] of MembershipStruct unless fabric_index
        entries = @membership.select { |entry| entry.fabric_index == fabric_index }
        entries.map do |entry|
          MembershipStruct.new(entry.group_id, entry.endpoints_field.try(&.dup), entry.key_set_id,
            entry.has_auxiliary_acl_field, entry.mcast_addr_policy, entry.fabric_index)
        end
      end

      def used_mcast_addr_count : UInt16
        multicast_address_count(@membership).to_u16
      end

      def fabric_under_test : UInt8
        test_active? ? @test_fabric : 0_u8
      end

      def join_group(request : JoinGroupRequest) : InteractionModel::Status
        fabric = accessing_fabric
        return InteractionModel::Status.constraint_error unless valid_group?(request.group_id) &&
                                                                valid_key_set?(request.key_set_id)
        return InteractionModel::Status.constraint_error if request.endpoints.empty? && !@feature_map.sender?
        return InteractionModel::Status.constraint_error if !@feature_map.listener? && !request.endpoints.empty?
        return InteractionModel::Status.constraint_error if request.endpoints.uniq.size != request.endpoints.size
        return InteractionModel::Status.unsupported_endpoint if request.endpoints.any? { |endpoint| !valid_endpoint?(endpoint) }
        return InteractionModel::Status.constraint_error if request.mcast_addr_policy == MulticastAddrPolicyEnum::PerGroup &&
                                                            !@feature_map.per_group?
        return InteractionModel::Status.constraint_error if !@feature_map.listener? &&
                                                            (!request.use_auxiliary_acl.nil? || !request.replace_endpoints.nil?)
        if request.key || !request.use_auxiliary_acl.nil?
          return InteractionModel::Status.unsupported_access unless administering?(fabric)
        end
        existing = @membership.find { |entry| entry.fabric_index == fabric && entry.group_id == request.group_id }
        if existing.nil?
          return InteractionModel::Status.resource_exhausted if @membership.size >= @max_membership_count ||
                                                                membership(fabric).size >= @max_membership_count // 2
        end
        endpoints = if existing && !request.replace_endpoints
                      (existing.endpoints + request.endpoints).uniq
                    else
                      request.endpoints.dup
                    end
        return InteractionModel::Status.constraint_error if endpoints.size > MAX_MEMBERSHIP_ENDPOINTS
        auxiliary_flag = request.use_auxiliary_acl
        updated = MembershipStruct.new(request.group_id,
          @feature_map.listener? ? endpoints : nil, request.key_set_id,
          @feature_map.listener? ? (auxiliary_flag.nil? ? (existing.try(&.has_auxiliary_acl?) || false) : auxiliary_flag) : nil,
          request.mcast_addr_policy || MulticastAddrPolicyEnum::IanaAddr, fabric)
        projected = @membership.reject { |entry| entry.fabric_index == fabric && entry.group_id == request.group_id }
        projected << updated
        return InteractionModel::Status.resource_exhausted if multicast_address_count(projected) > @max_mcast_addr_count
        key_status = ensure_key_set(fabric, request.key_set_id, request.key)
        return key_status unless key_status.success?
        if @feature_map.listener?
          @group_keys.replace_groupcast_membership(updated.group_id, updated.endpoints,
            updated.key_set_id, fabric)
        end
        @membership.reject! { |entry| entry.fabric_index == fabric && entry.group_id == request.group_id }
        @membership << updated
        changed_membership
        InteractionModel::Status.success
      rescue ex : Matter::ClusterError
        ex.to_status
      end

      def leave_group(request : LeaveGroupRequest) : LeaveGroupResponse | InteractionModel::Status
        fabric = accessing_fabric
        requested = request.endpoints
        return InteractionModel::Status.constraint_error if requested && !@feature_map.listener?
        return InteractionModel::Status.constraint_error if requested && (requested.empty? || requested.size > MAX_LEAVE_ENDPOINTS)
        if request.group_id == 0_u16
          return InteractionModel::Status.constraint_error if requested
          affected = membership(fabric)
          return InteractionModel::Status.not_found if affected.empty?
          if @feature_map.listener?
            affected.each { |entry| @group_keys.replace_groupcast_membership(entry.group_id, [] of UInt16, entry.key_set_id, fabric) }
          end
          @membership.reject! { |entry| entry.fabric_index == fabric }
          changed_membership
          return LeaveGroupResponse.new(0_u16, [] of UInt16)
        end
        index = @membership.index { |entry| entry.fabric_index == fabric && entry.group_id == request.group_id }
        return InteractionModel::Status.not_found unless index
        existing = @membership[index]
        removed = requested.nil? ? existing.endpoints.dup : existing.endpoints.select { |endpoint| requested.includes?(endpoint) }
        # LeaveGroupResponse.Endpoints has a 20-entry limit even though a
        # Membership can contain 255 endpoints. Keep the membership intact so
        # callers can withdraw large groups in bounded endpoint batches.
        return InteractionModel::Status.constraint_error if removed.size > MAX_LEAVE_ENDPOINTS
        remaining = existing.endpoints.reject { |endpoint| removed.includes?(endpoint) }
        if @feature_map.listener?
          @group_keys.replace_groupcast_membership(existing.group_id, remaining, existing.key_set_id, fabric)
        end
        @membership.reject! { |entry| entry.fabric_index == fabric && entry.group_id == request.group_id }
        unless remaining.empty?
          @membership << MembershipStruct.new(existing.group_id, remaining, existing.key_set_id,
            existing.has_auxiliary_acl?, existing.mcast_addr_policy, fabric)
        end
        changed_membership
        LeaveGroupResponse.new(request.group_id, removed)
      rescue ex : Matter::ClusterError
        ex.to_status
      end

      def update_group_key(request : UpdateGroupKeyRequest) : InteractionModel::Status
        fabric = accessing_fabric
        return InteractionModel::Status.constraint_error unless valid_key_set?(request.key_set_id)
        index = @membership.index { |entry| entry.fabric_index == fabric && entry.group_id == request.group_id }
        return InteractionModel::Status.not_found unless index
        existing = @membership[index]
        if request.key
          return InteractionModel::Status.unsupported_access unless administering?(fabric)
        end
        key_status = ensure_key_set(fabric, request.key_set_id, request.key)
        return key_status unless key_status.success?
        if @feature_map.listener?
          @group_keys.replace_groupcast_membership(existing.group_id, existing.endpoints,
            request.key_set_id, fabric)
        end
        existing.key_set_id = request.key_set_id
        @membership[index] = existing
        changed_membership
        InteractionModel::Status.success
      rescue ex : Matter::ClusterError
        ex.to_status
      end

      def configure_auxiliary_acl(request : ConfigureAuxiliaryAclRequest) : InteractionModel::Status
        return InteractionModel::Status.unsupported_command unless @feature_map.listener?
        fabric = accessing_fabric
        index = @membership.index { |entry| entry.fabric_index == fabric && entry.group_id == request.group_id }
        return InteractionModel::Status.not_found unless index
        existing = @membership[index]
        return InteractionModel::Status.success if existing.has_auxiliary_acl? == request.use_auxiliary_acl?
        existing.has_auxiliary_acl_field = request.use_auxiliary_acl?
        @membership[index] = existing
        changed_membership
        InteractionModel::Status.success
      end

      def groupcast_testing(request : GroupcastTestingRequest) : InteractionModel::Status
        fabric = accessing_fabric
        if request.test_operation.enable_listener_testing? && !@feature_map.listener?
          return InteractionModel::Status.constraint_error
        end
        if request.test_operation.enable_sender_testing? && !@feature_map.sender?
          return InteractionModel::Status.constraint_error
        end
        if request.test_operation.enable_listener_testing? || request.test_operation.enable_sender_testing?
          duration = request.duration_seconds || DEFAULT_TEST_DURATION
          return InteractionModel::Status.constraint_error unless (MIN_TEST_DURATION..MAX_TEST_DURATION).includes?(duration)
        elsif !request.test_operation.disable_testing?
          return InteractionModel::Status.constraint_error
        end
        @test_generation &+= 1_u32
        @test_operation = request.test_operation
        if request.test_operation.disable_testing?
          @test_fabric = 0_u8
          @test_deadline = nil
        else
          duration = request.duration_seconds || DEFAULT_TEST_DURATION
          @test_fabric = fabric
          @test_deadline = Time.instant + duration.seconds
          generation = @test_generation
          spawn do
            sleep duration.seconds
            test_active? if generation == @test_generation
          end
        end
        increment_version_and_notify(ATTR_FABRIC_UNDER_TEST)
        InteractionModel::Status.success
      end

      def record_group_message(fabric : UInt8?, group_id : UInt16?,
                               result : GroupcastTestResultEnum,
                               endpoint_id : UInt16? = nil, cluster_id : UInt32? = nil,
                               element_id : UInt32? = nil, access_allowed : Bool? = nil,
                               sender : Bool = false) : Nil
        selected_direction = sender ? @test_operation.enable_sender_testing? : @test_operation.enable_listener_testing?
        return unless selected_direction
        return unless test_active? && (fabric.nil? || @test_fabric == fabric)
        emit_event(EVENT_GROUPCAST_TESTING,
          GroupcastTestingEvent.new(result, group_id, endpoint_id, cluster_id, element_id, access_allowed), @test_fabric)
      end

      def remove_fabric(fabric : UInt8) : Nil
        if @test_fabric == fabric
          @test_generation &+= 1_u32
          @test_fabric = 0_u8
          @test_operation = GroupcastTestingEnum::DisableTesting
          @test_deadline = nil
          increment_version_and_notify(ATTR_FABRIC_UNDER_TEST)
        end
        return unless @membership.any? { |entry| entry.fabric_index == fabric }
        @membership.reject! { |entry| entry.fabric_index == fabric }
        changed_membership
      end

      private def accessing_fabric : UInt8
        unless request_is_case_session? && (fabric = request_fabric_index)
          raise Matter::ClusterError.new("Groupcast commands require CASE", InteractionModel::StatusCode::UnsupportedAccess)
        end
        fabric
      end

      private def administering?(fabric : UInt8) : Bool
        (request_peer_subject_ids || [] of UInt64).any? do |subject|
          @access_control.check_access(subject, fabric, AccessControl::AccessControlEntryPrivilege::Administer,
            cluster: CLUSTER_ID, endpoint: 0_u16)
        end
      end

      private def valid_group?(group_id : UInt16) : Bool
        group_id >= 1_u16 && group_id <= MAX_GROUP_ID
      end

      private def valid_key_set?(id : UInt16) : Bool
        id >= 1_u16 && id != UInt16::MAX
      end

      private def valid_endpoint?(endpoint : UInt16) : Bool
        endpoint > 0_u16 && endpoint <= MAX_ENDPOINT &&
          (@endpoint_exists.try(&.call(endpoint)) || @endpoint_exists.nil?)
      end

      # IANA has one shared policy address; PGA uses one per fabric and group.
      # Sender-only memberships still configure a destination address.
      private def multicast_address_count(entries : Array(MembershipStruct)) : Int32
        iana = false
        per_group = 0
        entries.each do |entry|
          if entry.mcast_addr_policy.per_group?
            per_group += 1
          else
            iana = true
          end
        end
        per_group + (iana ? 1 : 0)
      end

      private def ensure_key_set(fabric : UInt8, id : UInt16, key : Bytes?) : InteractionModel::Status
        if key
          return InteractionModel::Status.constraint_error unless key.size == KEY_BYTES
          return InteractionModel::Status.constraint_error if @group_keys.get_key_set(id, fabric)
          set = GroupKeyManagement::GroupKeySetStruct.new(id, epoch_key0: key,
            epoch_start_time0: 1_u64)
          @group_keys.handle_key_set_write(GroupKeyManagement::KeySetWriteRequest.new(set), fabric)
        elsif @group_keys.get_key_set(id, fabric).nil?
          return InteractionModel::Status.not_found
        end
        InteractionModel::Status.success
      end

      private def changed_membership(emit_event : Bool = true) : Nil
        entries = [] of AccessControl::AccessControlEntry
        @membership.each do |member|
          next unless member.has_auxiliary_acl? && (fabric = member.fabric_index)
          member.endpoints.each_slice(@access_control.targets_per_access_control_entry.to_i) do |endpoints|
            targets = endpoints.map { |endpoint| AccessControl::Target.new(nil, endpoint, nil) }
            entries << AccessControl::AccessControlEntry.new(
              AccessControl::AccessControlEntryPrivilege::Operate,
              AccessControl::AccessControlEntryAuthMode::Group,
              [member.group_id.to_u64], targets, fabric,
              AccessControl::AccessControlAuxiliaryType::Groupcast)
          end
        end
        if @feature_map.listener?
          @access_control.set_groupcast_auxiliary_acl(entries, request_peer_node_id, emit_event)
        end
        increment_version_and_notify(ATTR_MEMBERSHIP)
        notify_changed(ATTR_USED_MCAST_ADDR_COUNT)
        @on_membership_changed.try(&.call)
      end

      private def test_active? : Bool
        deadline = @test_deadline
        return false unless deadline
        if Time.instant < deadline
          true
        else
          @test_fabric = 0_u8
          @test_operation = GroupcastTestingEnum::DisableTesting
          @test_deadline = nil
          increment_version_and_notify(ATTR_FABRIC_UNDER_TEST)
          false
        end
      end

      private struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter membership : Array(MembershipStruct)

        def initialize(@data_version : UInt32, @membership : Array(MembershipStruct))
        end
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @membership).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        if state.membership.any?(&.mcast_addr_policy.per_group?) && !@feature_map.per_group?
          raise Matter::ConfigurationError.new("Stored Groupcast PerGroup membership requires PGA")
        end
        if multicast_address_count(state.membership) > @max_mcast_addr_count
          raise Matter::ConfigurationError.new("Stored Groupcast membership exceeds multicast address capacity")
        end
        @membership = state.membership
        @data_version = state.data_version
        @membership.each do |entry|
          next unless fabric = entry.fabric_index
          if @feature_map.listener?
            @group_keys.replace_groupcast_membership(entry.group_id, entry.endpoints, entry.key_set_id, fabric)
          end
        end
        changed_membership(emit_event: false)
      end
    end
  end
end
