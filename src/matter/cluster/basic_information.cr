require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Basic Information Cluster Implementation (0x0028)
    # Provides attributes about the device hardware, software, and configuration
    #
    # Required on endpoint 0 (root node).
    #
    # Matter Spec: Core 11.1
    class BasicInformation < Base
      cluster 0x0028, revision: 6

      # Matter 1.6's data model revision is independent of a product's
      # certification version. An uncertified device reports zero for the
      # latter until its application supplies the version it was certified for.
      DATA_MODEL_REVISION_1_6           =         21_u16
      MATTER_1_6_SPECIFICATION_VERSION  = 0x01060000_u32
      UNSPECIFIED_SPECIFICATION_VERSION =          0_u32
      DEFAULT_MAX_PATHS_PER_INVOKE      =          1_u16
      INITIAL_CONFIGURATION_VERSION     =          1_u32

      # Mandatory identity names and NodeLabel are at most 32 bytes; Location
      # is an ISO 3166-1 alpha-2 code (two ASCII letters, or "XX" if unknown).
      VENDOR_NAME_MAX_LENGTH   = 32
      PRODUCT_NAME_MAX_LENGTH  = 32
      NODE_LABEL_MAX_LENGTH    = 32
      LOCATION_LENGTH          =  2
      LOCATION_UNKNOWN         = "XX"
      VERSION_STRING_MIN_BYTES =  1
      VERSION_STRING_MAX_BYTES = 64

      # Product Finish enum
      enum ProductFinish : UInt8
        Other    = 0
        Matte    = 1
        Satin    = 2
        Polished = 3
        Rugged   = 4
        Fabric   = 5
      end

      # Color enum
      enum Color : UInt8
        Black   =  0
        Navy    =  1
        Green   =  2
        Teal    =  3
        Maroon  =  4
        Purple  =  5
        Olive   =  6
        Gray    =  7
        Blue    =  8
        Lime    =  9
        Aqua    = 10
        Red     = 11
        Fuchsia = 12
        Yellow  = 13
        White   = 14
        Nickel  = 15
        Chrome  = 16
        Brass   = 17
        Copper  = 18
        Silver  = 19
        Gold    = 20
      end

      # Product Appearance Structure
      struct ProductAppearanceStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property finish : ProductFinish

        @[TLV::Field(tag: 1)]
        property primary_color : Color?

        def initialize(@finish : ProductFinish, @primary_color : Color? = nil)
        end
      end

      # Capability Minima Structure
      struct CapabilityMinimaStruct
        include TLV::Serializable

        MIN_CASE_SESSIONS_PER_FABRIC =      3_u16
        MIN_SUBSCRIPTIONS_PER_FABRIC =      3_u16
        MIN_SIMULTANEOUS_INVOCATIONS =      1_u16
        MIN_SIMULTANEOUS_WRITES      =      1_u16
        MIN_READ_PATHS               =      9_u16
        MIN_SUBSCRIBE_PATHS          =      3_u16
        MAX_CAPABILITY_COUNT         = 10_000_u16

        @[TLV::Field(tag: 0)]
        property case_sessions_per_fabric : UInt16

        @[TLV::Field(tag: 1)]
        property subscriptions_per_fabric : UInt16

        @[TLV::Field(tag: 2)]
        property simultaneous_invocations_supported : UInt16

        @[TLV::Field(tag: 3)]
        property simultaneous_writes_supported : UInt16

        @[TLV::Field(tag: 4)]
        property read_paths_supported : UInt16

        @[TLV::Field(tag: 5)]
        property subscribe_paths_supported : UInt16

        def initialize(@case_sessions_per_fabric : UInt16 = MIN_CASE_SESSIONS_PER_FABRIC,
                       @subscriptions_per_fabric : UInt16 = MIN_SUBSCRIPTIONS_PER_FABRIC,
                       @simultaneous_invocations_supported : UInt16 = MIN_SIMULTANEOUS_INVOCATIONS,
                       @simultaneous_writes_supported : UInt16 = MIN_SIMULTANEOUS_WRITES,
                       @read_paths_supported : UInt16 = MIN_READ_PATHS,
                       @subscribe_paths_supported : UInt16 = MIN_SUBSCRIBE_PATHS)
          validate!
        end

        def validate! : Nil
          validate_count(@case_sessions_per_fabric, MIN_CASE_SESSIONS_PER_FABRIC, "CaseSessionsPerFabric")
          validate_count(@subscriptions_per_fabric, MIN_SUBSCRIPTIONS_PER_FABRIC, "SubscriptionsPerFabric")
          validate_count(@simultaneous_invocations_supported, MIN_SIMULTANEOUS_INVOCATIONS, "SimultaneousInvocationsSupported")
          validate_count(@simultaneous_writes_supported, MIN_SIMULTANEOUS_WRITES, "SimultaneousWritesSupported")
          validate_count(@read_paths_supported, MIN_READ_PATHS, "ReadPathsSupported")
          validate_count(@subscribe_paths_supported, MIN_SUBSCRIBE_PATHS, "SubscribePathsSupported")
        end

        private def validate_count(value : UInt16, minimum : UInt16, name : String) : Nil
          return if value >= minimum && value <= MAX_CAPABILITY_COUNT
          raise Matter::ConfigurationError.new("#{name} must be between #{minimum} and #{MAX_CAPABILITY_COUNT}")
        end
      end

      # Event structures
      struct StartUpEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property software_version : UInt32

        def initialize(@software_version : UInt32)
        end
      end

      struct LeaveEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property fabric_index : UInt8

        def initialize(@fabric_index : UInt8)
        end
      end

      struct ShutDownEvent
        include TLV::Serializable

        # ShutDown event has no fields
        def initialize
        end
      end

      struct ReachableChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property? reachable_new_value : Bool

        def initialize(@reachable_new_value : Bool)
        end
      end

      attribute 0x0000, :data_model_revision, UInt16, default: DATA_MODEL_REVISION_1_6, fixed: true
      attribute 0x0001, :vendor_name, String, default: "", fixed: true,
        max_length: VENDOR_NAME_MAX_LENGTH, validate: :validate_vendor_name!
      attribute 0x0002, :vendor_id, UInt16, default: 0_u16, fixed: true
      attribute 0x0003, :product_name, String, default: "", fixed: true,
        max_length: PRODUCT_NAME_MAX_LENGTH, validate: :validate_product_name!
      attribute 0x0004, :product_id, UInt16, default: 0_u16, fixed: true
      attribute 0x0005, :node_label, String, default: "", writable: true, write_access: :manage,
        max_length: NODE_LABEL_MAX_LENGTH, validate: :validate_node_label!
      attribute 0x0006, :location, String, default: LOCATION_UNKNOWN, writable: true, write_access: :administer
      attribute 0x0007, :hardware_version, UInt16, default: 0_u16, fixed: true
      attribute 0x0008, :hardware_version_string, String, default: "1.0", fixed: true,
        validate: :validate_hardware_version_string!
      attribute 0x0009, :software_version, UInt32, default: 0_u32, fixed: true
      attribute 0x000A, :software_version_string, String, default: "1.0.0", fixed: true,
        validate: :validate_software_version_string!
      attribute 0x000B, :manufacturing_date, String, default: "", fixed: true, optional: true
      attribute 0x000C, :part_number, String, default: "", fixed: true, optional: true
      attribute 0x000D, :product_url, String, default: "", fixed: true, optional: true
      attribute 0x000E, :product_label, String, default: "", fixed: true, optional: true
      attribute 0x000F, :serial_number, String, default: "", fixed: true, optional: true
      attribute 0x0010, :local_config_disabled, Bool, default: false, writable: true, write_access: :manage, optional: true
      attribute 0x0011, :reachable, Bool, default: true, optional: true, on_change: :emit_reachable_changed_on_change
      attribute 0x0012, :unique_id, String, default: "", fixed: true
      attribute 0x0013, :capability_minima, CapabilityMinimaStruct, default: CapabilityMinimaStruct.new, fixed: true
      attribute 0x0014, :product_appearance, ProductAppearanceStruct, nullable: true, fixed: true, optional: true, present_if: :product_appearance
      attribute 0x0015, :specification_version, UInt32, default: UNSPECIFIED_SPECIFICATION_VERSION, fixed: true
      attribute 0x0016, :max_paths_per_invoke, UInt16, default: DEFAULT_MAX_PATHS_PER_INVOKE, fixed: true
      attribute 0x0018, :configuration_version, UInt32, default: INITIAL_CONFIGURATION_VERSION,
        persist: true, persist_default: INITIAL_CONFIGURATION_VERSION

      # Location is validated as a country code and stored upper case.
      before_write :location do |code|
        valid_location?(code) ? code.upcase : InteractionModel::Status.constraint_error
      end

      event 0x00, :start_up, priority: :critical
      event 0x01, :shut_down, priority: :critical
      event 0x02, :leave, priority: :info
      event 0x03, :reachable_changed, priority: :info

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @data_model_revision : UInt16 = DATA_MODEL_REVISION_1_6,
                     @vendor_name : String = "",
                     @vendor_id : UInt16 = 0_u16,
                     @product_name : String = "",
                     @product_id : UInt16 = 0_u16,
                     node_label : String? = nil,
                     @location : String = LOCATION_UNKNOWN,
                     @hardware_version : UInt16 = 0_u16,
                     @hardware_version_string : String = "1.0",
                     @software_version : UInt32 = 0_u32,
                     @software_version_string : String = "1.0.0",
                     @manufacturing_date : String = "",
                     @part_number : String = "",
                     @product_url : String = "",
                     product_label : String? = nil,
                     @serial_number : String = "",
                     @local_config_disabled : Bool = false,
                     @reachable : Bool = true,
                     @unique_id : String = "",
                     @capability_minima : CapabilityMinimaStruct = CapabilityMinimaStruct.new,
                     @product_appearance : ProductAppearanceStruct? = nil,
                     @specification_version : UInt32 = UNSPECIFIED_SPECIFICATION_VERSION,
                     @max_paths_per_invoke : UInt16 = DEFAULT_MAX_PATHS_PER_INVOKE,
                     @configuration_version : UInt32 = INITIAL_CONFIGURATION_VERSION)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise Matter::ConfigurationError.new("MaxPathsPerInvoke must be positive") if @max_paths_per_invoke == 0_u16
        raise Matter::ConfigurationError.new("ConfigurationVersion must be positive") if @configuration_version == 0_u32
        @capability_minima.validate!
        validate_vendor_name!(@vendor_name)
        validate_product_name!(@product_name)
        validate_version_string!(@hardware_version_string, "HardwareVersionString")
        validate_version_string!(@software_version_string, "SoftwareVersionString")

        # Default node_label to product_name if not explicitly set
        # This ensures iOS/controllers show a meaningful device name
        configured_node_label = node_label || @product_name
        validate_node_label!(configured_node_label)
        @node_label = configured_node_label

        # Default product_label to product_name if not explicitly set
        @product_label = product_label || @product_name
      end

      # A lower value cannot describe a newer configuration. The uint32 wrap
      # restarts at the first valid version.
      def configuration_version=(value : UInt32) : Nil
        if value == 0_u32 || (value < @configuration_version && !(@configuration_version == UInt32::MAX && value == INITIAL_CONFIGURATION_VERSION))
          raise Matter::ConfigurationError.new("ConfigurationVersion must advance or wrap to one")
        end
        previous_def(value)
      end

      def capability_minima=(value : CapabilityMinimaStruct) : Nil
        value.validate!
        previous_def(value)
      end

      def self.next_configuration_version(current : UInt32) : UInt32
        current == UInt32::MAX ? INITIAL_CONFIGURATION_VERSION : current + 1_u32
      end

      # Advance once after a successful logical configuration change.
      def increase_configuration_version(&) : Nil
        yield
        increase_configuration_version
      end

      def increase_configuration_version : Nil
        self.configuration_version = BasicInformation.next_configuration_version(@configuration_version)
      end

      private def after_restore_state : Nil
        self.configuration_version = INITIAL_CONFIGURATION_VERSION if @configuration_version == 0_u32
      end

      private def valid_location?(code : String) : Bool
        code.size == LOCATION_LENGTH && (code == LOCATION_UNKNOWN || code.chars.all?(&.ascii_letter?))
      end

      private def validate_node_label!(label : String) : Nil
        return if label.bytesize <= NODE_LABEL_MAX_LENGTH

        raise Matter::ConfigurationError.new("NodeLabel must be at most #{NODE_LABEL_MAX_LENGTH} bytes")
      end

      private def validate_vendor_name!(name : String) : Nil
        return if name.bytesize <= VENDOR_NAME_MAX_LENGTH

        raise Matter::ConfigurationError.new("VendorName must be at most #{VENDOR_NAME_MAX_LENGTH} bytes")
      end

      private def validate_product_name!(name : String) : Nil
        return if name.bytesize <= PRODUCT_NAME_MAX_LENGTH

        raise Matter::ConfigurationError.new("ProductName must be at most #{PRODUCT_NAME_MAX_LENGTH} bytes")
      end

      private def validate_version_string!(value : String, name : String) : Nil
        bytes = value.bytesize
        return if value.valid_encoding? && VERSION_STRING_MIN_BYTES <= bytes <= VERSION_STRING_MAX_BYTES

        raise Matter::ConfigurationError.new("#{name} must contain #{VERSION_STRING_MIN_BYTES}-#{VERSION_STRING_MAX_BYTES} UTF-8 bytes")
      end

      private def validate_hardware_version_string!(value : String) : Nil
        validate_version_string!(value, "HardwareVersionString")
      end

      private def validate_software_version_string!(value : String) : Nil
        validate_version_string!(value, "SoftwareVersionString")
      end

      # Journals the StartUp event (call when the node boots) and returns its
      # encoded body.
      def emit_start_up_event(software_version : UInt32) : Bytes
        payload = StartUpEvent.new(software_version)
        emit_event(EVENT_START_UP, payload)
        payload.to_slice
      end

      # Journals the ShutDown event (call when the node shuts down).
      def emit_shut_down_event : Bytes
        payload = ShutDownEvent.new
        emit_event(EVENT_SHUT_DOWN, payload)
        payload.to_slice
      end

      # Journals the Leave event (call when a fabric is removed). The event is
      # scoped to the fabric that left.
      def emit_leave_event(fabric_index : UInt8) : Bytes
        payload = LeaveEvent.new(fabric_index)
        emit_event(EVENT_LEAVE, payload, fabric_index)
        payload.to_slice
      end

      # Updates reachability and returns the event payload. The setter journals
      # the event only when the value actually changes.
      def emit_reachable_changed_event(reachable_new_value : Bool) : Bytes
        self.reachable = reachable_new_value
        ReachableChangedEvent.new(reachable_new_value).to_slice
      end

      private def emit_reachable_changed_on_change(reachable_new_value : Bool) : Nil
        emit_event(EVENT_REACHABLE_CHANGED, ReachableChangedEvent.new(reachable_new_value))
      end
    end
  end
end
