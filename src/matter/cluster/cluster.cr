require "tlv"
require "socket"
require "../interaction_model/status_code"
require "../storage/record"
require "../interaction_model/paths"
require "../datatype/*"
require "../interaction_model/access"
require "./dsl"

module Matter
  module Cluster
    # Attribute metadata
    struct AttributeMetadata
      property id : DataType::AttributeId
      property name : String
      property type : Symbol # :bool, :uint8, :uint16, :uint32, :int8, :string, :array, etc.
      property? writable : Bool
      property? optional : Bool
      property? fixed : Bool
      property default : TLV::Any?
      property min : Int64?
      property max : Int64?
      # Privilege required to read the attribute
      property access : InteractionModel::EntryPrivilege
      # Quality flags; timed writes are enforced by the unicast IM handler.
      property? timed : Bool
      property? fabric_scoped : Bool
      property? scene : Bool
      property? omit_changes : Bool

      def initialize(
        @id : DataType::AttributeId,
        @name : String,
        @type : Symbol,
        @writable : Bool = false,
        @optional : Bool = false,
        @fixed : Bool = false,
        @default : TLV::Any? = nil,
        @min : Int64? = nil,
        @max : Int64? = nil,
        @access : InteractionModel::EntryPrivilege = InteractionModel::EntryPrivilege::View,
        @write_access : InteractionModel::EntryPrivilege? = nil,
        @timed : Bool = false,
        @fabric_scoped : Bool = false,
        @scene : Bool = false,
        @omit_changes : Bool = false,
      )
      end

      # Privilege required to write the attribute; the read privilege unless
      # a different one was declared.
      def write_access : InteractionModel::EntryPrivilege
        @write_access || @access
      end
    end

    # Command metadata
    struct CommandMetadata
      property id : DataType::CommandId
      property name : String
      property? optional : Bool
      property access : InteractionModel::EntryPrivilege
      # Id of the response command this command generates, if any
      property response_id : UInt32?
      property? timed : Bool

      def initialize(
        @id : DataType::CommandId,
        @name : String,
        @optional : Bool = false,
        @access : InteractionModel::EntryPrivilege = InteractionModel::EntryPrivilege::Operate,
        @response_id : UInt32? = nil,
        @timed : Bool = false,
      )
      end
    end

    # Command response - returned by invoke_command
    struct CommandResponse
      property command_id : UInt32
      property response : TLV::Any?

      def initialize(@command_id : UInt32, @response : TLV::Any?)
      end
    end

    # Event metadata
    struct EventMetadata
      property id : DataType::EventId
      property name : String
      property priority : InteractionModel::EventPriority
      # Privilege required to read the event
      property access : InteractionModel::EntryPrivilege

      def initialize(
        @id : DataType::EventId,
        @name : String,
        @priority : InteractionModel::EventPriority = InteractionModel::EventPriority::Info,
        @access : InteractionModel::EntryPrivilege = InteractionModel::EntryPrivilege::View,
      )
      end
    end

    # Called with `(endpoint, cluster, event, priority, data, fabric_index)`
    # whenever a cluster emits one of its declared events.
    alias EventEmittedCallback = Proc(UInt16, UInt32, UInt32, InteractionModel::EventPriority, TLV::Any, UInt8?, Nil)

    # Base class for all cluster implementations. Concrete clusters declare
    # their elements with the `DSL` macros (see `dsl.cr`).
    abstract class Base
      include DSL

      property endpoint_id : DataType::EndpointNumber
      property cluster_id : DataType::ClusterId
      property data_version : UInt32

      # Request context (populated by the protocol layer for the current operation).
      # These are intentionally prefixed to avoid colliding with cluster-specific state.
      property request_session_id : UInt64? = nil
      # Identity of the live secure session, distinct from its reusable wire ID.
      property request_session_identity : UInt64? = nil
      property request_exchange_id : UInt16? = nil
      property request_peer_node_id : UInt64? = nil
      # Authenticated CASE NOC subjects (node ID and CATs) for this request.
      property request_peer_subject_ids : Array(UInt64)? = nil
      property request_peer_address : Socket::IPAddress? = nil
      property request_peer_icac : Bytes? = nil
      property? request_is_case_session : Bool = false
      property request_fabric_index : UInt8? = nil
      property request_auth_mode : InteractionModel::EntryAuthMode? = nil
      property request_group_id : UInt16? = nil
      property? request_fabric_filtered : Bool = true
      # Highest ACL privilege granted to this command's caller. Populated only
      # during protocol command dispatch and cleared before the next invoke.
      property request_command_privilege : InteractionModel::EntryPrivilege? = nil

      @request_command_depth : UInt32 = 0_u32

      # True only while a command handler (including its synchronous callbacks)
      # is running. Request identity fields remain available after dispatch, so
      # callbacks that forward a command must check this as well as CASE.
      def request_command_active? : Bool
        @request_command_depth > 0_u32
      end

      # IMHandler sets request_* fields immediately before dispatch. A fiber
      # waiting in a cluster callback must retain its own authenticated
      # context until that operation finishes.
      @request_context_mutex : Mutex = Mutex.new(:reentrant)

      def with_request_context(&)
        @request_context_mutex.synchronize { yield }
      end

      # Callback for attribute change notifications (used by subscription system)
      # Parameters: endpoint_id, cluster_id, attribute_id
      property on_attribute_changed : Proc(UInt16, UInt32, UInt32, Nil)?

      # Called from `increment_version` after every data version bump; the
      # persistence layer uses it to mark this cluster dirty.
      property on_version_changed : Proc(Nil)?

      # Callback for emitted events (wired by `Node` exactly as
      # `on_attribute_changed` is; the node journals what arrives here).
      property on_event_emitted : EventEmittedCallback?

      # Separates the endpoint and cluster id in `persistence_key`.
      PERSISTENCE_KEY_SEPARATOR = "-"

      # Macro to add class method for accessing CLUSTER_ID constant
      # Revision of the cluster specification this implementation follows.
      # Subclasses override it by defining their own `CLUSTER_REVISION`.
      CLUSTER_REVISION = 1_u16

      macro inherited
        # DSL declarations accumulate here (see `dsl.cr`); `dsl_generate`
        # turns them into code once the class body is complete.
        CLUSTER_DECLS   = [] of Nil
        FEATURE_DECLS   = [] of Nil
        CONFLICT_DECLS  = [] of Nil
        ATTRIBUTE_DECLS = [] of Nil
        COMMAND_DECLS   = [] of Nil
        EVENT_DECLS     = [] of Nil

        macro finished
          dsl_generate
        end

        def self.cluster_id
          CLUSTER_ID
        end

        # Expanded in the subclass body, so the bare `CLUSTER_REVISION` is
        # resolved in the subclass scope when the method is first typed. That
        # finds the subclass's own constant even when it is defined after this
        # macro ran, and falls back to `Base::CLUSTER_REVISION` otherwise.
        def cluster_revision : UInt16
          CLUSTER_REVISION
        end
      end

      # The ClusterRevision global attribute value (`CLUSTER_REVISION`).
      def cluster_revision : UInt16
        CLUSTER_REVISION
      end

      def initialize(@endpoint_id : DataType::EndpointNumber, @cluster_id : DataType::ClusterId)
        @data_version = 0_u32
        @attribute_values = {} of UInt32 => TLV::Any
        dsl_validate_features
      end

      # Raises `ArgumentError` for a feature combination declared with
      # `conflicts`; generated by the DSL, a no-op otherwise.
      protected def dsl_validate_features : Nil
      end

      # Cluster-specific host FeatureMap mutation guard. Concrete clusters may
      # restrict a feature that depends on a live external capability.
      protected def validate_feature_map_change(value) : Nil
      end

      # The FeatureMap value; generated by the DSL when features are declared.
      protected def dsl_features : UInt32
        0_u32
      end

      # Get cluster name
      abstract def name : String

      # Get all attribute metadata
      abstract def attributes : Array(AttributeMetadata)

      # Get all command metadata
      def commands : Array(CommandMetadata)
        [] of CommandMetadata
      end

      # Get all event metadata
      def events : Array(EventMetadata)
        [] of EventMetadata
      end

      # Global attribute IDs (mandatory on all clusters)
      GLOBAL_ATTRIBUTE_LIST         = 0xFFFB_u32
      GLOBAL_ACCEPTED_COMMAND_LIST  = 0xFFF9_u32
      GLOBAL_GENERATED_COMMAND_LIST = 0xFFF8_u32
      GLOBAL_FEATURE_MAP            = 0xFFFC_u32
      GLOBAL_CLUSTER_REVISION       = 0xFFFD_u32

      # Read an attribute value
      # The fabric_index parameter is optional and used for fabric-scoped attributes
      # like CurrentFabricIndex in OperationalCredentials
      def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : InteractionModel::Status | TLV::Any
        # Handle global attributes that all clusters must support
        # These MUST be handled before checking cluster-specific attributes
        case attribute_id
        when GLOBAL_ATTRIBUTE_LIST
          return attribute_list_tlv
        when GLOBAL_ACCEPTED_COMMAND_LIST
          return accepted_command_list_tlv
        when GLOBAL_GENERATED_COMMAND_LIST
          return generated_command_list_tlv
        when GLOBAL_FEATURE_MAP
          return feature_map_tlv
        when GLOBAL_CLUSTER_REVISION
          return cluster_revision_tlv
        end

        dsl_read_attribute(attribute_id, fabric_index)
      end

      # Reads a cluster attribute. The DSL generates the declared branches
      # and falls through here for the rest: the stored value or the metadata
      # default of a hand-written `attributes` entry.
      protected def dsl_read_attribute(attribute_id : UInt32, fabric_index : UInt8?) : InteractionModel::Status | TLV::Any
        metadata = get_attribute_metadata(attribute_id)
        return InteractionModel::Status.unsupported_attribute unless metadata

        @attribute_values.fetch(attribute_id) do
          metadata.default || InteractionModel::Status.failure
        end
      end

      # Encode FeatureMap
      protected def feature_map_tlv : TLV::Any
        tlv(dsl_features)
      end

      # Encode ClusterRevision - subclasses set `CLUSTER_REVISION` instead of overriding
      protected def cluster_revision_tlv : TLV::Any
        tlv(cluster_revision)
      end

      # Encode AttributeList - override in subclass for custom handling
      protected def attribute_list_tlv : TLV::Any
        # Collect all attribute IDs (cluster-specific + global)
        attr_ids = attributes.map(&.id.id)
        attr_ids << GLOBAL_GENERATED_COMMAND_LIST
        attr_ids << GLOBAL_ACCEPTED_COMMAND_LIST
        attr_ids << GLOBAL_ATTRIBUTE_LIST
        attr_ids << GLOBAL_FEATURE_MAP
        attr_ids << GLOBAL_CLUSTER_REVISION
        unique_attr_ids = [] of UInt32
        attr_ids.each do |attribute_id|
          next if unique_attr_ids.includes?(attribute_id)
          unique_attr_ids << attribute_id
        end
        tlv(unique_attr_ids)
      end

      # Encode AcceptedCommandList - override in subclass for custom handling
      protected def accepted_command_list_tlv : TLV::Any
        tlv(commands.map(&.id.id))
      end

      # Encode GeneratedCommandList: the distinct response ids of the
      # supported commands that generate one
      protected def generated_command_list_tlv : TLV::Any
        tlv(commands.compact_map(&.response_id).uniq!)
      end

      # Write an attribute value.
      #
      # Exceptions escaping `handle_write_attribute` are mapped to an
      # Interaction Model status here so a misbehaving cluster never breaks the
      # protocol layer: `Matter::ClusterError` carries its own status, a TLV /
      # codec or argument failure is the peer's fault (`InvalidDataType`) and
      # anything else is a bug reported as `Failure`.
      def write_attribute(attribute_id : UInt32, value : TLV::Any) : InteractionModel::Status
        handle_write_attribute(attribute_id, value)
      rescue ex : Matter::ClusterError
        Log.warn(exception: ex) { "#{self.class.name}: write attribute 0x#{attribute_id.to_s(16)} rejected" }
        ex.to_status
      rescue ex : TLV::DeserializationError | TypeCastError | Matter::CodecError | ArgumentError
        Log.warn(exception: ex) { "#{self.class.name}: write attribute 0x#{attribute_id.to_s(16)} rejected" }
        InteractionModel::Status.invalid_data_type
      rescue ex
        Log.error(exception: ex) { "#{self.class.name}: write attribute 0x#{attribute_id.to_s(16)} failed" }
        InteractionModel::Status.failure
      end

      # Attribute write implementation (override in subclasses).
      protected def handle_write_attribute(attribute_id : UInt32, value : TLV::Any) : InteractionModel::Status
        dsl_write_attribute(attribute_id, value)
      end

      # Writes a cluster attribute. The DSL generates the declared branches
      # (decode, validate, assign through the setter) and falls through here
      # for the rest: a hand-written `attributes` entry stores the raw value.
      protected def dsl_write_attribute(attribute_id : UInt32, value : TLV::Any) : InteractionModel::Status
        metadata = get_attribute_metadata(attribute_id)
        return InteractionModel::Status.unsupported_attribute unless metadata
        return InteractionModel::Status.unsupported_write unless metadata.writable?

        @attribute_values[attribute_id] = value
        increment_version

        InteractionModel::Status.success
      end

      # Decode values without losing the TLV type at the cluster boundary.
      #
      # Every failure raised by the tlv shard is a fault in the peer's encoding,
      # so it is normalised to `TLV::DeserializationError` for the status mapping
      # in `write_attribute` / `invoke_command`. The shard itself raises a bare
      # `Exception` for enum and union mismatches (`raise "Cannot deserialize ..."`)
      # and `deserialize_field` only re-wraps `TypeCastError`.
      protected def decode(value : TLV::Any?, type : T.class) : T forall T
        raise TLV::DeserializationError.new("Missing command fields") unless value
        decoded = begin
          TLV::Serializable.deserialize_value(value, type)
        rescue ex : TLV::DeserializationError
          raise ex
        rescue ex
          raise TLV::DeserializationError.new(ex.message, cause: ex)
        end
        {% if T == String %}
          raise TLV::DeserializationError.new("Invalid UTF-8 string") unless decoded.valid_encoding?
        {% end %}
        decoded
      end

      protected def decode?(value : TLV::Any, type : T.class) : T? forall T
        {% if T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 %}
          number = value.as_u64?
          T.new(number) if number
        {% else %}
          decode(value, type)
        {% end %}
      rescue ex : TypeCastError | OverflowError | TLV::DeserializationError | ArgumentError
        Log.trace(exception: ex) { "Invalid attribute type for #{type}" }
        nil
      end

      # Small scalar attributes accept a wider unsigned wire representation.
      protected def narrow_u8?(value : TLV::Any) : UInt8?
        number = decode?(value, UInt64)
        number.to_u8 if number && number <= UInt8::MAX
      end

      protected def narrow_i8?(value : TLV::Any) : Int8?
        signed?(value, Int8)
      end

      # Existing signed attributes also accept nonnegative unsigned encodings.
      protected def signed?(value : TLV::Any, type : T.class) : T? forall T
        case number = value.value
        when Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64
          T.new(number)
        end
      rescue ex : OverflowError
        Log.trace(exception: ex) { "Attribute value out of range for #{type}" }
        nil
      end

      protected def tlv(value) : TLV::Any
        TLV::Serializable.serialize_value(value, nil)
      end

      # Invoke a command.
      #
      # Exceptions escaping `handle_command` are mapped to an Interaction Model
      # status here (see `write_attribute`): `Matter::ClusterError` carries its
      # own status, a codec or argument failure is `InvalidCommand` and anything
      # else is a bug reported as `Failure`.
      def invoke_command(command_id : UInt32, fields : TLV::Any? = nil, session_id : UInt64? = nil, is_case_session : Bool = false, fabric_index : UInt8? = nil) : InteractionModel::Status | CommandResponse
        previous_depth = @request_command_depth
        return InteractionModel::Status.unsupported_command unless get_command_metadata(command_id)

        # The request context the handlers read
        @request_command_depth = previous_depth + 1_u32
        @request_session_id = session_id
        @request_is_case_session = is_case_session
        @request_fabric_index = fabric_index

        # Command implementations override this
        handle_command(command_id, fields)
      rescue ex : Matter::ClusterError
        Log.warn(exception: ex) { "#{self.class.name}: command 0x#{command_id.to_s(16)} rejected" }
        ex.to_status
      rescue ex : TLV::DeserializationError | TypeCastError | Matter::CodecError | ArgumentError
        Log.warn(exception: ex) { "#{self.class.name}: command 0x#{command_id.to_s(16)} rejected" }
        InteractionModel::Status.invalid_command
      rescue ex
        Log.error(exception: ex) { "#{self.class.name}: command 0x#{command_id.to_s(16)} failed" }
        InteractionModel::Status.failure
      ensure
        @request_command_depth = previous_depth if previous_depth
        @request_command_privilege = nil
      end

      # Handle command implementation (to be overridden)
      protected def handle_command(command_id : UInt32, fields : TLV::Any?) : InteractionModel::Status | CommandResponse
        dsl_invoke_command(command_id, fields)
      end

      # Dispatches a declared command to its handler; generated by the DSL.
      protected def dsl_invoke_command(command_id : UInt32, fields : TLV::Any?) : InteractionModel::Status | CommandResponse
        InteractionModel::Status.unsupported_command
      end

      # Normalises a command handler's result: a status or response passes
      # through, a `TLV::Serializable` response struct is wrapped.
      protected def dsl_command_result(result : InteractionModel::Status | CommandResponse, response_id : UInt32) : InteractionModel::Status | CommandResponse
        result
      end

      protected def dsl_command_result(result : TLV::Serializable, response_id : UInt32) : CommandResponse
        CommandResponse.new(response_id, result.to_tlv(nil))
      end

      # Encodes a computed attribute reader's result: a status or an encoded
      # value passes through, an enum is encoded by value, anything else as is.
      protected def dsl_computed_value(value : InteractionModel::Status | TLV::Any) : InteractionModel::Status | TLV::Any
        value
      end

      protected def dsl_computed_value(value : Enum) : TLV::Any
        tlv(value.value)
      end

      protected def dsl_computed_value(value) : TLV::Any
        tlv(value)
      end

      # Increment data version (call when attribute changes). This is the only
      # place the version moves so persistence sees every change.
      protected def increment_version
        @data_version &+= 1
        @on_version_changed.try(&.call)
      end

      # Notify that a specific attribute has changed (triggers subscription updates)
      # This should be called after changing an attribute value
      protected def notify_changed(attribute_id : UInt32)
        if callback = @on_attribute_changed
          callback.call(@endpoint_id.number, @cluster_id.id, attribute_id)
        end
      end

      # Increment version AND notify about a specific attribute change
      # This is the preferred method when an attribute value changes
      protected def increment_version_and_notify(attribute_id : UInt32)
        increment_version
        notify_changed(attribute_id)
      end

      # Get attribute metadata by ID
      def get_attribute_metadata(attribute_id : UInt32) : AttributeMetadata?
        attributes.find { |attr| attr.id.id == attribute_id }
      end

      # Get command metadata by ID
      def get_command_metadata(command_id : UInt32) : CommandMetadata?
        commands.find { |cmd| cmd.id.id == command_id }
      end

      # Get event metadata by ID
      def get_event_metadata(event_id : UInt32) : EventMetadata?
        events.find { |event| event.id.id == event_id }
      end

      # Emits one of this cluster's declared events.
      #
      # The priority comes from the declaration, so a cluster cannot report the
      # same event at two priorities. Emitting an event the cluster does not
      # declare - or one gated off by its feature map - is a configuration bug
      # and raises rather than silently dropping the event.
      #
      # *fabric_index* marks the event as fabric scoped: only readers on that
      # fabric will see it. Leave it `nil` for a node-scoped event.
      def emit_event(event_id : UInt32, data : TLV::Any, fabric_index : UInt8? = nil) : Nil
        metadata = get_event_metadata(event_id)
        unless metadata
          raise ConfigurationError.new(
            "#{self.class.name} does not declare event 0x#{event_id.to_s(16)} (endpoint #{@endpoint_id.number})"
          )
        end

        @on_event_emitted.try(&.call(
          @endpoint_id.number,
          @cluster_id.id,
          event_id,
          metadata.priority,
          data,
          fabric_index
        ))
      end

      # :ditto:
      #
      # Encodes a `TLV::Serializable` payload struct first.
      def emit_event(event_id : UInt32, payload : TLV::Serializable, fabric_index : UInt8? = nil) : Nil
        emit_event(event_id, payload.to_tlv(nil), fabric_index)
      end

      # The id of this cluster's document in the `clusters` collection:
      # `"<endpoint>-<cluster id>"` in decimal.
      def persistence_key : String
        Base.persistence_key(@endpoint_id.number, @cluster_id.id)
      end

      # :ditto:
      def self.persistence_key(endpoint : UInt16, cluster_id : UInt32) : String
        "#{endpoint}#{PERSISTENCE_KEY_SEPARATOR}#{cluster_id}"
      end

      # The cluster state to persist, or nil when the cluster has none.
      # Override in subclasses that need to persist state (e.g., scenes, groups).
      def save_state : Storage::Document?
        nil
      end

      # A cluster may serialize its snapshot and backend write with lifecycle
      # mutations that would otherwise invalidate that snapshot.
      def with_persistence_guard(&)
        yield
      end

      # Restore cluster state from a document produced by `save_state`.
      # Override in subclasses that need to restore state.
      def restore_state(document : Storage::Document) : Nil
        # Default: no-op
      end

      # Clusters with security-critical persisted state can require startup to
      # fail when their document cannot be read or restored.
      def fail_closed_restore? : Bool
        false
      end

      # Whether this cluster has host-managed state that requires an
      # independent marker when its document is persisted.
      def persist_restore_sentinel? : Bool
        false
      end

      # Whether an advertised feature requires a saved document once a fabric
      # exists, even before any host-managed state was configured.
      def require_state_with_fabrics? : Bool
        false
      end

      # ------------------------------------------------------------------------
      # Scenes Management hooks
      # ------------------------------------------------------------------------
      #
      # ScenesManagement (0x0062) stores "extension field sets" that capture
      # cluster-specific state for scene recall. Clusters can override these hooks
      # to participate; default implementations are no-ops.
      #
      # The Device base class wires ScenesManagement callbacks by calling
      # these methods on clusters present on the same endpoint.
      def store_scene_extension_field_set : ScenesManagement::ExtensionFieldSet?
        nil
      end

      def apply_scene_extension_field_set(field_set : ScenesManagement::ExtensionFieldSet) : Bool
        false
      end
    end
  end
end
