require "./cluster"
require "../fabric"
require "tlv"

module Matter
  module Cluster
    # Scenes Management Cluster Implementation (0x0062)
    #
    # Provides scene storage and recall functionality.
    # This is the Matter 1.4+ replacement for the deprecated Scenes cluster (0x0005).
    #
    # Features:
    # - SceneNames (SN): Store names for scenes
    #
    # Specification: Matter 1.4 § 1.4

    # TLV-serializable SceneInfo for FabricSceneInfo attribute
    struct SceneInfoTlv
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property scene_count : UInt8

      @[TLV::Field(tag: 1)]
      property current_scene : UInt8

      @[TLV::Field(tag: 2)]
      property current_group : UInt16

      @[TLV::Field(tag: 3)]
      property? scene_valid : Bool

      @[TLV::Field(tag: 4)]
      property remaining_capacity : UInt8

      @[TLV::Field(tag: 254)]
      property fabric_index : UInt8

      def initialize(
        @scene_count = 0_u8,
        @current_scene = ScenesManagement::UNDEFINED_SCENE_ID,
        @current_group = DataType::GroupId::RESERVED.id,
        @scene_valid = false,
        @remaining_capacity = 16_u8,
        @fabric_index = ScenesManagement::DEFAULT_FABRIC_INDEX,
      )
      end
    end

    # Standard scene status response (AddScene, RemoveScene, StoreScene)
    struct SceneStatusResponse
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property status : UInt8

      @[TLV::Field(tag: 1)]
      property group_id : UInt16

      @[TLV::Field(tag: 2)]
      property scene_id : UInt8

      def initialize(@status : UInt8, @group_id : UInt16, @scene_id : UInt8)
      end
    end

    # Attribute value pair for extension field sets
    # Per Matter spec: AttributeValuePairStruct
    # The value field used depends on the attribute's data type:
    # - valueUnsigned8 (tag 1): bool, map8, uint8
    # - valueSigned8 (tag 2): int8
    # - valueUnsigned16 (tag 3): map16, uint16
    # - valueSigned16 (tag 4): int16
    # - valueUnsigned32 (tag 5): map32, uint24, uint32
    # - valueSigned32 (tag 6): int24, int32
    # - valueUnsigned64 (tag 7): map64, uint40-64
    # - valueSigned64 (tag 8): int40-64
    struct AttributeValuePairTlv
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property attribute_id : UInt32

      @[TLV::Field(tag: 1, optional: true)]
      property value_unsigned8 : UInt8?

      @[TLV::Field(tag: 2, optional: true)]
      property value_signed8 : Int8?

      @[TLV::Field(tag: 3, optional: true)]
      property value_unsigned16 : UInt16?

      @[TLV::Field(tag: 4, optional: true)]
      property value_signed16 : Int16?

      @[TLV::Field(tag: 5, optional: true)]
      property value_unsigned32 : UInt32?

      @[TLV::Field(tag: 6, optional: true)]
      property value_signed32 : Int32?

      @[TLV::Field(tag: 7, optional: true)]
      property value_unsigned64 : UInt64?

      @[TLV::Field(tag: 8, optional: true)]
      property value_signed64 : Int64?

      def initialize(@attribute_id : UInt32,
                     @value_unsigned8 : UInt8? = nil,
                     @value_signed8 : Int8? = nil,
                     @value_unsigned16 : UInt16? = nil,
                     @value_signed16 : Int16? = nil,
                     @value_unsigned32 : UInt32? = nil,
                     @value_signed32 : Int32? = nil,
                     @value_unsigned64 : UInt64? = nil,
                     @value_signed64 : Int64? = nil)
      end

      # Scene snapshots retain TLV bytes for storage and the extension callbacks.
      def attribute_value : TLV::Any
        value = @value_unsigned8 || @value_signed8 || @value_unsigned16 || @value_signed16 ||
                @value_unsigned32 || @value_signed32 || @value_unsigned64 || @value_signed64
        raise ArgumentError.new("scene attribute is missing its value") if value.nil?
        TLV::Any.new(value)
      end

      # Create from a decoded attribute value, selecting the matching value field
      def self.from_attribute_value(attribute_id : UInt32, tlv_value : TLV::Any) : AttributeValuePairTlv
        case value = tlv_value.value
        when Bool
          # Boolean maps to valueUnsigned8
          new(attribute_id, value_unsigned8: value ? 1_u8 : 0_u8)
        when UInt8
          new(attribute_id, value_unsigned8: value)
        when Int8
          new(attribute_id, value_signed8: value)
        when UInt16
          new(attribute_id, value_unsigned16: value)
        when Int16
          new(attribute_id, value_signed16: value)
        when UInt32
          new(attribute_id, value_unsigned32: value)
        when Int32
          new(attribute_id, value_signed32: value)
        when UInt64
          new(attribute_id, value_unsigned64: value)
        when Int64
          new(attribute_id, value_signed64: value)
        else
          # For other types, try to extract a numeric value
          # Default to unsigned8 for unknown types
          new(attribute_id, value_unsigned8: 0_u8)
        end
      end
    end

    # Extension field set - cluster state snapshot for a scene
    # Per Matter spec: ExtensionFieldSetStruct
    struct ExtensionFieldSetTlv
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property cluster_id : UInt32

      @[TLV::Field(tag: 1)]
      property attribute_value_list : Array(AttributeValuePairTlv)

      def initialize(@cluster_id : UInt32, @attribute_value_list : Array(AttributeValuePairTlv))
      end
    end

    # ViewScene response
    struct ViewSceneResponseTlv
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property status : UInt8

      @[TLV::Field(tag: 1)]
      property group_id : UInt16

      @[TLV::Field(tag: 2)]
      property scene_id : UInt8

      @[TLV::Field(tag: 3, optional: true)]
      property transition_time : UInt32?

      @[TLV::Field(tag: 4, optional: true)]
      property scene_name : String?

      @[TLV::Field(tag: 5, optional: true)]
      property extension_field_sets : Array(ExtensionFieldSetTlv)?

      def initialize(
        @status : UInt8,
        @group_id : UInt16,
        @scene_id : UInt8,
        @transition_time : UInt32? = nil,
        @scene_name : String? = nil,
        @extension_field_sets : Array(ExtensionFieldSetTlv)? = nil,
      )
      end
    end

    # RemoveAllScenes response
    struct RemoveAllScenesResponse
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property status : UInt8

      @[TLV::Field(tag: 1)]
      property group_id : UInt16

      def initialize(@status : UInt8, @group_id : UInt16)
      end
    end

    # GetSceneMembership response
    struct GetSceneMembershipResponse
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property status : UInt8

      @[TLV::Field(tag: 1, optional: true)]
      property capacity : UInt8?

      @[TLV::Field(tag: 2)]
      property group_id : UInt16

      @[TLV::Field(tag: 3, optional: true)]
      property scene_list : Array(UInt8)?

      def initialize(
        @status : UInt8,
        @group_id : UInt16,
        @capacity : UInt8? = nil,
        @scene_list : Array(UInt8)? = nil,
      )
      end
    end

    # CopyScene response
    struct CopySceneResponse
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property status : UInt8

      @[TLV::Field(tag: 1)]
      property group_identifier_from : UInt16

      @[TLV::Field(tag: 2)]
      property scene_identifier_from : UInt8

      def initialize(@status : UInt8, @group_identifier_from : UInt16, @scene_identifier_from : UInt8)
      end
    end

    # Command request structs

    struct AddSceneRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property group_id : UInt16

      @[TLV::Field(tag: 1)]
      property scene_id : UInt8

      @[TLV::Field(tag: 2)]
      property transition_time : UInt32

      @[TLV::Field(tag: 3, optional: true)]
      property scene_name : String?

      @[TLV::Field(tag: 4, optional: true)]
      property extension_field_sets : Array(TLV::Any)?

      def initialize(@group_id : UInt16, @scene_id : UInt8, @transition_time : UInt32, @scene_name : String? = nil, @extension_field_sets : Array(TLV::Any)? = nil)
      end
    end

    struct ViewSceneRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property group_id : UInt16

      @[TLV::Field(tag: 1)]
      property scene_id : UInt8

      def initialize(@group_id : UInt16, @scene_id : UInt8)
      end
    end

    struct RemoveSceneRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property group_id : UInt16

      @[TLV::Field(tag: 1)]
      property scene_id : UInt8

      def initialize(@group_id : UInt16, @scene_id : UInt8)
      end
    end

    struct RemoveAllScenesRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property group_id : UInt16

      def initialize(@group_id : UInt16)
      end
    end

    struct StoreSceneRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property group_id : UInt16

      @[TLV::Field(tag: 1)]
      property scene_id : UInt8

      def initialize(@group_id : UInt16, @scene_id : UInt8)
      end
    end

    struct RecallSceneRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property group_id : UInt16

      @[TLV::Field(tag: 1)]
      property scene_id : UInt8

      @[TLV::Field(tag: 2, optional: true)]
      property transition_time : UInt32?

      def initialize(@group_id : UInt16, @scene_id : UInt8, @transition_time : UInt32? = nil)
      end
    end

    struct GetSceneMembershipRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property group_id : UInt16

      def initialize(@group_id : UInt16)
      end
    end

    struct CopySceneRequest
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property mode : UInt8

      @[TLV::Field(tag: 1)]
      property group_identifier_from : UInt16

      @[TLV::Field(tag: 2)]
      property scene_identifier_from : UInt8

      @[TLV::Field(tag: 3)]
      property group_identifier_to : UInt16

      @[TLV::Field(tag: 4)]
      property scene_identifier_to : UInt8

      def initialize(@mode : UInt8, @group_identifier_from : UInt16, @scene_identifier_from : UInt8, @group_identifier_to : UInt16, @scene_identifier_to : UInt8)
      end
    end

    class ScenesManagement < Base
      Log = ::Log.for("matter.cluster.scenes_management")

      cluster 0x0062, revision: 1, persist_state: false

      feature :scene_names, bit: 0 # SN - Store names for scenes

      # Used only by the direct, local convenience methods below. A network
      # command must always use its authenticated request fabric instead.
      DEFAULT_FABRIC_INDEX = 1_u8

      # Minimum Scene Table size the specification allows (Matter 1.4 §1.4.8.1).
      DEFAULT_SCENE_TABLE_SIZE =  16_u16
      UNDEFINED_SCENE_ID       = 0xFF_u8
      GLOBAL_SCENE_GROUP_ID    = DataType::GroupId::RESERVED.id
      GLOBAL_SCENE_ID          = 0_u8

      # Largest exact capacity a SceneInfo / GetSceneMembershipResponse can
      # report; 0xFE means "at least one" and 0xFF "unknown".
      MAX_REPORTED_CAPACITY = 253

      # CopyScene mode bit: copy every scene of the source group.
      COPY_MODE_ALL_SCENES = 0x01_u8

      # SceneInfo structure for fabric-scoped scene info
      struct SceneInfo
        include Storage::Record

        property scene_count : UInt8
        property current_scene : UInt8
        property current_group : UInt16
        property? scene_valid : Bool
        property remaining_capacity : UInt8
        property fabric_index : UInt8

        def initialize(
          @scene_count = 0_u8,
          @current_scene = UNDEFINED_SCENE_ID,
          @current_group = DataType::GroupId::RESERVED.id,
          @scene_valid = false,
          @remaining_capacity = DEFAULT_SCENE_TABLE_SIZE.to_u8,
          @fabric_index = DEFAULT_FABRIC_INDEX,
        )
        end
      end

      # Extension field set for scene data: the attribute values a sceneable
      # cluster captured, keyed by attribute id.
      struct ExtensionFieldSet
        property cluster_id : UInt32
        property attribute_value_list : Array(Tuple(UInt32, TLV::Any))

        def initialize(@cluster_id, attribute_list : Array(Tuple(UInt32, TLV::Any)) = [] of Tuple(UInt32, TLV::Any))
          @attribute_value_list = attribute_list
        end
      end

      # Scene data structure
      struct SceneData
        property transition_time : UInt32 # milliseconds
        property scene_name : String
        property extension_field_sets : Array(ExtensionFieldSet)

        def initialize(
          @transition_time = 0_u32,
          @scene_name = "",
          @extension_field_sets = [] of ExtensionFieldSet,
        )
        end
      end

      # One attribute value of a persisted extension field set (TLV bytes).
      struct PersistedAttributeValue
        include Storage::Record

        getter attribute_id : UInt32
        getter value : Bytes

        def initialize(@attribute_id : UInt32, @value : Bytes)
        end
      end

      # A persisted extension field set.
      struct PersistedExtensionFieldSet
        include Storage::Record

        getter cluster_id : UInt32
        getter attributes : Array(PersistedAttributeValue)

        def initialize(@cluster_id : UInt32, @attributes : Array(PersistedAttributeValue))
        end

        def self.from_field_set(field_set : ExtensionFieldSet) : PersistedExtensionFieldSet
          new(field_set.cluster_id, field_set.attribute_value_list.map { |id, value| PersistedAttributeValue.new(id, value.to_slice) })
        end

        def to_field_set : ExtensionFieldSet
          ExtensionFieldSet.new(@cluster_id, @attributes.map { |attribute| {attribute.attribute_id, TLV::Any.from_slice(attribute.value)} })
        end
      end

      # A persisted scene: its key (fabric, group, scene) and data.
      struct PersistedScene
        include Storage::Record

        getter fabric_index : UInt8
        getter group_id : UInt16
        getter scene_id : UInt8
        getter transition_time : UInt32
        getter scene_name : String
        getter extension_field_sets : Array(PersistedExtensionFieldSet)

        def initialize(
          @fabric_index : UInt8,
          @group_id : UInt16,
          @scene_id : UInt8,
          @transition_time : UInt32,
          @scene_name : String,
          @extension_field_sets : Array(PersistedExtensionFieldSet),
        )
        end

        def self.from_scene(key : {UInt8, UInt16, UInt8}, data : SceneData) : PersistedScene
          new(
            fabric_index: key[0],
            group_id: key[1],
            scene_id: key[2],
            transition_time: data.transition_time,
            scene_name: data.scene_name,
            extension_field_sets: data.extension_field_sets.map { |field_set| PersistedExtensionFieldSet.from_field_set(field_set) }
          )
        end

        def key : {UInt8, UInt16, UInt8}
          {@fabric_index, @group_id, @scene_id}
        end

        def to_scene_data : SceneData
          SceneData.new(@transition_time, @scene_name, @extension_field_sets.map(&.to_field_set))
        end
      end

      # Full persisted cluster state.
      struct PersistedState
        include Storage::Record

        getter scenes : Array(PersistedScene)
        getter fabric_scene_info : Hash(UInt8, SceneInfo)
        getter data_version : UInt32

        def initialize(
          @scenes : Array(PersistedScene),
          @fabric_scene_info : Hash(UInt8, SceneInfo),
          @data_version : UInt32,
        )
        end
      end

      # Scene table size (total across all fabrics)
      attribute 0x0001, :scene_table_size, UInt16, default: DEFAULT_SCENE_TABLE_SIZE, fixed: true
      # Computed for the accessing fabric from `scene_info_by_fabric`.
      attribute 0x0002, :fabric_scene_info, Array(SceneInfoTlv), computed: true, fabric_scoped: true

      command 0x00, :add_scene, request: AddSceneRequest, response: SceneStatusResponse, access: :manage
      command 0x01, :view_scene, request: ViewSceneRequest, response: ViewSceneResponseTlv
      command 0x02, :remove_scene, request: RemoveSceneRequest, response: SceneStatusResponse, access: :manage
      command 0x03, :remove_all_scenes, request: RemoveAllScenesRequest, response: RemoveAllScenesResponse, access: :manage
      command 0x04, :store_scene, request: StoreSceneRequest, response: SceneStatusResponse, access: :manage
      command 0x05, :recall_scene, request: RecallSceneRequest
      command 0x06, :get_scene_membership, request: GetSceneMembershipRequest, response: GetSceneMembershipResponse
      command 0x40, :copy_scene, request: CopySceneRequest, response: CopySceneResponse, access: :manage, optional: true

      # Scene storage: {fabric_index, group_id, scene_id} => SceneData
      property scenes : Hash({UInt8, UInt16, UInt8}, SceneData)

      # Per-fabric scene info, the source of the FabricSceneInfo attribute
      property scene_info_by_fabric : Hash(UInt8, SceneInfo)

      # Callback for when scene is recalled (legacy - use apply_extension_field_sets instead)
      property on_recall_scene : Proc(UInt16, UInt8, Nil)?

      # Callback to get current extension field sets from other clusters during StoreScene
      # Returns array of extension field sets representing current state of sceneable clusters
      property get_extension_field_sets : Proc(Array(ExtensionFieldSet))?

      # Callback to apply extension field sets to other clusters during RecallScene
      # Receives the stored extension field sets to apply to sceneable clusters
      property apply_extension_field_sets : Proc(Array(ExtensionFieldSet), Nil)?

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @feature_map : Feature = Feature::SceneNames,
        @scene_table_size : UInt16 = DEFAULT_SCENE_TABLE_SIZE,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @scenes = Hash({UInt8, UInt16, UInt8}, SceneData).new
        @scene_info_by_fabric = Hash(UInt8, SceneInfo).new
      end

      # FabricSceneInfo reports the accessing fabric, plus other stored
      # fabrics when the authenticated read is not fabric-filtered.
      def fabric_scene_info(fabric_index : UInt8?) : Array(SceneInfoTlv) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        indices = request_fabric_filtered? ? [fabric_index] : (@scene_info_by_fabric.keys + [fabric_index]).uniq.sort!
        result = [] of SceneInfoTlv
        indices.each do |index|
          scene_info = @scene_info_by_fabric[index]? || SceneInfo.new(fabric_index: index)
          result << SceneInfoTlv.new(
            scene_count: scene_info.scene_count,
            current_scene: scene_info.current_scene,
            current_group: scene_info.current_group,
            scene_valid: scene_info.scene_valid?,
            remaining_capacity: scene_info.remaining_capacity,
            fabric_index: index
          )
        end
        result
      end

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def add_scene(request : AddSceneRequest) : SceneStatusResponse
        fabric_index = scene_fabric_index
        key = {fabric_index, request.group_id, request.scene_id}

        if fabric_full?(fabric_index) && !@scenes.has_key?(key)
          return scene_status_response(InteractionModel::StatusCode::ResourceExhausted, request.group_id, request.scene_id)
        end

        extension_fields = (request.extension_field_sets || [] of TLV::Any).map do |value|
          field_set = ExtensionFieldSetTlv.from_tlv(value)
          attributes = field_set.attribute_value_list.map { |pair| {pair.attribute_id, pair.attribute_value} }
          ExtensionFieldSet.new(field_set.cluster_id, attributes)
        end
        @scenes[key] = SceneData.new(request.transition_time, request.scene_name || "", extension_fields)
        update_fabric_scene_info(fabric_index)

        scene_status_response(InteractionModel::StatusCode::Success, request.group_id, request.scene_id)
      end

      def view_scene(request : ViewSceneRequest) : ViewSceneResponseTlv
        key = {scene_fabric_index, request.group_id, request.scene_id}

        if scene = @scenes[key]?
          view_scene_response(InteractionModel::StatusCode::Success, request.group_id, request.scene_id, scene)
        else
          view_scene_response(InteractionModel::StatusCode::NotFound, request.group_id, request.scene_id, nil)
        end
      end

      def remove_scene(request : RemoveSceneRequest) : SceneStatusResponse
        fabric_index = scene_fabric_index
        key = {fabric_index, request.group_id, request.scene_id}

        if @scenes.delete(key)
          update_fabric_scene_info(fabric_index)
          scene_status_response(InteractionModel::StatusCode::Success, request.group_id, request.scene_id)
        else
          scene_status_response(InteractionModel::StatusCode::NotFound, request.group_id, request.scene_id)
        end
      end

      def remove_all_scenes(request : RemoveAllScenesRequest) : RemoveAllScenesResponse
        fabric_index = scene_fabric_index
        @scenes.reject! { |key, _| key[0] == fabric_index && key[1] == request.group_id }
        update_fabric_scene_info(fabric_index)

        RemoveAllScenesResponse.new(InteractionModel::StatusCode::Success.value, request.group_id)
      end

      def store_scene(request : StoreSceneRequest) : SceneStatusResponse
        store_scene_for_fabric(request, scene_fabric_index)
      end

      # OnOff Lighting uses the reserved global scene identity. The caller
      # supplies its authenticated fabric because this cluster is not the
      # dispatched command target and has no request context of its own.
      def store_global_scene(fabric_index : UInt8) : Bool
        with_request_context do
          store_scene_for_fabric(StoreSceneRequest.new(GLOBAL_SCENE_GROUP_ID, GLOBAL_SCENE_ID), fabric_index)
            .status == InteractionModel::StatusCode::Success.value
        end
      end

      private def store_scene_for_fabric(request : StoreSceneRequest, fabric_index : UInt8) : SceneStatusResponse
        key = {fabric_index, request.group_id, request.scene_id}

        if fabric_full?(fabric_index) && !@scenes.has_key?(key)
          return scene_status_response(InteractionModel::StatusCode::ResourceExhausted, request.group_id, request.scene_id)
        end

        # Get extension field sets from other clusters (if callback is set)
        extension_fields = @get_extension_field_sets.try(&.call) || [] of ExtensionFieldSet

        @scenes[key] = SceneData.new(
          transition_time: 0_u32,
          scene_name: "",
          extension_field_sets: extension_fields
        )
        update_fabric_scene_info(fabric_index)

        Log.debug { "Stored scene #{request.scene_id} in group #{request.group_id} with #{extension_fields.size} extension field set(s)" }

        scene_status_response(InteractionModel::StatusCode::Success, request.group_id, request.scene_id)
      end

      def recall_scene(request : RecallSceneRequest) : InteractionModel::Status
        recall_scene_for_fabric(request, scene_fabric_index)
      end

      def recall_global_scene(fabric_index : UInt8) : Bool
        with_request_context do
          request = RecallSceneRequest.new(GLOBAL_SCENE_GROUP_ID, GLOBAL_SCENE_ID)
          @scenes.has_key?({fabric_index, GLOBAL_SCENE_GROUP_ID, GLOBAL_SCENE_ID}) &&
            recall_scene_for_fabric(request, fabric_index).status == InteractionModel::StatusCode::Success
        end
      end

      private def recall_scene_for_fabric(request : RecallSceneRequest, fabric_index : UInt8) : InteractionModel::Status
        key = {fabric_index, request.group_id, request.scene_id}

        scene_data = @scenes[key]?
        return InteractionModel::Status.not_found unless scene_data

        info = @scene_info_by_fabric[fabric_index]? || SceneInfo.new(fabric_index: fabric_index)
        info.current_scene = request.scene_id
        info.current_group = request.group_id
        info.scene_valid = true
        @scene_info_by_fabric[fabric_index] = info

        # Apply extension field sets to other clusters
        if scene_data.extension_field_sets.size > 0
          Log.debug { "Recalling scene #{request.scene_id} from group #{request.group_id} with #{scene_data.extension_field_sets.size} extension field set(s)" }
          @apply_extension_field_sets.try(&.call(scene_data.extension_field_sets))
        end

        # Legacy callback
        @on_recall_scene.try(&.call(request.group_id, request.scene_id))

        InteractionModel::Status.success
      end

      def get_scene_membership(request : GetSceneMembershipRequest) : GetSceneMembershipResponse
        fabric_index = scene_fabric_index
        scene_list = @scenes.keys.select { |key| key[0] == fabric_index && key[1] == request.group_id }.map { |key| key[2] }

        GetSceneMembershipResponse.new(
          status: InteractionModel::StatusCode::Success.value,
          group_id: request.group_id,
          capacity: remaining_capacity(fabric_index),
          scene_list: scene_list
        )
      end

      def copy_scene(request : CopySceneRequest) : CopySceneResponse
        fabric_index = scene_fabric_index
        copy_all = (request.mode & COPY_MODE_ALL_SCENES) != 0

        if copy_all
          @scenes.select { |key, _| key[0] == fabric_index && key[1] == request.group_identifier_from }.each do |key, data|
            new_key = {fabric_index, request.group_identifier_to, key[2]}
            @scenes[new_key] = SceneData.new(data.transition_time, data.scene_name, data.extension_field_sets)
          end
        else
          source_key = {fabric_index, request.group_identifier_from, request.scene_identifier_from}
          if data = @scenes[source_key]?
            dest_key = {fabric_index, request.group_identifier_to, request.scene_identifier_to}
            @scenes[dest_key] = SceneData.new(data.transition_time, data.scene_name, data.extension_field_sets)
          else
            return copy_response(InteractionModel::StatusCode::NotFound, request.group_identifier_from, request.scene_identifier_from)
          end
        end

        update_fabric_scene_info(fabric_index)
        copy_response(InteractionModel::StatusCode::Success, request.group_identifier_from, request.scene_identifier_from)
      end

      private def fabric_full?(fabric_index : UInt8) : Bool
        scene_count(fabric_index) >= @scene_table_size
      end

      private def scene_fabric_index : UInt8
        fabric_index = request_fabric_index || raise Matter::ClusterError.new("Scene commands require an authenticated fabric",
          InteractionModel::StatusCode::UnsupportedAccess)
        valid_auth = case request_auth_mode
                     when InteractionModel::EntryAuthMode::Case
                       request_is_case_session?
                     when InteractionModel::EntryAuthMode::Group
                       !request_is_case_session?
                     when Nil
                       # Direct callers can supply the CASE flag without an auth-mode descriptor.
                       request_is_case_session?
                     else
                       false
                     end
        unless (Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX).includes?(fabric_index) && valid_auth
          raise Matter::ClusterError.new("Scene commands require an authenticated fabric",
            InteractionModel::StatusCode::UnsupportedAccess)
        end
        fabric_index
      end

      private def remaining_capacity(fabric_index : UInt8) : UInt8
        (@scene_table_size - scene_count(fabric_index)).clamp(0, MAX_REPORTED_CAPACITY).to_u8
      end

      # Update fabric scene info after changes
      private def update_fabric_scene_info(fabric_index : UInt8)
        info = @scene_info_by_fabric[fabric_index]? || SceneInfo.new(fabric_index: fabric_index)
        info.scene_count = scene_count(fabric_index).to_u8
        info.remaining_capacity = remaining_capacity(fabric_index)
        @scene_info_by_fabric[fabric_index] = info
        increment_version_and_notify(ATTR_FABRIC_SCENE_INFO)
      end

      private def scene_status_response(status : InteractionModel::StatusCode, group_id : UInt16, scene_id : UInt8) : SceneStatusResponse
        SceneStatusResponse.new(status.value, group_id, scene_id)
      end

      private def view_scene_response(status : InteractionModel::StatusCode, group_id : UInt16, scene_id : UInt8, scene : SceneData?) : ViewSceneResponseTlv
        if scene && status == InteractionModel::StatusCode::Success
          ext_fields = scene.extension_field_sets.map do |efs|
            attr_pairs = efs.attribute_value_list.map do |attr_id, attr_value|
              AttributeValuePairTlv.from_attribute_value(attr_id, attr_value)
            end
            ExtensionFieldSetTlv.new(efs.cluster_id, attr_pairs)
          end

          ViewSceneResponseTlv.new(
            status: status.value,
            group_id: group_id,
            scene_id: scene_id,
            transition_time: scene.transition_time,
            scene_name: scene.scene_name,
            extension_field_sets: ext_fields.empty? ? nil : ext_fields
          )
        else
          ViewSceneResponseTlv.new(status: status.value, group_id: group_id, scene_id: scene_id)
        end
      end

      private def copy_response(status : InteractionModel::StatusCode, group_from : UInt16, scene_from : UInt8) : CopySceneResponse
        CopySceneResponse.new(status.value, group_from, scene_from)
      end

      # Public API

      def scene_count(fabric_index : UInt8 = DEFAULT_FABRIC_INDEX) : Int32
        @scenes.count { |key, _| key[0] == fabric_index }
      end

      def has_scene?(group_id : UInt16, scene_id : UInt8, fabric_index : UInt8 = DEFAULT_FABRIC_INDEX) : Bool
        @scenes.has_key?({fabric_index, group_id, scene_id})
      end

      def invalidate_current_scene(fabric_index : UInt8 = DEFAULT_FABRIC_INDEX)
        if info = @scene_info_by_fabric[fabric_index]?
          info.scene_valid = false
          @scene_info_by_fabric[fabric_index] = info
          increment_version_and_notify(ATTR_FABRIC_SCENE_INFO)
        end
      end

      # Fabric indexes are reusable. Erase both scene data and the fabric's
      # SceneInfo before another commissioner can receive the same index.
      def fabric_indices : Array(UInt8)
        (@scenes.keys.map { |key| key[0] } + @scene_info_by_fabric.keys).uniq
      end

      def remove_fabric(fabric_index : UInt8) : Nil
        previous_size = @scenes.size
        @scenes.reject! { |key, _| key[0] == fabric_index }
        removed_info = @scene_info_by_fabric.delete(fabric_index)
        increment_version_and_notify(ATTR_FABRIC_SCENE_INFO) if @scenes.size != previous_size || removed_info
      end

      # Persistence support

      def save_state : Storage::Document?
        PersistedState.new(
          scenes: @scenes.map { |key, data| PersistedScene.from_scene(key, data) },
          fabric_scene_info: @scene_info_by_fabric,
          data_version: @data_version
        ).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)

        @scenes.clear
        state.scenes.each { |scene| @scenes[scene.key] = scene.to_scene_data }

        @scene_info_by_fabric = state.fabric_scene_info
        @data_version = state.data_version
      rescue ex
        Log.error(exception: ex) { "ScenesManagement restore_state failed; starting fresh" }
      end
    end
  end
end
