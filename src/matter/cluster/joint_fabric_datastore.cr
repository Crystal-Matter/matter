require "./cluster"
require "./access_control"
require "../datatype/node_id"

module Matter
  module Cluster
    # Matter 1.6 Joint Fabric Datastore cluster (0x0752).
    # Wire layout follows connectedhomeip v1.6.0.0's
    # joint-fabric-datastore-cluster.xml.
    class JointFabricDatastore < Base
      cluster 0x0752, revision: 1

      enum DatastoreAccessControlEntryAuthModeEnum : UInt8
        PASE  = 1
        CASE  = 2
        Group = 3
      end

      enum DatastoreAccessControlEntryPrivilegeEnum : UInt8
        View       = 1
        Operate    = 3
        Manage     = 4
        Administer = 5
      end

      enum DatastoreGroupKeyMulticastPolicyEnum : UInt8
        PerGroupID = 0
        AllNodes   = 1
      end

      enum DatastoreGroupKeySecurityPolicyEnum : UInt8
        TrustFirst = 0
      end

      enum DatastoreStateEnum : UInt8
        Pending       = 0
        Committed     = 1
        DeletePending = 2
        CommitFailed  = 3
      end

      struct DatastoreACLEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property list_id : UInt16

        @[TLV::Field(tag: 2)]
        property acl_entry : DatastoreAccessControlEntryStruct

        @[TLV::Field(tag: 3)]
        property status_entry : DatastoreStatusEntryStruct

        # Local delivery journal. This is persisted but omitted from the
        # cluster wire struct so a changed ACL can replace its old target value
        # even after an Anchor restart.
        property prior_acl_entry : DatastoreAccessControlEntryStruct? = nil

        # Local association with a GroupList entry. The cluster wire schema has
        # no GroupID on ACL entries, so this is deliberately storage-only.
        property associated_group_id : UInt16? = nil

        def initialize(
          @node_id : UInt64,
          @list_id : UInt16,
          @acl_entry : DatastoreAccessControlEntryStruct,
          @status_entry : DatastoreStatusEntryStruct,
        )
        end
      end

      struct DatastoreAccessControlEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 1)]
        property privilege : DatastoreAccessControlEntryPrivilegeEnum

        @[TLV::Field(tag: 2)]
        property auth_mode : DatastoreAccessControlEntryAuthModeEnum

        @[TLV::Field(tag: 3)]
        property subjects : Array(UInt64)?

        @[TLV::Field(tag: 4)]
        property targets : Array(DatastoreAccessControlTargetStruct)?

        def initialize(
          @privilege : DatastoreAccessControlEntryPrivilegeEnum,
          @auth_mode : DatastoreAccessControlEntryAuthModeEnum,
          @subjects : Array(UInt64)?,
          @targets : Array(DatastoreAccessControlTargetStruct)?,
        )
        end
      end

      struct DatastoreAccessControlTargetStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property cluster : UInt32?

        @[TLV::Field(tag: 1)]
        property endpoint : UInt16?

        @[TLV::Field(tag: 2)]
        property device_type : UInt32?

        def initialize(
          @cluster : UInt32?,
          @endpoint : UInt16?,
          @device_type : UInt32?,
        )
        end
      end

      struct DatastoreAdministratorInformationEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property friendly_name : String

        @[TLV::Field(tag: 2)]
        property vendor_id : UInt16

        @[TLV::Field(tag: 3)]
        property icac : Bytes

        def initialize(
          @node_id : UInt64,
          @friendly_name : String,
          @vendor_id : UInt16,
          @icac : Bytes,
        )
        end
      end

      struct DatastoreBindingTargetStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 1, optional: true)]
        property node : UInt64?

        @[TLV::Field(tag: 2, optional: true)]
        property group : UInt16?

        @[TLV::Field(tag: 3, optional: true)]
        property endpoint : UInt16?

        @[TLV::Field(tag: 4, optional: true)]
        property cluster : UInt32?

        def initialize(
          @node : UInt64? = nil,
          @group : UInt16? = nil,
          @endpoint : UInt16? = nil,
          @cluster : UInt32? = nil,
        )
        end
      end

      struct DatastoreEndpointBindingEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 2)]
        property list_id : UInt16

        @[TLV::Field(tag: 3)]
        property binding : DatastoreBindingTargetStruct

        @[TLV::Field(tag: 4)]
        property status_entry : DatastoreStatusEntryStruct

        def initialize(
          @node_id : UInt64,
          @endpoint_id : UInt16,
          @list_id : UInt16,
          @binding : DatastoreBindingTargetStruct,
          @status_entry : DatastoreStatusEntryStruct,
        )
        end
      end

      struct DatastoreEndpointEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 1)]
        property node_id : UInt64

        @[TLV::Field(tag: 2)]
        property friendly_name : String

        def initialize(
          @endpoint_id : UInt16,
          @node_id : UInt64,
          @friendly_name : String,
        )
        end
      end

      struct DatastoreEndpointGroupIDEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 2)]
        property group_id : UInt16

        @[TLV::Field(tag: 3)]
        property status_entry : DatastoreStatusEntryStruct

        def initialize(
          @node_id : UInt64,
          @endpoint_id : UInt16,
          @group_id : UInt16,
          @status_entry : DatastoreStatusEntryStruct,
        )
        end
      end

      struct DatastoreGroupInformationEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_id : UInt64

        @[TLV::Field(tag: 1)]
        property friendly_name : String

        @[TLV::Field(tag: 2)]
        property group_key_set_id : UInt16?

        @[TLV::Field(tag: 3)]
        property group_cat : UInt16?

        @[TLV::Field(tag: 4)]
        property group_cat_version : UInt16?

        @[TLV::Field(tag: 5)]
        property group_permission : DatastoreAccessControlEntryPrivilegeEnum

        def initialize(
          @group_id : UInt64,
          @friendly_name : String,
          @group_key_set_id : UInt16?,
          @group_cat : UInt16?,
          @group_cat_version : UInt16?,
          @group_permission : DatastoreAccessControlEntryPrivilegeEnum,
        )
        end
      end

      struct DatastoreGroupKeySetStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_key_set_id : UInt16

        @[TLV::Field(tag: 1)]
        property group_key_security_policy : DatastoreGroupKeySecurityPolicyEnum

        @[TLV::Field(tag: 2)]
        property epoch_key0 : Bytes?

        @[TLV::Field(tag: 3)]
        property epoch_start_time0 : UInt64?

        @[TLV::Field(tag: 4)]
        property epoch_key1 : Bytes?

        @[TLV::Field(tag: 5)]
        property epoch_start_time1 : UInt64?

        @[TLV::Field(tag: 6)]
        property epoch_key2 : Bytes?

        @[TLV::Field(tag: 7)]
        property epoch_start_time2 : UInt64?

        def initialize(
          @group_key_set_id : UInt16,
          @group_key_security_policy : DatastoreGroupKeySecurityPolicyEnum,
          @epoch_key0 : Bytes?,
          @epoch_start_time0 : UInt64?,
          @epoch_key1 : Bytes?,
          @epoch_start_time1 : UInt64?,
          @epoch_key2 : Bytes?,
          @epoch_start_time2 : UInt64?,
        )
        end
      end

      struct DatastoreNodeInformationEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property friendly_name : String

        @[TLV::Field(tag: 2)]
        property commissioning_status_entry : DatastoreStatusEntryStruct

        def initialize(
          @node_id : UInt64,
          @friendly_name : String,
          @commissioning_status_entry : DatastoreStatusEntryStruct,
        )
        end
      end

      struct DatastoreNodeKeySetEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property group_key_set_id : UInt16

        @[TLV::Field(tag: 2)]
        property status_entry : DatastoreStatusEntryStruct

        def initialize(
          @node_id : UInt64,
          @group_key_set_id : UInt16,
          @status_entry : DatastoreStatusEntryStruct,
        )
        end
      end

      struct DatastoreStatusEntryStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property state : DatastoreStateEnum

        @[TLV::Field(tag: 1)]
        property update_timestamp : UInt32

        @[TLV::Field(tag: 2)]
        property failure_code : UInt8

        def initialize(
          @state : DatastoreStateEnum,
          @update_timestamp : UInt32,
          @failure_code : UInt8,
        )
        end
      end

      struct AddKeySetRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_key_set : DatastoreGroupKeySetStruct

        def initialize(
          @group_key_set : DatastoreGroupKeySetStruct,
        )
        end
      end

      struct UpdateKeySetRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_key_set : DatastoreGroupKeySetStruct

        def initialize(
          @group_key_set : DatastoreGroupKeySetStruct,
        )
        end
      end

      # Decode the policy as an integer before the strict enum request decoder.
      # The certification test sends an unrecognized policy and requires the
      # cluster's ConstraintError rather than a TLV InvalidCommand.
      struct KeySetPolicyWire
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        property group_key_security_policy : UInt8

        def initialize(@group_key_security_policy : UInt8)
        end
      end

      struct KeySetRequestPolicyWire
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property group_key_set : KeySetPolicyWire

        def initialize(@group_key_set : KeySetPolicyWire)
        end
      end

      struct RemoveKeySetRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_key_set_id : UInt16

        def initialize(
          @group_key_set_id : UInt16,
        )
        end
      end

      struct AddGroupRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1)]
        property friendly_name : String

        @[TLV::Field(tag: 2)]
        property group_key_set_id : UInt16?

        @[TLV::Field(tag: 3)]
        property group_cat : UInt16?

        @[TLV::Field(tag: 4)]
        property group_cat_version : UInt16?

        @[TLV::Field(tag: 5)]
        property group_permission : DatastoreAccessControlEntryPrivilegeEnum

        def initialize(
          @group_id : UInt16,
          @friendly_name : String,
          @group_key_set_id : UInt16?,
          @group_cat : UInt16?,
          @group_cat_version : UInt16?,
          @group_permission : DatastoreAccessControlEntryPrivilegeEnum,
        )
        end
      end

      struct UpdateGroupRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        @[TLV::Field(tag: 1)]
        property friendly_name : String?

        @[TLV::Field(tag: 2)]
        property group_key_set_id : UInt16?

        @[TLV::Field(tag: 3)]
        property group_cat : UInt16?

        @[TLV::Field(tag: 4)]
        property group_cat_version : UInt16?

        @[TLV::Field(tag: 5)]
        property group_permission : DatastoreAccessControlEntryPrivilegeEnum?

        def initialize(
          @group_id : UInt16,
          @friendly_name : String?,
          @group_key_set_id : UInt16?,
          @group_cat : UInt16?,
          @group_cat_version : UInt16?,
          @group_permission : DatastoreAccessControlEntryPrivilegeEnum?,
        )
        end
      end

      struct RemoveGroupRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property group_id : UInt16

        def initialize(
          @group_id : UInt16,
        )
        end
      end

      struct AddAdminRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property friendly_name : String

        @[TLV::Field(tag: 2)]
        property vendor_id : UInt16

        @[TLV::Field(tag: 3)]
        property icac : Bytes

        def initialize(
          @node_id : UInt64,
          @friendly_name : String,
          @vendor_id : UInt16,
          @icac : Bytes,
        )
        end
      end

      struct UpdateAdminRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1, optional: true)]
        property friendly_name : String?

        @[TLV::Field(tag: 2, optional: true)]
        property icac : Bytes?

        def initialize(
          @node_id : UInt64,
          @friendly_name : String? = nil,
          @icac : Bytes? = nil,
        )
        end
      end

      struct RemoveAdminRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        def initialize(
          @node_id : UInt64,
        )
        end
      end

      struct AddPendingNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property friendly_name : String

        def initialize(
          @node_id : UInt64,
          @friendly_name : String,
        )
        end
      end

      struct RefreshNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        def initialize(
          @node_id : UInt64,
        )
        end
      end

      struct UpdateNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property friendly_name : String

        def initialize(
          @node_id : UInt64,
          @friendly_name : String,
        )
        end
      end

      struct RemoveNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        def initialize(
          @node_id : UInt64,
        )
        end
      end

      struct UpdateEndpointForNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 1)]
        property node_id : UInt64

        @[TLV::Field(tag: 2)]
        property friendly_name : String

        def initialize(
          @endpoint_id : UInt16,
          @node_id : UInt64,
          @friendly_name : String,
        )
        end
      end

      struct AddGroupIDToEndpointForNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 2)]
        property group_id : UInt16

        def initialize(
          @node_id : UInt64,
          @endpoint_id : UInt16,
          @group_id : UInt16,
        )
        end
      end

      struct RemoveGroupIDFromEndpointForNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 2)]
        property group_id : UInt16

        def initialize(
          @node_id : UInt64,
          @endpoint_id : UInt16,
          @group_id : UInt16,
        )
        end
      end

      struct AddBindingToEndpointForNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 2)]
        property binding : DatastoreBindingTargetStruct

        def initialize(
          @node_id : UInt64,
          @endpoint_id : UInt16,
          @binding : DatastoreBindingTargetStruct,
        )
        end
      end

      struct RemoveBindingFromEndpointForNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property list_id : UInt16

        @[TLV::Field(tag: 1)]
        property endpoint_id : UInt16

        @[TLV::Field(tag: 2)]
        property node_id : UInt64

        def initialize(
          @list_id : UInt16,
          @endpoint_id : UInt16,
          @node_id : UInt64,
        )
        end
      end

      struct AddACLToNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property node_id : UInt64

        @[TLV::Field(tag: 1)]
        property acl_entry : DatastoreAccessControlEntryStruct

        def initialize(
          @node_id : UInt64,
          @acl_entry : DatastoreAccessControlEntryStruct,
        )
        end
      end

      struct RemoveACLFromNodeRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property list_id : UInt16

        @[TLV::Field(tag: 1)]
        property node_id : UInt64

        def initialize(
          @list_id : UInt16,
          @node_id : UInt64,
        )
        end
      end

      attribute 0x0000, :anchor_root_ca, Bytes, default: Bytes.empty, read_access: :administer, persist: true
      attribute 0x0001, :anchor_node_id, UInt64, default: 0_u64, read_access: :administer, persist: true
      attribute 0x0002, :anchor_vendor_id, UInt16, default: 0_u16, read_access: :administer, persist: true
      attribute 0x0003, :friendly_name, String, default: "", read_access: :administer, persist: true
      attribute 0x0004, :group_key_set_list, Array(DatastoreGroupKeySetStruct), default: [] of DatastoreGroupKeySetStruct, read_access: :administer, persist: true
      attribute 0x0005, :group_list, Array(DatastoreGroupInformationEntryStruct), default: [] of DatastoreGroupInformationEntryStruct, read_access: :administer, persist: true
      attribute 0x0006, :node_list, Array(DatastoreNodeInformationEntryStruct), default: [] of DatastoreNodeInformationEntryStruct, read_access: :administer, persist: true
      attribute 0x0007, :admin_list, Array(DatastoreAdministratorInformationEntryStruct), default: [] of DatastoreAdministratorInformationEntryStruct, read_access: :administer, persist: true
      attribute 0x0008, :status, DatastoreStatusEntryStruct, default: DatastoreStatusEntryStruct.new(DatastoreStateEnum::Pending, 0_u32, 0_u8), read_access: :administer, persist: true
      attribute 0x0009, :endpoint_group_id_list, Array(DatastoreEndpointGroupIDEntryStruct), default: [] of DatastoreEndpointGroupIDEntryStruct, read_access: :administer, persist: true
      attribute 0x000A, :endpoint_binding_list, Array(DatastoreEndpointBindingEntryStruct), default: [] of DatastoreEndpointBindingEntryStruct, read_access: :administer, persist: true
      attribute 0x000B, :node_key_set_list, Array(DatastoreNodeKeySetEntryStruct), default: [] of DatastoreNodeKeySetEntryStruct, read_access: :administer, persist: true
      attribute 0x000C, :node_acl_list, Array(DatastoreACLEntryStruct), default: [] of DatastoreACLEntryStruct, read_access: :administer, persist: true
      attribute 0x000D, :node_endpoint_list, Array(DatastoreEndpointEntryStruct), default: [] of DatastoreEndpointEntryStruct, read_access: :administer, persist: true

      command 0x00, :add_key_set, request: AddKeySetRequest, access: :administer
      command 0x01, :update_key_set, request: UpdateKeySetRequest, access: :administer
      command 0x02, :remove_key_set, request: RemoveKeySetRequest, access: :administer
      command 0x03, :add_group, request: AddGroupRequest, access: :administer
      command 0x04, :update_group, request: UpdateGroupRequest, access: :administer
      command 0x05, :remove_group, request: RemoveGroupRequest, access: :administer
      command 0x06, :add_admin, request: AddAdminRequest, access: :administer
      command 0x07, :update_admin, request: UpdateAdminRequest, access: :administer
      command 0x08, :remove_admin, request: RemoveAdminRequest, access: :administer
      command 0x09, :add_pending_node, request: AddPendingNodeRequest, access: :administer
      command 0x0A, :refresh_node, request: RefreshNodeRequest, access: :administer
      command 0x0B, :update_node, request: UpdateNodeRequest, access: :administer
      command 0x0C, :remove_node, request: RemoveNodeRequest, access: :administer
      command 0x0D, :update_endpoint_for_node, request: UpdateEndpointForNodeRequest, access: :administer
      command 0x0E, :add_group_id_to_endpoint_for_node, request: AddGroupIDToEndpointForNodeRequest, access: :administer
      command 0x0F, :remove_group_id_from_endpoint_for_node, request: RemoveGroupIDFromEndpointForNodeRequest, access: :administer
      command 0x10, :add_binding_to_endpoint_for_node, request: AddBindingToEndpointForNodeRequest, access: :administer
      command 0x11, :remove_binding_from_endpoint_for_node, request: RemoveBindingFromEndpointForNodeRequest, access: :administer
      command 0x12, :add_acl_to_node, request: AddACLToNodeRequest, access: :administer
      command 0x13, :remove_acl_from_node, request: RemoveACLFromNodeRequest, access: :administer
      MAX_KEY_SETS              =             254
      MAX_GROUPS                =             254
      MAX_NODES                 =            1024
      MAX_ADMINS                =              32
      MAX_NODE_ENTRIES          =            8192
      MAX_FRIENDLY_NAME_BYTES   =              32
      EPOCH_KEY_BYTES           =              16
      RESERVED_GROUP_ID         =           0_u16
      ADMINISTRATOR_CAT         =      0xFFFF_u16
      ANCHOR_CAT                =      0xFFFE_u16
      MATTER_EPOCH_UNIX_SECONDS = 946_684_800_i64

      enum AccessMode
        Inactive
        Active
        Frozen
      end

      # A Datastore instance belongs to one fabric. Once bound, cluster reads
      # and invokes require that fabric's CASE session.
      property joint_fabric_index : UInt8? = nil
      property access_mode : AccessMode = AccessMode::Inactive
      property allow_jcm_pase_group_list : Proc(Bool)? = nil

      def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : InteractionModel::Status | TLV::Any
        if @access_mode.active? && !@joint_fabric_index.nil? && fabric_index.nil? && !request_is_case_session? && attribute_id == ATTR_GROUP_LIST &&
           @allow_jcm_pase_group_list.try(&.call)
          return super
        end
        readable = @access_mode.active? || @access_mode.frozen?
        return InteractionModel::Status.unsupported_access unless readable && request_is_case_session? && accessing_fabric?(fabric_index)
        super
      end

      def invoke_command(command_id : UInt32, fields : TLV::Any? = nil, session_id : UInt64? = nil,
                         is_case_session : Bool = false, fabric_index : UInt8? = nil) : InteractionModel::Status | CommandResponse
        return InteractionModel::Status.unsupported_access unless @access_mode.active? && is_case_session && accessing_fabric?(fabric_index)
        if (command_id == CMD_ADD_KEY_SET || command_id == CMD_UPDATE_KEY_SET) && fields
          policy = KeySetRequestPolicyWire.from_tlv(fields).group_key_set.group_key_security_policy
          return InteractionModel::Status.constraint_error unless policy == DatastoreGroupKeySecurityPolicyEnum::TrustFirst.value
        end
        super
      rescue ex : TLV::DeserializationError | TypeCastError | ArgumentError
        Log.warn(exception: ex) { "Invalid Joint Fabric key set policy request" }
        InteractionModel::Status.invalid_command
      end

      private def accessing_fabric?(fabric_index : UInt8?) : Bool
        bound = @joint_fabric_index
        !bound.nil? && bound == fabric_index
      end

      # The former Anchor remains readable while its Datastore is copied to
      # the new Anchor, but no further mutation may race with that snapshot.
      def begin_anchor_transfer : Bool
        return false if transfer_busy?
        self.status = status_entry(DatastoreStateEnum::DeletePending)
        @access_mode = AccessMode::Frozen
        true
      end

      # Fabric-scoped Datastore contents must not survive removal of the
      # fabric that gave callers access to them.
      def clear_fabric_state : Nil
        self.anchor_root_ca = Bytes.empty
        self.anchor_node_id = 0_u64
        self.anchor_vendor_id = 0_u16
        self.friendly_name = ""
        self.group_key_set_list = [] of DatastoreGroupKeySetStruct
        self.group_list = [] of DatastoreGroupInformationEntryStruct
        self.node_list = [] of DatastoreNodeInformationEntryStruct
        self.admin_list = [] of DatastoreAdministratorInformationEntryStruct
        self.status = DatastoreStatusEntryStruct.new(DatastoreStateEnum::Pending, 0_u32, 0_u8)
        self.endpoint_group_id_list = [] of DatastoreEndpointGroupIDEntryStruct
        self.endpoint_binding_list = [] of DatastoreEndpointBindingEntryStruct
        self.node_key_set_list = [] of DatastoreNodeKeySetEntryStruct
        self.node_acl_list = [] of DatastoreACLEntryStruct
        self.node_endpoint_list = [] of DatastoreEndpointEntryStruct
        @joint_fabric_index = nil
        @access_mode = AccessMode::Inactive
      end

      def transfer_busy? : Bool
        return true unless @status.state == DatastoreStateEnum::Committed
        @node_list.any? { |entry| pending?(entry.commissioning_status_entry) } ||
          @node_key_set_list.any? { |entry| pending?(entry.status_entry) } ||
          @endpoint_group_id_list.any? { |entry| pending?(entry.status_entry) } ||
          @endpoint_binding_list.any? { |entry| pending?(entry.status_entry) } ||
          @node_acl_list.any? { |entry| pending?(entry.status_entry) }
      end

      private def transfer_pending? : Bool
        @status.state == DatastoreStateEnum::DeletePending
      end

      def configure_anchor(root_ca : Bytes, node_id : UInt64, vendor_id : UInt16, name : String,
                           ipk : Bytes? = nil) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error if root_ca.empty? || root_ca.size > 400 || !valid_name?(name)
        return InteractionModel::Status.constraint_error if ipk && ipk.size != Fabric::IPK_SIZE
        self.anchor_root_ca = root_ca
        self.anchor_node_id = node_id
        self.anchor_vendor_id = vendor_id
        self.friendly_name = name
        unless @group_key_set_list.any?(&.group_key_set_id.==(0_u16))
          self.group_key_set_list = [DatastoreGroupKeySetStruct.new(0_u16,
            DatastoreGroupKeySecurityPolicyEnum::TrustFirst, nil, nil, nil, nil, nil, nil)] + @group_key_set_list
        end
        if key = ipk
          entries = @group_key_set_list.dup
          index = entries.index!(&.group_key_set_id.==(0_u16))
          ipk_entry = entries[index]
          ipk_entry.epoch_key0 = key.dup
          ipk_entry.epoch_start_time0 = 0_u64
          entries[index] = ipk_entry
          self.group_key_set_list = entries
        end
        commit!
      end

      def add_key_set(request : AddKeySetRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        key_set = request.group_key_set
        return InteractionModel::Status.constraint_error unless valid_key_set?(key_set)
        return InteractionModel::Status.constraint_error if @group_key_set_list.any?(&.group_key_set_id.==(key_set.group_key_set_id))
        return InteractionModel::Status.resource_exhausted if @group_key_set_list.size >= MAX_KEY_SETS
        self.group_key_set_list = @group_key_set_list + [key_set]
        commit!
      end

      def update_key_set(request : UpdateKeySetRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        key_set = request.group_key_set
        return InteractionModel::Status.constraint_error if key_set.group_key_set_id == 0_u16
        return InteractionModel::Status.constraint_error unless valid_key_set?(key_set)
        index = @group_key_set_list.index { |entry| entry.group_key_set_id == key_set.group_key_set_id }
        return InteractionModel::Status.not_found unless index
        changed = @group_key_set_list[index] != key_set
        entries = @group_key_set_list.dup
        entries[index] = key_set
        self.group_key_set_list = entries
        if changed
          self.node_key_set_list = @node_key_set_list.map do |entry|
            if entry.group_key_set_id == key_set.group_key_set_id &&
               entry.status_entry.state != DatastoreStateEnum::DeletePending
              entry.status_entry = status_entry(DatastoreStateEnum::Pending)
            end
            entry
          end
        end
        commit!
      end

      def remove_key_set(request : RemoveKeySetRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        id = request.group_key_set_id
        in_use = @node_key_set_list.any? do |entry|
          entry.group_key_set_id == id && entry.status_entry.state != DatastoreStateEnum::DeletePending
        end
        return InteractionModel::Status.constraint_error if id == 0_u16 || id == UInt16::MAX || in_use
        return InteractionModel::Status.not_found unless @group_key_set_list.any?(&.group_key_set_id.==(id))
        self.group_key_set_list = @group_key_set_list.reject { |entry| entry.group_key_set_id == id }
        commit!
      end

      def add_group(request : AddGroupRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error if request.group_id == RESERVED_GROUP_ID || !valid_name?(request.friendly_name)
        return InteractionModel::Status.constraint_error if reserved_cat?(request.group_cat)
        return InteractionModel::Status.constraint_error unless valid_group_cat?(request.group_cat)
        return InteractionModel::Status.constraint_error if @group_list.any?(&.group_id.==(request.group_id.to_u64))
        return InteractionModel::Status.resource_exhausted if @group_list.size >= MAX_GROUPS
        return InteractionModel::Status.constraint_error unless valid_group_key_set_id?(request.group_key_set_id) && valid_group_cat_version?(request.group_cat_version)
        return InteractionModel::Status.constraint_error if request.group_cat.nil? && !request.group_cat_version.nil?
        return InteractionModel::Status.constraint_error if privileged_group_with_key_set?(request.group_permission, request.group_key_set_id)
        entry = DatastoreGroupInformationEntryStruct.new(request.group_id.to_u64, request.friendly_name,
          request.group_key_set_id, request.group_cat, request.group_cat_version, request.group_permission)
        self.group_list = @group_list + [entry]
        commit!
      end

      # The two CAT groups are created by the local Anchor bootstrap. Network
      # AddGroup/UpdateGroup/RemoveGroup cannot create or change them.
      def seed_reserved_cat_group(group_id : UInt16, name : String, cat : UInt16, version : UInt16) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless reserved_cat?(cat) && group_id != RESERVED_GROUP_ID &&
                                                                valid_name?(name) && valid_group_cat_version?(version)
        if existing = @group_list.find(&.group_cat.==(cat))
          return InteractionModel::Status.constraint_error unless existing.group_id == group_id.to_u64 &&
                                                                  existing.group_cat_version == version &&
                                                                  existing.friendly_name == name &&
                                                                  existing.group_key_set_id.nil? &&
                                                                  existing.group_permission == DatastoreAccessControlEntryPrivilegeEnum::Administer
          return InteractionModel::Status.success
        end
        return InteractionModel::Status.constraint_error if @group_list.any?(&.group_id.==(group_id.to_u64))
        return InteractionModel::Status.resource_exhausted if @group_list.size >= MAX_GROUPS
        entry = DatastoreGroupInformationEntryStruct.new(group_id.to_u64, name, nil, cat, version,
          DatastoreAccessControlEntryPrivilegeEnum::Administer)
        self.group_list = @group_list + [entry]
        commit!
      end

      def update_group(request : UpdateGroupRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        index = @group_list.index { |entry| entry.group_id == request.group_id.to_u64 }
        return InteractionModel::Status.not_found unless index
        return InteractionModel::Status.constraint_error if reserved_cat?(@group_list[index].group_cat) || reserved_cat?(request.group_cat)
        return InteractionModel::Status.constraint_error unless valid_group_cat?(request.group_cat)
        return InteractionModel::Status.constraint_error unless valid_group_key_set_id?(request.group_key_set_id) && valid_group_cat_version?(request.group_cat_version)
        return InteractionModel::Status.constraint_error if (name = request.friendly_name) && !valid_name?(name)
        entry = @group_list[index]
        effective_cat = request.group_cat || entry.group_cat
        effective_version = request.group_cat_version || entry.group_cat_version
        effective_permission = request.group_permission || entry.group_permission
        effective_key_set_id = request.group_key_set_id || entry.group_key_set_id
        return InteractionModel::Status.constraint_error if effective_cat.nil? && !effective_version.nil?
        return InteractionModel::Status.constraint_error if privileged_group_with_key_set?(effective_permission, effective_key_set_id)
        name_changed = !name.nil? && name != entry.friendly_name
        access_changed = (!request.group_cat.nil? && request.group_cat != entry.group_cat) ||
                         (!request.group_cat_version.nil? && request.group_cat_version != entry.group_cat_version) ||
                         (!request.group_permission.nil? && request.group_permission != entry.group_permission)
        key_changed = !request.group_key_set_id.nil? && request.group_key_set_id != entry.group_key_set_id
        entry.friendly_name = name if name
        entry.group_key_set_id = request.group_key_set_id if request.group_key_set_id
        entry.group_cat = request.group_cat if request.group_cat
        entry.group_cat_version = request.group_cat_version if request.group_cat_version
        if permission = request.group_permission
          entry.group_permission = permission
        end
        entries = @group_list.dup
        entries[index] = entry
        if access_changed
          updated_acls = prepare_group_acl_update(request.group_id, @group_list[index], entry)
          return InteractionModel::Status.constraint_error unless updated_acls
          if updated_acls == @node_acl_list
            self.group_list = entries
          else
            old_groups = @group_list
            old_acls = @node_acl_list
            @group_list = entries
            @node_acl_list = updated_acls
            increment_version_and_notify(ATTR_GROUP_LIST)
            @on_group_list_changed.try(&.call(old_groups, entries))
            increment_version_and_notify(ATTR_NODE_ACL_LIST)
            @on_node_acl_list_changed.try(&.call(old_acls, updated_acls))
          end
        else
          self.group_list = entries
        end
        mark_group_memberships_pending(request.group_id) if name_changed
        if key_changed
          mark_group_key_sets_pending(request.group_id, entry.group_key_set_id)
          memberships = @endpoint_group_id_list.select do |membership|
            membership.group_id == request.group_id && membership.status_entry.state != DatastoreStateEnum::DeletePending
          end
          node_ids = memberships.map(&.node_id)
          node_ids.uniq!
          node_ids.each do |node_id|
            mark_unused_key_sets_for_node(node_id)
          end
        end
        commit!
      end

      def remove_group(request : RemoveGroupRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        group = @group_list.find(&.group_id.==(request.group_id.to_u64))
        return InteractionModel::Status.not_found unless group
        return InteractionModel::Status.constraint_error if reserved_cat?(group.group_cat)
        in_use = @endpoint_group_id_list.any? do |entry|
          entry.group_id == request.group_id && entry.status_entry.state != DatastoreStateEnum::DeletePending
        end
        return InteractionModel::Status.constraint_error if in_use
        affected_nodes = @endpoint_group_id_list.select { |entry| entry.group_id == request.group_id }.map(&.node_id)
        affected_nodes.uniq!
        self.group_list = @group_list.reject { |entry| entry.group_id == request.group_id.to_u64 }
        self.endpoint_group_id_list = @endpoint_group_id_list.map do |entry|
          if entry.group_id == request.group_id
            entry.status_entry = status_entry(DatastoreStateEnum::DeletePending)
          end
          entry
        end
        affected_nodes.each { |node_id| mark_unused_key_sets_for_node(node_id) }
        commit!
      end

      def add_admin(request : AddAdminRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless DataType::NodeId.valid_joint_fabric?(request.node_id)
        return InteractionModel::Status.constraint_error unless valid_name?(request.friendly_name) && request.icac.size <= 400
        return InteractionModel::Status.constraint_error if @admin_list.any?(&.node_id.==(request.node_id))
        return InteractionModel::Status.resource_exhausted if @admin_list.size >= MAX_ADMINS
        entry = DatastoreAdministratorInformationEntryStruct.new(request.node_id, request.friendly_name,
          request.vendor_id, request.icac)
        self.admin_list = @admin_list + [entry]
        commit!
      end

      def update_admin(request : UpdateAdminRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        index = @admin_list.index { |entry| entry.node_id == request.node_id }
        return InteractionModel::Status.not_found unless index
        return InteractionModel::Status.constraint_error if (name = request.friendly_name) && !valid_name?(name)
        return InteractionModel::Status.constraint_error if (icac = request.icac) && icac.size > 400
        entry = @admin_list[index]
        entry.friendly_name = name if name
        entry.icac = icac if icac
        entries = @admin_list.dup
        entries[index] = entry
        self.admin_list = entries
        commit!
      end

      def remove_admin(request : RemoveAdminRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error if request.node_id == @anchor_node_id
        return InteractionModel::Status.not_found unless @admin_list.any?(&.node_id.==(request.node_id))
        self.admin_list = @admin_list.reject { |entry| entry.node_id == request.node_id }
        commit!
      end

      def add_pending_node(request : AddPendingNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless DataType::NodeId.valid_joint_fabric?(request.node_id)
        return InteractionModel::Status.constraint_error unless valid_name?(request.friendly_name)
        return InteractionModel::Status.constraint_error if @node_list.any?(&.node_id.==(request.node_id))
        return InteractionModel::Status.constraint_error if request.node_id == @anchor_node_id ||
                                                            @admin_list.any?(&.node_id.==(request.node_id))
        return InteractionModel::Status.resource_exhausted if @node_list.size >= MAX_NODES
        entry = DatastoreNodeInformationEntryStruct.new(request.node_id, request.friendly_name, status_entry(DatastoreStateEnum::Pending))
        self.node_list = @node_list + [entry]
        commit!
      end

      def refresh_node(request : RefreshNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        index = @node_list.index { |entry| entry.node_id == request.node_id }
        return InteractionModel::Status.not_found unless index
        entry = @node_list[index]
        entry.commissioning_status_entry = status_entry(DatastoreStateEnum::Pending)
        entries = @node_list.dup
        entries[index] = entry
        self.node_list = entries
        self.node_key_set_list = @node_key_set_list.reject { |item| item.node_id == request.node_id && terminal_failure?(item.status_entry) }.map do |item|
          item.status_entry = retry_failed(item.status_entry) if item.node_id == request.node_id
          item
        end
        self.endpoint_group_id_list = @endpoint_group_id_list.reject { |item| item.node_id == request.node_id && terminal_failure?(item.status_entry) }.map do |item|
          item.status_entry = retry_failed(item.status_entry) if item.node_id == request.node_id
          item
        end
        self.endpoint_binding_list = @endpoint_binding_list.reject { |item| item.node_id == request.node_id && terminal_failure?(item.status_entry) }.map do |item|
          item.status_entry = retry_failed(item.status_entry) if item.node_id == request.node_id
          item
        end
        self.node_acl_list = @node_acl_list.reject { |item| item.node_id == request.node_id && terminal_failure?(item.status_entry) }.map do |item|
          item.status_entry = retry_failed(item.status_entry) if item.node_id == request.node_id
          item
        end
        commit!
      end

      def update_node(request : UpdateNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless valid_name?(request.friendly_name)
        index = @node_list.index { |entry| entry.node_id == request.node_id }
        return InteractionModel::Status.not_found unless index
        entry = @node_list[index]
        entry.friendly_name = request.friendly_name
        entries = @node_list.dup
        entries[index] = entry
        self.node_list = entries
        commit!
      end

      def remove_node(request : RemoveNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless @node_list.any?(&.node_id.==(request.node_id))
        self.node_list = @node_list.reject { |entry| entry.node_id == request.node_id }
        self.node_endpoint_list = @node_endpoint_list.reject { |entry| entry.node_id == request.node_id }
        self.endpoint_group_id_list = @endpoint_group_id_list.reject { |entry| entry.node_id == request.node_id }
        self.endpoint_binding_list = @endpoint_binding_list.reject { |entry| entry.node_id == request.node_id }
        self.node_key_set_list = @node_key_set_list.reject { |entry| entry.node_id == request.node_id }
        self.node_acl_list = @node_acl_list.reject { |entry| entry.node_id == request.node_id }
        commit!
      end

      def update_endpoint_for_node(request : UpdateEndpointForNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless node_exists?(request.node_id) && valid_name?(request.friendly_name)
        return InteractionModel::Status.constraint_error unless endpoint_exists?(request.node_id, request.endpoint_id)

        entries = @node_endpoint_list.reject { |entry| entry.node_id == request.node_id && entry.endpoint_id == request.endpoint_id }
        entries << DatastoreEndpointEntryStruct.new(request.endpoint_id, request.node_id, request.friendly_name)
        self.node_endpoint_list = entries
        commit!
      end

      # RefreshNode discovers endpoints on the target device and records them
      # here before UpdateEndpointForNode may change their friendly names.
      def record_endpoint(node_id : UInt64, endpoint_id : UInt16, name : String) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless node_exists?(node_id) && valid_name?(name)
        entries = @node_endpoint_list.reject { |entry| entry.node_id == node_id && entry.endpoint_id == endpoint_id }
        return InteractionModel::Status.resource_exhausted if entries.size >= MAX_NODE_ENTRIES
        entries << DatastoreEndpointEntryStruct.new(endpoint_id, node_id, name)
        self.node_endpoint_list = entries
        commit!
      end

      # RefreshNode's Descriptor snapshot. New endpoint labels start empty;
      # labels already assigned by an Administrator are preserved.
      def reconcile_node_endpoints(node_id : UInt64, endpoint_ids : Array(UInt16)) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless node_exists?(node_id)
        ids = endpoint_ids.uniq
        return InteractionModel::Status.constraint_error if ids.includes?(0_u16)
        entries = @node_endpoint_list.reject { |entry| entry.node_id == node_id && !ids.includes?(entry.endpoint_id) }
        ids.each do |endpoint_id|
          unless entries.any? { |entry| entry.node_id == node_id && entry.endpoint_id == endpoint_id }
            return InteractionModel::Status.resource_exhausted if entries.size >= MAX_NODE_ENTRIES
            entries << DatastoreEndpointEntryStruct.new(endpoint_id, node_id, "")
          end
        end
        self.node_endpoint_list = entries
        self.endpoint_group_id_list = @endpoint_group_id_list.reject do |entry|
          entry.node_id == node_id && !ids.includes?(entry.endpoint_id)
        end
        self.endpoint_binding_list = @endpoint_binding_list.reject do |entry|
          entry.node_id == node_id && !ids.includes?(entry.endpoint_id)
        end
        commit!
      end

      def reconcile_node_groups(node_id : UInt64, endpoint_id : UInt16, group_ids : Array(UInt16)) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless endpoint_exists?(node_id, endpoint_id)
        return InteractionModel::Status.constraint_error if group_ids.includes?(0_u16)
        ids = group_ids.uniq
        entries = @endpoint_group_id_list.reject do |entry|
          entry.node_id == node_id && entry.endpoint_id == endpoint_id &&
            entry.status_entry.state == DatastoreStateEnum::Committed && !ids.includes?(entry.group_id)
        end
        ids.each do |group_id|
          unless entries.any? { |entry| entry.node_id == node_id && entry.endpoint_id == endpoint_id && entry.group_id == group_id }
            return InteractionModel::Status.resource_exhausted if entries.size >= MAX_NODE_ENTRIES
            entries << DatastoreEndpointGroupIDEntryStruct.new(node_id, endpoint_id, group_id, status_entry)
          end
        end
        self.endpoint_group_id_list = entries
        commit!
      end

      def reconcile_node_bindings(node_id : UInt64, endpoint_id : UInt16,
                                  bindings : Array(DatastoreBindingTargetStruct)) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless endpoint_exists?(node_id, endpoint_id)
        entries = @endpoint_binding_list.reject do |entry|
          entry.node_id == node_id && entry.endpoint_id == endpoint_id &&
            entry.status_entry.state == DatastoreStateEnum::Committed && !bindings.includes?(entry.binding)
        end
        bindings.uniq.each do |binding|
          unless entries.any? { |entry| entry.node_id == node_id && entry.endpoint_id == endpoint_id && entry.binding == binding }
            return InteractionModel::Status.resource_exhausted if entries.size >= MAX_NODE_ENTRIES
            id = next_list_id(@node_acl_list.map(&.list_id) + entries.map(&.list_id))
            return InteractionModel::Status.resource_exhausted unless id
            entries << DatastoreEndpointBindingEntryStruct.new(node_id, endpoint_id, id, binding, status_entry)
          end
        end
        self.endpoint_binding_list = entries
        commit!
      end

      def reconcile_node_acls(node_id : UInt64,
                              acls : Array(DatastoreAccessControlEntryStruct)) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless node_exists?(node_id)
        entries = @node_acl_list.reject do |entry|
          entry.node_id == node_id && entry.status_entry.state == DatastoreStateEnum::Committed &&
            !acls.includes?(entry.acl_entry)
        end
        acls.uniq.each do |acl|
          unless entries.any? { |entry| entry.node_id == node_id && entry.acl_entry == acl }
            return InteractionModel::Status.resource_exhausted if entries.size >= MAX_NODE_ENTRIES
            id = next_list_id(@endpoint_binding_list.map(&.list_id) + entries.map(&.list_id))
            return InteractionModel::Status.resource_exhausted unless id
            entry = DatastoreACLEntryStruct.new(node_id, id, acl, status_entry)
            entry.associated_group_id = infer_acl_group(acl)
            entries << entry
          end
        end
        self.node_acl_list = entries
        commit!
      end

      def reconcile_node_key_sets(node_id : UInt64, key_set_ids : Array(UInt16)) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless node_exists?(node_id)
        ids = key_set_ids.uniq
        entries = @node_key_set_list.reject do |entry|
          entry.node_id == node_id && entry.status_entry.state == DatastoreStateEnum::Committed &&
            !ids.includes?(entry.group_key_set_id)
        end
        ids.each do |id|
          unless entries.any? { |entry| entry.node_id == node_id && entry.group_key_set_id == id }
            return InteractionModel::Status.resource_exhausted if entries.size >= MAX_NODE_ENTRIES
            entries << DatastoreNodeKeySetEntryStruct.new(node_id, id, status_entry)
          end
        end
        self.node_key_set_list = entries
        commit!
      end

      def add_group_id_to_endpoint_for_node(request : AddGroupIDToEndpointForNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless endpoint_exists?(request.node_id, request.endpoint_id) &&
                                                                @group_list.any?(&.group_id.==(request.group_id.to_u64))
        return InteractionModel::Status.constraint_error if @endpoint_group_id_list.any? { |e| e.node_id == request.node_id && e.endpoint_id == request.endpoint_id && e.group_id == request.group_id }
        return InteractionModel::Status.resource_exhausted if @endpoint_group_id_list.size >= MAX_NODE_ENTRIES
        entry = DatastoreEndpointGroupIDEntryStruct.new(request.node_id, request.endpoint_id, request.group_id, status_entry(DatastoreStateEnum::Pending))
        self.endpoint_group_id_list = @endpoint_group_id_list + [entry]
        if (group = @group_list.find { |item| item.group_id == request.group_id.to_u64 }) && (key_id = group.group_key_set_id)
          unless @node_key_set_list.any? { |item| item.node_id == request.node_id && item.group_key_set_id == key_id }
            key_entry = DatastoreNodeKeySetEntryStruct.new(request.node_id, key_id, status_entry(DatastoreStateEnum::Pending))
            self.node_key_set_list = @node_key_set_list + [key_entry]
          end
        end
        commit!
      end

      def remove_group_id_from_endpoint_for_node(request : RemoveGroupIDFromEndpointForNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless @endpoint_group_id_list.any? { |e| e.node_id == request.node_id && e.endpoint_id == request.endpoint_id && e.group_id == request.group_id }
        entries = @endpoint_group_id_list.dup
        index = entries.index { |e| e.node_id == request.node_id && e.endpoint_id == request.endpoint_id && e.group_id == request.group_id }.as(Int32)
        entry = entries[index]
        entry.status_entry = status_entry(DatastoreStateEnum::DeletePending)
        entries[index] = entry
        self.endpoint_group_id_list = entries
        mark_unused_key_sets_for_node(request.node_id)
        commit!
      end

      def add_binding_to_endpoint_for_node(request : AddBindingToEndpointForNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless endpoint_exists?(request.node_id, request.endpoint_id)
        binding = request.binding
        return InteractionModel::Status.constraint_error if binding.node.nil? == binding.group.nil?
        return InteractionModel::Status.constraint_error if binding.group == 0_u16 || (binding.group && binding.endpoint)
        return InteractionModel::Status.resource_exhausted if @endpoint_binding_list.size >= MAX_NODE_ENTRIES
        id = next_list_id(all_list_ids)
        return InteractionModel::Status.resource_exhausted unless id
        entry = DatastoreEndpointBindingEntryStruct.new(request.node_id, request.endpoint_id, id, binding, status_entry(DatastoreStateEnum::Pending))
        self.endpoint_binding_list = @endpoint_binding_list + [entry]
        commit!
      end

      def remove_binding_from_endpoint_for_node(request : RemoveBindingFromEndpointForNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless @endpoint_binding_list.any? { |e| e.node_id == request.node_id && e.endpoint_id == request.endpoint_id && e.list_id == request.list_id }
        entries = @endpoint_binding_list.dup
        index = entries.index { |e| e.node_id == request.node_id && e.endpoint_id == request.endpoint_id && e.list_id == request.list_id }.as(Int32)
        entry = entries[index]
        entry.status_entry = status_entry(DatastoreStateEnum::DeletePending)
        entries[index] = entry
        self.endpoint_binding_list = entries
        commit!
      end

      def add_acl_to_node(request : AddACLToNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.constraint_error unless node_exists?(request.node_id)
        acl = request.acl_entry
        return InteractionModel::Status.constraint_error if (acl.subjects.try(&.size) || 0) > AccessControl::DEFAULT_SUBJECTS_PER_ENTRY ||
                                                            (acl.targets.try(&.size) || 0) > AccessControl::DEFAULT_TARGETS_PER_ENTRY
        return InteractionModel::Status.resource_exhausted if @node_acl_list.size >= MAX_NODE_ENTRIES
        id = next_list_id(all_list_ids)
        return InteractionModel::Status.resource_exhausted unless id
        entry = DatastoreACLEntryStruct.new(request.node_id, id, request.acl_entry, status_entry(DatastoreStateEnum::Pending))
        entry.associated_group_id = infer_acl_group(request.acl_entry)
        self.node_acl_list = @node_acl_list + [entry]
        commit!
      end

      # Bind an existing ACL to a group when its one CAT subject is known to
      # represent that group. This local metadata is never exposed on the wire.
      def associate_acl_with_group(node_id : UInt64, list_id : UInt16, group_id : UInt16) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        group = @group_list.find(&.group_id.==(group_id.to_u64))
        index = @node_acl_list.index { |entry| entry.node_id == node_id && entry.list_id == list_id }
        return InteractionModel::Status.not_found unless group && index
        entry = @node_acl_list[index]
        return InteractionModel::Status.constraint_error unless acl_matches_group?(entry.acl_entry, group)
        return InteractionModel::Status.constraint_error if shared_group_cat?(group_id, group.group_cat)
        return InteractionModel::Status.constraint_error if (other = entry.associated_group_id) && other != group_id
        return InteractionModel::Status.success if entry.associated_group_id == group_id
        entry.associated_group_id = group_id
        entries = @node_acl_list.dup
        entries[index] = entry
        self.node_acl_list = entries
        commit!
      end

      def remove_acl_from_node(request : RemoveACLFromNodeRequest) : InteractionModel::Status
        return InteractionModel::Status.busy if transfer_pending?
        return InteractionModel::Status.not_found unless @node_acl_list.any? { |e| e.node_id == request.node_id && e.list_id == request.list_id }
        entries = @node_acl_list.dup
        index = entries.index { |e| e.node_id == request.node_id && e.list_id == request.list_id }.as(Int32)
        entry = entries[index]
        entry.status_entry = status_entry(DatastoreStateEnum::DeletePending)
        entries[index] = entry
        self.node_acl_list = entries
        commit!
      end

      # Called after the corresponding device operation completes. A pending
      # deletion remains visible until the device confirms it, so a failed
      # write can be retried by RefreshNode.
      def complete_node(node_id : UInt64, failure_code : UInt8 = 0_u8) : Bool
        entries = @node_list.dup
        index = entries.index { |e| e.node_id == node_id }
        return false unless index
        entry = entries[index]
        entry.commissioning_status_entry = synced_status(failure_code)
        entries[index] = entry
        self.node_list = entries
        commit!
        true
      end

      def complete_group_membership(node_id : UInt64, endpoint_id : UInt16, group_id : UInt16, failure_code : UInt8 = 0_u8) : Bool
        entries = @endpoint_group_id_list.dup
        index = entries.index { |e| e.node_id == node_id && e.endpoint_id == endpoint_id && e.group_id == group_id }
        return false unless index
        entry = entries[index]
        if entry.status_entry.state == DatastoreStateEnum::DeletePending && failure_code == 0_u8
          entries.delete_at(index)
        else
          entry.status_entry = synced_status(failure_code, entry.status_entry.state)
          entries[index] = entry
        end
        self.endpoint_group_id_list = entries
        commit!
        true
      end

      def complete_binding(node_id : UInt64, endpoint_id : UInt16, list_id : UInt16, failure_code : UInt8 = 0_u8) : Bool
        entries = @endpoint_binding_list.dup
        index = entries.index { |e| e.node_id == node_id && e.endpoint_id == endpoint_id && e.list_id == list_id }
        return false unless index
        entry = entries[index]
        if entry.status_entry.state == DatastoreStateEnum::DeletePending && failure_code == 0_u8
          entries.delete_at(index)
        else
          entry.status_entry = synced_status(failure_code, entry.status_entry.state)
          entries[index] = entry
        end
        self.endpoint_binding_list = entries
        commit!
        true
      end

      def complete_acl(node_id : UInt64, list_id : UInt16, failure_code : UInt8 = 0_u8) : Bool
        entries = @node_acl_list.dup
        index = entries.index { |e| e.node_id == node_id && e.list_id == list_id }
        return false unless index
        entry = entries[index]
        if entry.status_entry.state == DatastoreStateEnum::DeletePending && failure_code == 0_u8
          entries.delete_at(index)
        else
          entry.status_entry = synced_status(failure_code, entry.status_entry.state)
          entry.prior_acl_entry = nil if failure_code == 0_u8
          entries[index] = entry
        end
        self.node_acl_list = entries
        commit!
        true
      end

      def complete_node_key_set(node_id : UInt64, key_set_id : UInt16, failure_code : UInt8 = 0_u8) : Bool
        entries = @node_key_set_list.dup
        index = entries.index { |e| e.node_id == node_id && e.group_key_set_id == key_set_id }
        return false unless index
        entry = entries[index]
        if entry.status_entry.state == DatastoreStateEnum::DeletePending && failure_code == 0_u8
          entries.delete_at(index)
        else
          entry.status_entry = synced_status(failure_code, entry.status_entry.state)
          entries[index] = entry
        end
        self.node_key_set_list = entries
        commit!
        true
      end

      private def synced_status(failure_code : UInt8, previous_state : DatastoreStateEnum = DatastoreStateEnum::Pending) : DatastoreStatusEntryStruct
        state = if failure_code == 0_u8
                  DatastoreStateEnum::Committed
                elsif previous_state == DatastoreStateEnum::DeletePending
                  DatastoreStateEnum::DeletePending
                else
                  DatastoreStateEnum::CommitFailed
                end
        DatastoreStatusEntryStruct.new(state, matter_timestamp, failure_code)
      end

      private def retry_failed(entry : DatastoreStatusEntryStruct) : DatastoreStatusEntryStruct
        case entry.state
        when DatastoreStateEnum::CommitFailed
          status_entry(DatastoreStateEnum::Pending)
        when DatastoreStateEnum::DeletePending
          entry.failure_code == 0_u8 ? entry : status_entry(DatastoreStateEnum::DeletePending)
        else
          entry
        end
      end

      # Only codes explicitly identified as unrecoverable by Core 11.24.7.11
      # are pruned. Unknown failures keep their intent for a later refresh.
      private def terminal_failure?(entry : DatastoreStatusEntryStruct) : Bool
        return false unless entry.state == DatastoreStateEnum::CommitFailed ||
                            (entry.state == DatastoreStateEnum::DeletePending && entry.failure_code != 0_u8)
        entry.failure_code == InteractionModel::StatusCode::ResourceExhausted.value ||
          entry.failure_code == InteractionModel::StatusCode::ConstraintError.value
      end

      private def valid_name?(name : String) : Bool
        name.bytesize <= MAX_FRIENDLY_NAME_BYTES
      end

      private def valid_key_set?(entry : DatastoreGroupKeySetStruct) : Bool
        return false if entry.group_key_set_id == 0_u16 || entry.group_key_set_id == UInt16::MAX
        return false unless entry.group_key_security_policy == DatastoreGroupKeySecurityPolicyEnum::TrustFirst
        keys = {entry.epoch_key0, entry.epoch_key1, entry.epoch_key2}
        times = {entry.epoch_start_time0, entry.epoch_start_time1, entry.epoch_start_time2}
        return false unless keys.zip(times).all? { |key, time| key.nil? == time.nil? && (key.nil? || key.size == EPOCH_KEY_BYTES) }
        present_times = times.to_a.compact
        present_times.each_with_index.all? { |time, index| index == 0 || present_times[index - 1] < time }
      end

      private def valid_group_key_set_id?(id : UInt16?) : Bool
        id.nil? || (id > 0_u16 && id < UInt16::MAX)
      end

      private def reserved_cat?(cat : UInt16?) : Bool
        cat == ADMINISTRATOR_CAT || cat == ANCHOR_CAT
      end

      private def valid_group_cat?(cat : UInt16?) : Bool
        cat.nil? || (cat > 0_u16 && cat < UInt16::MAX)
      end

      private def valid_group_cat_version?(version : UInt16?) : Bool
        version.nil? || (version >= 1_u16 && version < UInt16::MAX)
      end

      private def privileged_group_with_key_set?(permission : DatastoreAccessControlEntryPrivilegeEnum, key_set_id : UInt16?) : Bool
        !key_set_id.nil? && (permission == DatastoreAccessControlEntryPrivilegeEnum::Manage ||
          permission == DatastoreAccessControlEntryPrivilegeEnum::Administer)
      end

      private def node_exists?(id : UInt64) : Bool
        @node_list.any?(&.node_id.==(id))
      end

      private def endpoint_exists?(node_id : UInt64, endpoint_id : UInt16) : Bool
        @node_endpoint_list.any? { |e| e.node_id == node_id && e.endpoint_id == endpoint_id }
      end

      private def next_list_id(ids : Array(UInt16)) : UInt16?
        candidate = 0_u16
        loop do
          return candidate unless ids.includes?(candidate)
          return if candidate == UInt16::MAX
          candidate += 1_u16
        end
      end

      private def all_list_ids : Array(UInt16)
        @endpoint_binding_list.map(&.list_id) + @node_acl_list.map(&.list_id)
      end

      private def mark_group_memberships_pending(group_id : UInt16) : Nil
        self.endpoint_group_id_list = @endpoint_group_id_list.map do |entry|
          if entry.group_id == group_id
            entry.status_entry = status_entry(DatastoreStateEnum::Pending)
          end
          entry
        end
      end

      private def infer_acl_group(acl : DatastoreAccessControlEntryStruct) : UInt16?
        cat = sole_acl_cat(acl)
        return unless cat
        groups = @group_list.select(&.group_cat.==(cat.identity_value))
        return unless groups.size == 1
        group = groups.first
        return unless (version = group.group_cat_version) && version >= cat.version && group.group_id <= UInt16::MAX
        group.group_id.to_u16
      end

      private def sole_acl_cat(acl : DatastoreAccessControlEntryStruct) : DataType::CaseAuthenticatedTag?
        return unless acl.auth_mode == DatastoreAccessControlEntryAuthModeEnum::CASE
        subjects = acl.subjects
        return unless subjects && subjects.size == 1
        node = DataType::NodeId.new(subjects.first)
        return unless node.case_authenticated_tag?
        node.extract_as_case_authenticated_tag
      rescue ArgumentError
        nil
      end

      private def acl_matches_group?(acl : DatastoreAccessControlEntryStruct,
                                     group : DatastoreGroupInformationEntryStruct) : Bool
        cat = sole_acl_cat(acl)
        group_cat = group.group_cat
        version = group.group_cat_version
        !cat.nil? && !group_cat.nil? && !version.nil? &&
          cat.identity_value == group_cat && cat.version <= version
      end

      private def shared_group_cat?(group_id : UInt16, cat : UInt16?) : Bool
        !cat.nil? && @group_list.any? { |group| group.group_id != group_id.to_u64 && group.group_cat == cat }
      end

      private def acl_references_cat?(acl : DatastoreAccessControlEntryStruct, cat : UInt16?) : Bool
        return false unless cat && acl.auth_mode == DatastoreAccessControlEntryAuthModeEnum::CASE
        subjects = acl.subjects
        return false unless subjects
        subjects.any? do |subject|
          node = DataType::NodeId.new(subject)
          node.case_authenticated_tag? && ((subject >> 16) & 0xFFFF_u64).to_u16 == cat
        end
      end

      private def prepare_group_acl_update(group_id : UInt16,
                                           previous_group : DatastoreGroupInformationEntryStruct,
                                           updated_group : DatastoreGroupInformationEntryStruct) : Array(DatastoreACLEntryStruct)?
        old_cat = previous_group.group_cat
        new_cat = updated_group.group_cat
        new_version = updated_group.group_cat_version
        affected = @node_acl_list.any? do |entry|
          entry.status_entry.state != DatastoreStateEnum::DeletePending &&
            (entry.associated_group_id == group_id || acl_references_cat?(entry.acl_entry, old_cat))
        end
        if affected && (shared_group_cat?(group_id, old_cat) || shared_group_cat?(group_id, new_cat))
          return
        end

        result = [] of DatastoreACLEntryStruct
        @node_acl_list.each do |entry|
          if entry.status_entry.state == DatastoreStateEnum::DeletePending
            result << entry
            next
          end
          association = entry.associated_group_id || infer_acl_group(entry.acl_entry)
          if association == group_id
            return unless acl_matches_group?(entry.acl_entry, previous_group)
            return unless new_cat && new_version
            prior = entry.prior_acl_entry || entry.acl_entry
            acl = entry.acl_entry
            acl.subjects = [DataType::NodeId.from_case_authenticated_tag(
              DataType::CaseAuthenticatedTag.create(new_cat, new_version)).id]
            acl.privilege = updated_group.group_permission
            entry.prior_acl_entry = prior
            entry.associated_group_id = group_id
            entry.acl_entry = acl
            entry.status_entry = status_entry(DatastoreStateEnum::Pending)
          elsif acl_references_cat?(entry.acl_entry, old_cat)
            # The wire ACL has no GroupID. An ambiguous or multi-subject ACL
            # cannot be safely attributed to this Group.
            return
          end
          result << entry
        end
        result
      end

      private def mark_group_key_sets_pending(group_id : UInt16, key_set_id : UInt16?) : Nil
        return unless key_set_id
        memberships = @endpoint_group_id_list.select do |entry|
          entry.group_id == group_id && entry.status_entry.state != DatastoreStateEnum::DeletePending
        end
        node_ids = memberships.map(&.node_id)
        node_ids.uniq!
        entries = @node_key_set_list.dup
        node_ids.each do |node_id|
          index = entries.index { |entry| entry.node_id == node_id && entry.group_key_set_id == key_set_id }
          if index
            entry = entries[index]
            entry.status_entry = status_entry(DatastoreStateEnum::Pending)
            entries[index] = entry
          else
            entries << DatastoreNodeKeySetEntryStruct.new(node_id, key_set_id, status_entry(DatastoreStateEnum::Pending))
          end
        end
        self.node_key_set_list = entries
      end

      private def mark_unused_key_sets_for_node(node_id : UInt64) : Nil
        entries = @node_key_set_list.map do |entry|
          if entry.node_id == node_id && entry.group_key_set_id != 0_u16
            needed = @endpoint_group_id_list.any? do |membership|
              membership.node_id == node_id && membership.status_entry.state != DatastoreStateEnum::DeletePending &&
                @group_list.any? { |group| group.group_id == membership.group_id.to_u64 && group.group_key_set_id == entry.group_key_set_id }
            end
            entry.status_entry = status_entry(DatastoreStateEnum::DeletePending) unless needed
          end
          entry
        end
        self.node_key_set_list = entries
      end

      private def status_entry(state : DatastoreStateEnum = DatastoreStateEnum::Committed) : DatastoreStatusEntryStruct
        DatastoreStatusEntryStruct.new(state, matter_timestamp, 0_u8)
      end

      private def matter_timestamp : UInt32
        (Time.utc.to_unix - MATTER_EPOCH_UNIX_SECONDS).to_u32
      end

      private def commit! : InteractionModel::Status
        pending = @node_list.any? { |e| e.commissioning_status_entry.state == DatastoreStateEnum::Pending } ||
                  @endpoint_group_id_list.any? { |e| pending?(e.status_entry) } ||
                  @endpoint_binding_list.any? { |e| pending?(e.status_entry) } ||
                  @node_key_set_list.any? { |e| pending?(e.status_entry) } ||
                  @node_acl_list.any? { |e| pending?(e.status_entry) }
        self.status = status_entry(pending ? DatastoreStateEnum::Pending : DatastoreStateEnum::Committed)
        InteractionModel::Status.success
      end

      private def pending?(entry : DatastoreStatusEntryStruct) : Bool
        entry.state == DatastoreStateEnum::Pending || entry.state == DatastoreStateEnum::DeletePending
      end
    end
  end
end
