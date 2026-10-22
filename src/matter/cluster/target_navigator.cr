require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Target Navigator server (0x0505, revision 2). The application
    # supplies the available targets and performs navigation in its callback.
    class TargetNavigator < Base
      cluster 0x0505, revision: 2

      NO_CURRENT_TARGET = 255_u8
      MAX_TARGET_ID     = 254_u8
      MAX_TARGETS       =    255
      MAX_EVENT_DATA    =    900

      enum Status : UInt8
        Success
        TargetNotFound
        NotAllowed
      end

      struct TargetInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter identifier : UInt8

        @[TLV::Field(tag: 1)]
        getter name : String

        def initialize(@identifier : UInt8, @name : String)
          raise ArgumentError.new("target identifier must be at most #{MAX_TARGET_ID}") if @identifier > MAX_TARGET_ID
        end
      end

      struct NavigateTargetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter target : UInt8

        @[TLV::Field(tag: 1, optional: true)]
        getter data : String?

        def initialize(@target : UInt8, @data : String? = nil)
        end
      end

      struct NavigateTargetResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : Status

        @[TLV::Field(tag: 1, optional: true)]
        getter data : String?

        def initialize(@status : Status, @data : String? = nil)
        end
      end

      struct TargetUpdatedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter target_list : Array(TargetInfo)?

        @[TLV::Field(tag: 1, optional: true)]
        getter current_target : UInt8?

        @[TLV::Field(tag: 2, optional: true)]
        getter data : Bytes?

        def initialize(@target_list : Array(TargetInfo)? = nil, @current_target : UInt8? = nil,
                       @data : Bytes? = nil)
          if @data && @data.as(Bytes).size > MAX_EVENT_DATA
            raise ArgumentError.new("TargetUpdated data exceeds #{MAX_EVENT_DATA} bytes")
          end
          @target_list = @target_list.try(&.dup)
          @data = @data.try(&.dup)
        end
      end

      record NavigationResult, status : Status, data : String? = nil

      alias NavigateCallback = Proc(TargetInfo, String?, NavigationResult)

      attribute 0x0000, :target_list, Array(TargetInfo), computed: true
      attribute 0x0001, :current_target, UInt8, optional: true,
        computed: true, present_if: :current_target_present?

      command 0x00, :navigate_target, request: NavigateTargetRequest,
        response: NavigateTargetResponse, response_id: 0x01, access: :operate

      event 0x00, :target_updated, priority: :info, payload: TargetUpdatedEvent

      def initialize(endpoint_id : DataType::EndpointNumber,
                     target_list : Array(TargetInfo) = [] of TargetInfo,
                     current_target : UInt8? = nil)
        validate_targets!(target_list)
        if current_target && current_target != NO_CURRENT_TARGET && !target_list.any? { |target| target.identifier == current_target }
          raise ArgumentError.new("current target is not in TargetList")
        end
        @target_list = target_list.dup
        @current_target = current_target || NO_CURRENT_TARGET
        @has_current_target = !current_target.nil?
        @navigate_callback = nil
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def target_list : Array(TargetInfo)
        @target_list.dup
      end

      def current_target : UInt8
        @current_target
      end

      def on_navigate(&block : TargetInfo, String? -> NavigationResult) : Nil
        @navigate_callback = block
      end

      def navigate_target(request : NavigateTargetRequest) : NavigateTargetResponse
        target = @target_list.find { |entry| entry.identifier == request.target }
        return NavigateTargetResponse.new(Status::TargetNotFound) unless target
        callback = @navigate_callback
        return NavigateTargetResponse.new(Status::NotAllowed) unless callback

        result = callback.call(target, request.data)
        report_current_target(target.identifier) if result.status.success? && @has_current_target
        NavigateTargetResponse.new(result.status, result.data)
      end

      # A local application change may replace the menu. If the selected item
      # disappears, the optional CurrentTarget reads its 0xFF sentinel.
      def update_targets(targets : Array(TargetInfo), data : Bytes? = nil) : Nil
        validate_targets!(targets)
        validate_event_data!(data)
        return if @target_list == targets
        @target_list = targets.dup
        increment_version_and_notify(ATTR_TARGET_LIST)
        current_changed = @has_current_target && @current_target != NO_CURRENT_TARGET &&
                          !targets.any? { |target| target.identifier == @current_target }
        if current_changed
          @current_target = NO_CURRENT_TARGET
          increment_version_and_notify(ATTR_CURRENT_TARGET)
        end
        emit_target_updated(TargetUpdatedEvent.new(targets, current_changed ? NO_CURRENT_TARGET : nil, data))
      end

      def report_current_target(target : UInt8, data : Bytes? = nil) : Nil
        raise ArgumentError.new("CurrentTarget is not exposed") unless @has_current_target
        validate_event_data!(data)
        if target != NO_CURRENT_TARGET && !@target_list.any? { |entry| entry.identifier == target }
          raise ArgumentError.new("current target is not in TargetList")
        end
        return if @current_target == target
        @current_target = target
        increment_version_and_notify(ATTR_CURRENT_TARGET)
        emit_target_updated(TargetUpdatedEvent.new(current_target: target, data: data))
      end

      private def current_target_present? : Bool
        @has_current_target
      end

      private def validate_targets!(targets : Array(TargetInfo)) : Nil
        raise ArgumentError.new("TargetList exceeds #{MAX_TARGETS} entries") if targets.size > MAX_TARGETS
        ids = targets.map(&.identifier)
        raise ArgumentError.new("TargetList contains duplicate identifiers") if ids.uniq.size != ids.size
      end

      private def validate_event_data!(data : Bytes?) : Nil
        if data && data.size > MAX_EVENT_DATA
          raise ArgumentError.new("TargetUpdated data exceeds #{MAX_EVENT_DATA} bytes")
        end
      end
    end
  end
end
