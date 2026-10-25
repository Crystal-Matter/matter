require "./cluster"
require "./basic_information"
require "tlv"

module Matter
  module Cluster
    # Bridged Device Basic Information Cluster Implementation (0x0039)
    # Provides information about a bridged device from another ecosystem.
    #
    # Required on each bridged endpoint in a bridge device.
    # The bridge populates this with information from the original device.
    #
    # Matter Spec: Core 9.13
    class BridgedDeviceBasicInformation < Base
      cluster 0x0039, revision: 6

      feature :bridged_icd_support, bit: 20

      NODE_LABEL_MAX_LENGTH      =            32
      UNIQUE_ID_MAX_LENGTH       =            32
      MIN_KEEP_ACTIVE_TIMEOUT_MS =    30_000_u32
      MAX_KEEP_ACTIVE_TIMEOUT_MS = 3_600_000_u32

      # Reuse enums and structs from BasicInformation
      alias ProductFinish = BasicInformation::ProductFinish
      alias Color = BasicInformation::Color
      alias ProductAppearanceStruct = BasicInformation::ProductAppearanceStruct

      # Event structures
      struct StartUpEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property software_version : UInt32

        def initialize(@software_version : UInt32)
        end
      end

      struct ShutDownEvent
        include TLV::Serializable

        def initialize
        end
      end

      struct LeaveEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property fabric_index : UInt8

        def initialize(@fabric_index : UInt8)
        end
      end

      struct ReachableChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property? reachable_new_value : Bool

        def initialize(@reachable_new_value : Bool)
        end
      end

      struct KeepActiveRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter stay_active_duration : UInt32

        @[TLV::Field(tag: 1)]
        getter timeout_ms : UInt32

        def initialize(@stay_active_duration : UInt32, @timeout_ms : UInt32)
        end
      end

      struct ActiveChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter promised_active_duration : UInt32

        def initialize(@promised_active_duration : UInt32)
        end
      end

      # Optional attributes are present exactly when the bridge supplied a
      # value. UniqueID is required from revision 4 onward and identifies the
      # same bridged device across bridge restarts.
      attribute 0x0001, :vendor_name, String, nullable: true, fixed: true, optional: true, present_if: :vendor_name
      attribute 0x0002, :vendor_id, UInt16, nullable: true, fixed: true, optional: true, present_if: :vendor_id
      attribute 0x0003, :product_name, String, nullable: true, fixed: true, optional: true, present_if: :product_name
      attribute 0x0004, :product_id, UInt16, nullable: true, fixed: true, optional: true, present_if: :product_id
      attribute 0x0005, :node_label, String, default: "", writable: true, write_access: :manage, max_length: NODE_LABEL_MAX_LENGTH
      attribute 0x0007, :hardware_version, UInt16, nullable: true, fixed: true, optional: true, present_if: :hardware_version
      attribute 0x0008, :hardware_version_string, String, nullable: true, fixed: true, optional: true, present_if: :hardware_version_string
      attribute 0x0009, :software_version, UInt32, nullable: true, fixed: true, optional: true, present_if: :software_version
      attribute 0x000A, :software_version_string, String, nullable: true, fixed: true, optional: true, present_if: :software_version_string
      attribute 0x000B, :manufacturing_date, String, nullable: true, fixed: true, optional: true, present_if: :manufacturing_date
      attribute 0x000C, :part_number, String, nullable: true, fixed: true, optional: true, present_if: :part_number
      attribute 0x000D, :product_url, String, nullable: true, fixed: true, optional: true, present_if: :product_url
      attribute 0x000E, :product_label, String, nullable: true, fixed: true, optional: true, present_if: :product_label
      attribute 0x000F, :serial_number, String, nullable: true, fixed: true, optional: true, present_if: :serial_number
      attribute 0x0011, :reachable, Bool, default: true, persist: true, callback: :new_only
      attribute 0x0012, :unique_id, String, default: "", fixed: true, max_length: UNIQUE_ID_MAX_LENGTH
      attribute 0x0014, :product_appearance, ProductAppearanceStruct, nullable: true, fixed: true, optional: true, present_if: :product_appearance
      attribute 0x0018, :configuration_version, UInt32, nullable: true, optional: true,
        present_if: :configuration_version, persist: true, min: 1_u32

      command 0x80, :keep_active, request: KeepActiveRequest, access: :operate,
        requires: :bridged_icd_support

      event 0x00, :start_up, priority: :critical
      event 0x01, :shut_down, priority: :critical
      event 0x02, :leave, priority: :info
      event 0x03, :reachable_changed, priority: :info
      event 0x80, :active_changed, priority: :info, requires: :bridged_icd_support,
        payload: ActiveChangedEvent

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @reachable : Bool = true,
        @vendor_name : String? = nil,
        @vendor_id : UInt16? = nil,
        @product_name : String? = nil,
        @product_id : UInt16? = nil,
        node_label : String? = nil,
        @hardware_version : UInt16? = nil,
        @hardware_version_string : String? = nil,
        @software_version : UInt32? = nil,
        @software_version_string : String? = nil,
        @manufacturing_date : String? = nil,
        @part_number : String? = nil,
        @product_url : String? = nil,
        @product_label : String? = nil,
        @serial_number : String? = nil,
        @unique_id : String = "",
        @product_appearance : ProductAppearanceStruct? = nil,
        @configuration_version : UInt32? = nil,
        @keep_active_adapter : Proc(UInt32, UInt32?)? = nil,
        @monotonic_clock : Proc(Time::Instant) = -> { Time.instant },
      )
        unless (1..UNIQUE_ID_MAX_LENGTH).includes?(@unique_id.bytesize)
          raise ArgumentError.new("unique_id must be 1..#{UNIQUE_ID_MAX_LENGTH} bytes")
        end
        if @configuration_version == 0_u32
          raise Matter::ConfigurationError.new("ConfigurationVersion must be positive")
        end
        @feature_map = @keep_active_adapter ? Feature::BridgedIcdSupport : Feature::None
        @pending_stay_active_duration = nil.as(UInt32?)
        @pending_active_deadline = nil.as(Time::Instant?)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @node_label = node_label || ""
      end

      # The BIS feature must reflect a real bridge host implementation.
      protected def validate_feature_map_change(value : Feature) : Nil
        expected = @keep_active_adapter ? Feature::BridgedIcdSupport : Feature::None
        unless value == expected
          raise ConfigurationError.new("BridgedICDSupport requires a keep-active adapter")
        end
      end

      # Records a pending request. TimeoutMs is the time to wait for the next
      # activation, not the amount of time the external device stays awake.
      def keep_active(request : KeepActiveRequest) : InteractionModel::Status
        return InteractionModel::Status.unsupported_command unless @keep_active_adapter
        unless request.timeout_ms.in?(MIN_KEEP_ACTIVE_TIMEOUT_MS..MAX_KEEP_ACTIVE_TIMEOUT_MS)
          return InteractionModel::Status.constraint_error
        end

        now = @monotonic_clock.call
        deadline = now + request.timeout_ms.milliseconds
        if prior_deadline = @pending_active_deadline
          if prior_deadline > now
            deadline = prior_deadline if prior_deadline > deadline
            prior_duration = @pending_stay_active_duration
            if prior_duration && prior_duration > request.stay_active_duration
              @pending_stay_active_duration = prior_duration
            else
              @pending_stay_active_duration = request.stay_active_duration
            end
          else
            @pending_stay_active_duration = request.stay_active_duration
          end
        else
          @pending_stay_active_duration = request.stay_active_duration
        end
        @pending_active_deadline = deadline
        InteractionModel::Status.success
      end

      # The bridge host calls this only after observing a real external device
      # activation (for Matter ICDs, on its check-in or subscription report).
      # The adapter sends StayActiveRequest or equivalent and returns the
      # confirmed promised duration, or nil when it cannot confirm a promise.
      # An event is never emitted for a failed or expired request.
      def bridged_device_became_active : UInt32?
        adapter = @keep_active_adapter
        duration = @pending_stay_active_duration
        deadline = @pending_active_deadline
        return unless adapter && duration && deadline
        if @monotonic_clock.call >= deadline
          @pending_stay_active_duration = nil
          @pending_active_deadline = nil
          return
        end

        promised = adapter.call(duration)
        return unless promised

        @pending_stay_active_duration = nil
        @pending_active_deadline = nil
        emit_event(EVENT_ACTIVE_CHANGED, ActiveChangedEvent.new(promised))
        promised
      end

      def configuration_version=(value : UInt32?) : Nil
        current = @configuration_version
        if current && !value
          raise Matter::ConfigurationError.new("ConfigurationVersion cannot be removed after provisioning")
        end
        if value && (value == 0_u32 || (current && value < current && !(current == UInt32::MAX && value == 1_u32)))
          raise Matter::ConfigurationError.new("ConfigurationVersion must advance or wrap to one")
        end
        previous_def(value)
      end

      # A bridge decides which external changes alter a bridged device's
      # configuration. The attribute is optional, so a caller must provision
      # it before advancing the version. The parent bridge version is advanced
      # by Device#increase_bridged_configuration_version.
      def increase_configuration_version(&) : Nil
        require_configuration_version
        yield
        increase_configuration_version
      end

      def increase_configuration_version : Nil
        current = require_configuration_version
        self.configuration_version = current == UInt32::MAX ? 1_u32 : current + 1_u32
      end

      private def require_configuration_version : UInt32
        @configuration_version || raise Matter::ConfigurationError.new("ConfigurationVersion is not enabled for this bridged device")
      end

      # Journals the StartUp event and returns its encoded body.
      def emit_start_up_event(software_version : UInt32) : Bytes
        payload = StartUpEvent.new(software_version)
        emit_event(EVENT_START_UP, payload)
        payload.to_slice
      end

      # Journals the ShutDown event.
      def emit_shut_down_event : Bytes
        payload = ShutDownEvent.new
        emit_event(EVENT_SHUT_DOWN, payload)
        payload.to_slice
      end

      # Journals the Leave event, scoped to the fabric that left.
      def emit_leave_event(fabric_index : UInt8) : Bytes
        payload = LeaveEvent.new(fabric_index)
        emit_event(EVENT_LEAVE, payload, fabric_index)
        payload.to_slice
      end

      # Journals the ReachableChanged event and updates `reachable`.
      def emit_reachable_changed_event(reachable_new_value : Bool) : Bytes
        self.reachable = reachable_new_value

        payload = ReachableChangedEvent.new(reachable_new_value)
        emit_event(EVENT_REACHABLE_CHANGED, payload)
        payload.to_slice
      end
    end
  end
end
