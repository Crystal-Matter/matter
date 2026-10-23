require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Device Energy Management (0x0098), revision 4.
    # This server supports one of the PowerAdjustment, PowerForecastReporting,
    # or StateForecastReporting profiles. The host owns physical operation and
    # supplies forecasts. Adjustment features remain unavailable.
    class DeviceEnergyManagement < Base
      Log = ::Log.for("matter.cluster.device_energy_management")

      cluster 0x0098, revision: 4, persist_state: false

      feature :power_adjustment, bit: 0
      feature :power_forecast_reporting, bit: 1
      feature :state_forecast_reporting, bit: 2
      feature :start_time_adjustment, bit: 3
      feature :pausable, bit: 4
      feature :forecast_adjustment, bit: 5
      feature :constraint_based_adjustment, bit: 6

      MAX_POWER_RANGES           =  8
      MAX_FORECAST_SLOTS         = 10
      MAX_SLOT_COSTS             =  5
      CAPABILITY_REPORT_INTERVAL = 10.seconds
      FORECAST_REPORT_INTERVAL   = 10.seconds

      enum ESAType : UInt8
        EVSE                =   0
        SpaceHeating        =   1
        WaterHeating        =   2
        SpaceCooling        =   3
        SpaceHeatingCooling =   4
        BatteryStorage      =   5
        SolarPV             =   6
        FridgeFreezer       =   7
        WashingMachine      =   8
        Dishwasher          =   9
        Cooking             =  10
        HomeWaterPump       =  11
        IrrigationWaterPump =  12
        PoolPump            =  13
        Other               = 255
      end

      enum ESAState : UInt8
        Offline           = 0
        Online            = 1
        Fault             = 2
        PowerAdjustActive = 3
        Paused            = 4
      end

      enum OptOutState : UInt8
        NoOptOut    = 0
        LocalOptOut = 1
        GridOptOut  = 2
        OptOut      = 3
      end

      enum AdjustmentCause : UInt8
        LocalOptimization = 0
        GridOptimization  = 1
      end

      enum EndCause : UInt8
        NormalCompletion = 0
        Offline          = 1
        Fault            = 2
        UserOptOut       = 3
        Cancelled        = 4
      end

      enum PowerAdjustReason : UInt8
        NoAdjustment                = 0
        LocalOptimizationAdjustment = 1
        GridOptimizationAdjustment  = 2
      end

      enum ForecastUpdateReason : UInt8
        InternalOptimization = 0
        LocalOptimization    = 1
        GridOptimization     = 2
      end

      enum CostType : UInt8
        Financial    = 0
        GHGEmissions = 1
        Comfort      = 2
        Temperature  = 3
      end

      struct Cost
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter cost_type : CostType

        @[TLV::Field(tag: 1)]
        getter value : Int32

        @[TLV::Field(tag: 2)]
        getter decimal_points : UInt8

        @[TLV::Field(tag: 3, optional: true)]
        getter currency : UInt16?

        def initialize(@cost_type : CostType, @value : Int32,
                       @decimal_points : UInt8, @currency : UInt16? = nil)
          raise ArgumentError.new("currency exceeds 999") if @currency.try { |currency| currency > 999_u16 }
        end
      end

      struct Slot
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter min_duration : UInt32
        @[TLV::Field(tag: 1)]
        getter max_duration : UInt32
        @[TLV::Field(tag: 2)]
        getter default_duration : UInt32
        @[TLV::Field(tag: 3)]
        getter elapsed_slot_time : UInt32
        @[TLV::Field(tag: 4)]
        getter remaining_slot_time : UInt32
        @[TLV::Field(tag: 8, optional: true)]
        getter manufacturer_esa_state : UInt16?
        @[TLV::Field(tag: 9, optional: true)]
        getter nominal_power : Int64?
        @[TLV::Field(tag: 10, optional: true)]
        getter min_power : Int64?
        @[TLV::Field(tag: 11, optional: true)]
        getter max_power : Int64?
        @[TLV::Field(tag: 12, optional: true)]
        getter nominal_energy : Int64?
        @[TLV::Field(tag: 13, optional: true)]
        @costs : Array(Cost)?

        def initialize(@min_duration : UInt32, @max_duration : UInt32,
                       @default_duration : UInt32, @elapsed_slot_time : UInt32,
                       @remaining_slot_time : UInt32,
                       @manufacturer_esa_state : UInt16? = nil,
                       @nominal_power : Int64? = nil, @min_power : Int64? = nil,
                       @max_power : Int64? = nil, @nominal_energy : Int64? = nil,
                       costs : Array(Cost)? = nil)
          unless @min_duration <= @default_duration && @default_duration <= @max_duration
            raise ArgumentError.new("slot duration is outside minimum and maximum")
          end
          raise ArgumentError.new("too many slot costs") if costs && costs.size > MAX_SLOT_COSTS
          @costs = costs.try(&.dup)
        end

        def duplicate : Slot
          Slot.new(@min_duration, @max_duration, @default_duration,
            @elapsed_slot_time, @remaining_slot_time, @manufacturer_esa_state,
            @nominal_power, @min_power, @max_power, @nominal_energy, @costs)
        end

        def costs : Array(Cost)?
          @costs.try(&.dup)
        end

        def with_progress(elapsed : UInt32, remaining : UInt32) : Slot
          Slot.new(@min_duration, @max_duration, @default_duration,
            elapsed, remaining, @manufacturer_esa_state,
            @nominal_power, @min_power, @max_power, @nominal_energy, @costs)
        end
      end

      struct Forecast
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter forecast_id : UInt32
        @[TLV::Field(tag: 1)]
        getter active_slot_number : UInt16?
        @[TLV::Field(tag: 2)]
        getter start_time : UInt32
        @[TLV::Field(tag: 3)]
        getter end_time : UInt32
        @[TLV::Field(tag: 6)]
        getter? is_pausable : Bool
        @[TLV::Field(tag: 7)]
        @slots : Array(Slot)
        @[TLV::Field(tag: 8)]
        getter forecast_update_reason : ForecastUpdateReason

        def initialize(@forecast_id : UInt32, @active_slot_number : UInt16?,
                       @start_time : UInt32, @end_time : UInt32,
                       @is_pausable : Bool, slots : Array(Slot),
                       @forecast_update_reason : ForecastUpdateReason)
          raise ArgumentError.new("forecast end precedes start") if @end_time < @start_time
          raise ArgumentError.new("forecast requires 1–10 slots") unless (1..MAX_FORECAST_SLOTS).includes?(slots.size)
          if (active = @active_slot_number) && active >= slots.size
            raise ArgumentError.new("active slot is outside the forecast")
          end
          @slots = slots.map(&.duplicate)
        end

        def duplicate : Forecast
          Forecast.new(@forecast_id, @active_slot_number, @start_time, @end_time,
            @is_pausable, @slots, @forecast_update_reason)
        end

        def slots : Array(Slot)
          @slots.map(&.duplicate)
        end

        def with_slot_progress(index : UInt16, elapsed : UInt32, remaining : UInt32) : Forecast
          updated = @slots.map(&.duplicate)
          updated[index] = updated[index].with_progress(elapsed, remaining)
          Forecast.new(@forecast_id, @active_slot_number, @start_time, @end_time,
            @is_pausable, updated, @forecast_update_reason)
        end
      end

      struct PowerAdjust
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter min_power : Int64

        @[TLV::Field(tag: 1)]
        getter max_power : Int64

        @[TLV::Field(tag: 2)]
        getter min_duration : UInt32

        @[TLV::Field(tag: 3)]
        getter max_duration : UInt32

        def initialize(@min_power : Int64, @max_power : Int64,
                       @min_duration : UInt32, @max_duration : UInt32)
          raise ArgumentError.new("MinPower exceeds MaxPower") if @min_power > @max_power
          raise ArgumentError.new("MinDuration exceeds MaxDuration") if @min_duration > @max_duration
        end
      end

      struct PowerAdjustCapability
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter power_adjustment_capability : Array(PowerAdjust)?

        @[TLV::Field(tag: 1)]
        getter cause : PowerAdjustReason

        def initialize(ranges : Array(PowerAdjust)?, @cause : PowerAdjustReason)
          raise ArgumentError.new("too many power ranges") if ranges && ranges.size > MAX_POWER_RANGES
          @power_adjustment_capability = ranges.try(&.dup)
        end

        def duplicate : PowerAdjustCapability
          PowerAdjustCapability.new(@power_adjustment_capability, @cause)
        end
      end

      struct PowerAdjustRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter power : Int64

        @[TLV::Field(tag: 1)]
        getter duration : UInt32

        @[TLV::Field(tag: 2)]
        getter cause : AdjustmentCause

        def initialize(@power : Int64, @duration : UInt32, @cause : AdjustmentCause)
        end
      end

      struct PowerAdjustStartEvent
        include TLV::Serializable

        def initialize
        end
      end

      struct PowerAdjustEndEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter cause : EndCause

        @[TLV::Field(tag: 1)]
        getter duration : UInt32

        @[TLV::Field(tag: 2)]
        getter energy_use : Int64

        def initialize(@cause : EndCause, @duration : UInt32, @energy_use : Int64)
        end
      end

      attribute 0x0000, :esa_type, ESAType, fixed: true, computed: true
      attribute 0x0001, :esa_can_generate, Bool, fixed: true, computed: true
      attribute 0x0002, :esa_state, ESAState, computed: true
      attribute 0x0003, :abs_min_power, Int64, computed: true
      attribute 0x0004, :abs_max_power, Int64, computed: true
      attribute 0x0005, :power_adjustment_capability, PowerAdjustCapability,
        nullable: true, computed: true, requires: :power_adjustment
      attribute 0x0006, :forecast, Forecast, nullable: true, computed: true,
        requires: [:power_forecast_reporting, :state_forecast_reporting]
      attribute 0x0007, :opt_out_state, OptOutState, computed: true,
        requires: [:power_adjustment, :start_time_adjustment, :pausable,
                   :forecast_adjustment, :constraint_based_adjustment]

      command 0x00, :power_adjust_request, request: PowerAdjustRequest,
        access: :operate, requires: :power_adjustment
      command 0x01, :cancel_power_adjust_request,
        access: :operate, requires: :power_adjustment

      event 0x00, :power_adjust_start, priority: :info,
        payload: PowerAdjustStartEvent, requires: :power_adjustment
      event 0x01, :power_adjust_end, priority: :info,
        payload: PowerAdjustEndEvent, requires: :power_adjustment

      @esa_state : ESAState = ESAState::Online
      @opt_out_state : OptOutState = OptOutState::NoOptOut
      @power_adjustment_capability : PowerAdjustCapability?
      @forecast : Forecast?
      @last_forecast_id : UInt32?
      @last_forecast_report : Time::Instant?
      @active_adjustment : PowerAdjustRequest?
      @active_started : Time::Instant?
      @active_fabric_index : UInt8?
      @active_generation : UInt64 = 0_u64
      @last_capability_report : Time::Instant?
      @power_adjust_callback : Proc(PowerAdjustRequest, UInt8?, InteractionModel::Status)?
      @cancel_callback : Proc(UInt8?, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @esa_type : ESAType,
                     @can_generate : Bool,
                     @abs_min_power : Int64,
                     @abs_max_power : Int64,
                     power_adjustment_capability : PowerAdjustCapability? = nil,
                     @feature_map : Feature = Feature::PowerAdjustment)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map.in?(Feature::PowerAdjustment,
                 Feature::PowerForecastReporting,
                 Feature::StateForecastReporting)
          raise ArgumentError.new("select exactly one supported DEM profile: PA, PFR, or SFR")
        end
        if !@feature_map.power_adjustment? && power_adjustment_capability
          raise ArgumentError.new("power capability requires PA")
        end
        raise ArgumentError.new("AbsMinPower exceeds AbsMaxPower") if @abs_min_power > @abs_max_power
        validate_capability!(power_adjustment_capability)
        if power_adjustment_capability && !power_adjustment_capability.cause.no_adjustment?
          raise ArgumentError.new("initial capability cannot report an active adjustment")
        end
        @power_adjustment_capability = power_adjustment_capability.try(&.duplicate)
      end

      def esa_type : ESAType
        @esa_type
      end

      def esa_can_generate? : Bool
        @can_generate
      end

      def esa_state : ESAState
        @esa_state
      end

      def abs_min_power : Int64
        @abs_min_power
      end

      def abs_max_power : Int64
        @abs_max_power
      end

      def power_adjustment_capability : PowerAdjustCapability?
        @power_adjustment_capability.try(&.duplicate)
      end

      def forecast : Forecast?
        @forecast.try(&.duplicate)
      end

      def opt_out_state : OptOutState
        @opt_out_state
      end

      # The host publishes a new indicative forecast. A repeated ID is not an
      # update; later IDs may wrap at UInt32::MAX. Progress-only changes use
      # report_slot_progress so subscriptions are not flooded each second.
      def report_forecast(value : Forecast?) : Nil
        unless @feature_map.power_forecast_reporting? || @feature_map.state_forecast_reporting?
          raise ArgumentError.new("forecast reporting feature is disabled")
        end
        validate_forecast!(value) if value
        if value && (previous = @last_forecast_id)
          distance = value.forecast_id &- previous
          unless distance > 0_u32 && distance < 0x8000_0000_u32
            raise ArgumentError.new("ForecastID must increase (wrapping is permitted)")
          end
        end
        was_null = @forecast.nil?
        return if value.nil? && was_null
        @forecast = value.try(&.duplicate)
        @last_forecast_id = value.forecast_id if value
        forecast_changed(force_report: was_null != value.nil?)
      end

      # These two values are read live but are expressly excluded from
      # Forecast subscription notifications by the cluster specification.
      def report_slot_progress(index : UInt16, elapsed : UInt32,
                               remaining : UInt32) : Nil
        forecast = @forecast
        raise ArgumentError.new("no active forecast") unless forecast
        raise ArgumentError.new("slot index is outside the forecast") if index >= forecast.slots.size
        @forecast = forecast.with_slot_progress(index, elapsed, remaining)
      end

      def on_power_adjust(&block : PowerAdjustRequest, UInt8? -> InteractionModel::Status) : Nil
        @power_adjust_callback = block
      end

      def on_cancel_power_adjust(&block : UInt8? -> InteractionModel::Status) : Nil
        @cancel_callback = block
      end

      # The host can update its nameplate limits only while all advertised PA
      # ranges still fit within them.
      def report_abs_power_limits(minimum : Int64, maximum : Int64) : Nil
        raise ArgumentError.new("AbsMinPower exceeds AbsMaxPower") if minimum > maximum
        validate_capability!(@power_adjustment_capability, minimum, maximum)
        if current_forecast = @forecast
          validate_forecast!(current_forecast, minimum, maximum)
        end
        if @abs_min_power != minimum
          @abs_min_power = minimum
          increment_version_and_notify(ATTR_ABS_MIN_POWER)
        end
        if @abs_max_power != maximum
          @abs_max_power = maximum
          increment_version_and_notify(ATTR_ABS_MAX_POWER)
        end
      end

      def report_power_adjustment_capability(value : PowerAdjustCapability?) : Nil
        validate_capability!(value)
        expected_cause = if active = @active_adjustment
                           active.cause.local_optimization? ? PowerAdjustReason::LocalOptimizationAdjustment : PowerAdjustReason::GridOptimizationAdjustment
                         else
                           PowerAdjustReason::NoAdjustment
                         end
        if value && value.cause != expected_cause
          raise ArgumentError.new("capability cause disagrees with active adjustment")
        end
        was_null = @power_adjustment_capability.nil?
        if value.nil? && @active_adjustment
          cancel_for_host_change(EndCause::Cancelled)
        end
        @power_adjustment_capability = value.try(&.duplicate)
        capability_changed(force_report: was_null != value.nil?)
      end

      def report_esa_state(state : ESAState) : Nil
        raise ArgumentError.new("host cannot report an active command state") if state.in?(ESAState::PowerAdjustActive, ESAState::Paused)
        if @active_adjustment
          cause = case state
                  when ESAState::Offline then EndCause::Offline
                  when ESAState::Fault   then EndCause::Fault
                  else                        EndCause::NormalCompletion
                  end
          finish_adjustment(cause)
        end
        change_esa_state(state)
      end

      def report_opt_out_state(state : OptOutState) : Nil
        return if @opt_out_state == state
        if (active = @active_adjustment) && opted_out?(state, active.cause)
          cancel_for_host_change(EndCause::UserOptOut)
        end
        @opt_out_state = state
        increment_version_and_notify(ATTR_OPT_OUT_STATE)
      end

      def power_adjust_request(request : PowerAdjustRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state unless @esa_state.in?(ESAState::Online, ESAState::PowerAdjustActive)
        return InteractionModel::Status.invalid_in_state if opted_out?(@opt_out_state, request.cause)
        return InteractionModel::Status.constraint_error unless valid_request?(request)
        callback = @power_adjust_callback
        return InteractionModel::Status.invalid_in_state unless callback && @cancel_callback
        fabric_index = request_fabric_index
        status = callback.call(request, fabric_index)
        return status unless status.success?
        finish_adjustment(EndCause::Cancelled) if @active_adjustment
        @active_adjustment = request
        @active_started = Time.instant
        @active_fabric_index = fabric_index
        @active_generation &+= 1_u64
        change_esa_state(ESAState::PowerAdjustActive)
        change_capability_cause(request.cause.local_optimization? ? PowerAdjustReason::LocalOptimizationAdjustment : PowerAdjustReason::GridOptimizationAdjustment)
        emit_power_adjust_start(PowerAdjustStartEvent.new)
        schedule_expiration(request.duration, @active_generation)
        status
      end

      def cancel_power_adjust_request : InteractionModel::Status
        return InteractionModel::Status.success unless @active_adjustment
        callback = @cancel_callback
        return InteractionModel::Status.invalid_in_state unless callback
        status = callback.call(request_fabric_index)
        finish_adjustment(EndCause::Cancelled) if status.success?
        status
      end

      private def valid_request?(request : PowerAdjustRequest) : Bool
        return false if request.duration.zero?
        capability = @power_adjustment_capability
        ranges = capability.try(&.power_adjustment_capability)
        return false unless ranges
        ranges.any? do |range|
          (range.min_power..range.max_power).includes?(request.power) &&
            (range.min_duration..range.max_duration).includes?(request.duration)
        end
      end

      private def opted_out?(state : OptOutState, cause : AdjustmentCause) : Bool
        state.opt_out? || (cause.local_optimization? && state.local_opt_out?) ||
          (cause.grid_optimization? && state.grid_opt_out?)
      end

      private def validate_capability!(value : PowerAdjustCapability?,
                                       minimum : Int64 = @abs_min_power,
                                       maximum : Int64 = @abs_max_power) : Nil
        return unless value
        if ranges = value.power_adjustment_capability
          raise ArgumentError.new("too many power ranges") if ranges.size > MAX_POWER_RANGES
          ranges.each do |range|
            unless minimum <= range.min_power && range.max_power <= maximum
              raise ArgumentError.new("power range exceeds absolute limits")
            end
          end
        end
      end

      private def validate_forecast!(value : Forecast,
                                     minimum_limit : Int64 = @abs_min_power,
                                     maximum_limit : Int64 = @abs_max_power) : Nil
        raise ArgumentError.new("Pausable forecast requires PAU") if value.is_pausable?
        value.slots.each do |slot|
          if @feature_map.power_forecast_reporting?
            minimum = slot.min_power
            maximum = slot.max_power
            nominal = slot.nominal_power
            unless minimum && maximum && nominal && slot.nominal_energy
              raise ArgumentError.new("PFR slot needs nominal, minimum, maximum power, and energy")
            end
            unless minimum_limit <= minimum && minimum <= nominal &&
                   nominal <= maximum && maximum <= maximum_limit
              raise ArgumentError.new("PFR slot power exceeds nameplate or slot range")
            end
            raise ArgumentError.new("PFR slot cannot contain manufacturer state") if slot.manufacturer_esa_state
          else
            raise ArgumentError.new("SFR slot needs manufacturer state") unless slot.manufacturer_esa_state
            if slot.nominal_power || slot.min_power || slot.max_power || slot.nominal_energy
              raise ArgumentError.new("SFR slot cannot contain PFR power fields")
            end
          end
        end
      end

      private def forecast_changed(force_report : Bool = false) : Nil
        increment_version
        now = Time.instant
        if force_report || (last = @last_forecast_report).nil? || now - last >= FORECAST_REPORT_INTERVAL
          @last_forecast_report = now
          notify_changed(ATTR_FORECAST)
        end
      end

      private def change_esa_state(state : ESAState) : Nil
        return if @esa_state == state
        @esa_state = state
        increment_version_and_notify(ATTR_ESA_STATE)
      end

      private def change_capability_cause(cause : PowerAdjustReason) : Nil
        if capability = @power_adjustment_capability
          @power_adjustment_capability = PowerAdjustCapability.new(capability.power_adjustment_capability, cause)
          capability_changed
        end
      end

      private def capability_changed(force_report : Bool = false) : Nil
        increment_version
        now = Time.instant
        if force_report || (last = @last_capability_report).nil? || now - last >= CAPABILITY_REPORT_INTERVAL
          @last_capability_report = now
          notify_changed(ATTR_POWER_ADJUSTMENT_CAPABILITY)
        end
      end

      private def finish_adjustment(cause : EndCause) : Nil
        active = @active_adjustment
        return unless active
        started = @active_started
        elapsed = started ? (Time.instant - started).total_seconds.to_u32 : 0_u32
        energy = (active.power.to_i128 * elapsed.to_i128 // 3_600_i128)
          .clamp(Int64::MIN.to_i128, Int64::MAX.to_i128).to_i64
        @active_adjustment = nil
        @active_started = nil
        @active_fabric_index = nil
        @active_generation &+= 1_u64
        change_esa_state(ESAState::Online)
        change_capability_cause(PowerAdjustReason::NoAdjustment)
        emit_power_adjust_end(PowerAdjustEndEvent.new(cause, elapsed, energy))
      end

      private def cancel_for_host_change(cause : EndCause) : Nil
        status = @cancel_callback.try(&.call(@active_fabric_index))
        Log.warn { "host rejected power-adjustment cancellation: #{status}" } unless status && status.success?
      rescue ex
        Log.warn(exception: ex) { "host failed to cancel power adjustment" }
      ensure
        finish_adjustment(cause)
      end

      private def schedule_expiration(duration : UInt32, generation : UInt64) : Nil
        spawn do
          sleep duration.seconds
          cancel_for_host_change(EndCause::NormalCompletion) if @active_generation == generation
        end
      end
    end
  end
end
