require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Switch: a device-facing source of position and press events.
    class Switch < Base
      cluster 0x003B, revision: 2

      feature :latching_switch, bit: 0
      feature :momentary_switch, bit: 1
      feature :momentary_switch_release, bit: 2
      feature :momentary_switch_long_press, bit: 3
      feature :momentary_switch_multi_press, bit: 4
      feature :action_switch, bit: 5
      conflicts :latching_switch, :momentary_switch

      struct PositionEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property position : UInt8

        def initialize(@position : UInt8)
        end
      end

      struct MultiPressOngoingEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property new_position : UInt8

        @[TLV::Field(tag: 1)]
        property current_number_of_presses_counted : UInt8

        def initialize(@new_position : UInt8, @current_number_of_presses_counted : UInt8)
        end
      end

      struct MultiPressCompleteEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property previous_position : UInt8

        @[TLV::Field(tag: 1)]
        property total_number_of_presses_counted : UInt8

        def initialize(@previous_position : UInt8, @total_number_of_presses_counted : UInt8)
        end
      end

      attribute 0x0000, :number_of_positions, UInt8, default: 2_u8, fixed: true, min: 2
      attribute 0x0001, :current_position, UInt8, default: 0_u8, persist: true
      attribute 0x0002, :multi_press_max, UInt8, default: 2_u8, fixed: true,
        requires: :momentary_switch_multi_press, min: 2

      event 0x00, :switch_latched, priority: :info, requires: :latching_switch,
        payload: PositionEvent
      event 0x01, :initial_press, priority: :info, requires: :momentary_switch,
        payload: PositionEvent
      event 0x02, :long_press, priority: :info, requires: :momentary_switch_long_press,
        payload: PositionEvent
      event 0x03, :short_release, priority: :info, requires: :momentary_switch_release,
        payload: PositionEvent
      event 0x04, :long_release, priority: :info, requires: :momentary_switch_long_press,
        payload: PositionEvent
      event 0x05, :multi_press_ongoing, priority: :info,
        requires: {momentary_switch_multi_press: true, action_switch: false},
        payload: MultiPressOngoingEvent
      event 0x06, :multi_press_complete, priority: :info,
        requires: :momentary_switch_multi_press, payload: MultiPressCompleteEvent

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::LatchingSwitch,
                     @number_of_positions : UInt8 = 2_u8,
                     @current_position : UInt8 = 0_u8,
                     @multi_press_max : UInt8 = 2_u8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("switch requires at least two positions") if @number_of_positions < 2
        validate_position!(@current_position)
        if @feature_map.momentary_switch_multi_press? && @multi_press_max < 2
          raise ArgumentError.new("multi_press_max must be at least two")
        end
        validate_features!
      end

      def latch(position : UInt8) : Nil
        require_feature!(@feature_map.latching_switch?, "latching switch")
        update_position(position, EVENT_SWITCH_LATCHED)
      end

      def initial_press(position : UInt8) : Nil
        require_feature!(@feature_map.momentary_switch?, "momentary switch")
        update_position(position, EVENT_INITIAL_PRESS)
      end

      def long_press(position : UInt8) : Nil
        require_feature!(@feature_map.momentary_switch_long_press?, "long press")
        validate_position!(position)
        emit_event(EVENT_LONG_PRESS, PositionEvent.new(position))
      end

      def short_release(position : UInt8) : Nil
        require_feature!(@feature_map.momentary_switch_release?, "short release")
        update_position(position, EVENT_SHORT_RELEASE)
      end

      def long_release(position : UInt8) : Nil
        require_feature!(@feature_map.momentary_switch_long_press?, "long release")
        update_position(position, EVENT_LONG_RELEASE)
      end

      def multi_press_ongoing(position : UInt8, presses : UInt8) : Nil
        require_feature!(@feature_map.momentary_switch_multi_press? && !@feature_map.action_switch?,
          "multi press ongoing")
        validate_position!(position)
        validate_press_count!(presses, minimum: 2_u8)
        emit_event(EVENT_MULTI_PRESS_ONGOING, MultiPressOngoingEvent.new(position, presses))
      end

      def multi_press_complete(position : UInt8, presses : UInt8) : Nil
        require_feature!(@feature_map.momentary_switch_multi_press?, "multi press complete")
        validate_position!(position)
        validate_press_count!(presses, minimum: 0_u8)
        emit_event(EVENT_MULTI_PRESS_COMPLETE, MultiPressCompleteEvent.new(position, presses))
      end

      private def update_position(position : UInt8, event_id : UInt32) : Nil
        validate_position!(position)
        self.current_position = position
        emit_event(event_id, PositionEvent.new(position))
      end

      private def validate_position!(position : UInt8) : Nil
        raise ArgumentError.new("switch position exceeds NumberOfPositions") if position >= @number_of_positions
      end

      private def validate_press_count!(presses : UInt8, minimum : UInt8) : Nil
        if presses < minimum || presses > @multi_press_max
          raise ArgumentError.new("switch press count exceeds MultiPressMax")
        end
      end

      private def require_feature!(enabled : Bool, name : String) : Nil
        raise ArgumentError.new("#{name} feature is disabled") unless enabled
      end

      private def validate_features! : Nil
        latching = @feature_map.latching_switch?
        momentary = @feature_map.momentary_switch?
        raise ArgumentError.new("switch requires exactly one of LS or MS") if latching == momentary
        dependent = @feature_map.momentary_switch_release? ||
                    @feature_map.momentary_switch_long_press? ||
                    @feature_map.momentary_switch_multi_press? || @feature_map.action_switch?
        raise ArgumentError.new("momentary switch features require MS") if dependent && !momentary
        if @feature_map.momentary_switch_long_press? &&
           !(@feature_map.momentary_switch_release? || @feature_map.action_switch?)
          raise ArgumentError.new("long press requires release or action switch")
        end
        if @feature_map.action_switch? && !@feature_map.momentary_switch_multi_press?
          raise ArgumentError.new("action switch requires multi press")
        end
        if @feature_map.momentary_switch_multi_press? && !@feature_map.action_switch? &&
           !@feature_map.momentary_switch_release?
          raise ArgumentError.new("multi press requires release unless ActionSwitch is enabled")
        end
      end
    end
  end
end
