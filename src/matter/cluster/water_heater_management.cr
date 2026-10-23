require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Water Heater Management (0x0094), revision 2.
    # The host owns the thermostat and physical heater; commands only report
    # success after its callbacks accept the requested operation.
    class WaterHeaterManagement < Base
      cluster 0x0094, revision: 2, persist_state: false

      feature :energy_management, bit: 0
      feature :tank_percent, bit: 1

      HEAT_SOURCE_MASK = 0x1F_u8
      MAX_PERCENT      =  100_u8

      @[Flags]
      enum HeatSource : UInt8
        None              =  0
        ImmersionElement1 =  1
        ImmersionElement2 =  2
        HeatPump          =  4
        Boiler            =  8
        Other             = 16
      end

      enum BoostState : UInt8
        Inactive = 0
        Active   = 1
      end

      struct BoostInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter duration : UInt32

        @[TLV::Field(tag: 1, optional: true)]
        getter one_shot : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        getter emergency_boost : Bool?

        @[TLV::Field(tag: 3, optional: true)]
        getter temporary_setpoint : Int16?

        @[TLV::Field(tag: 4, optional: true)]
        getter target_percentage : UInt8?

        @[TLV::Field(tag: 5, optional: true)]
        getter target_reheat : UInt8?

        def initialize(@duration : UInt32, @one_shot : Bool? = nil,
                       @emergency_boost : Bool? = nil, @temporary_setpoint : Int16? = nil,
                       @target_percentage : UInt8? = nil, @target_reheat : UInt8? = nil)
        end
      end

      struct BoostRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter boost_info : BoostInfo

        def initialize(@boost_info : BoostInfo)
        end
      end

      struct BoostStartedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter boost_info : BoostInfo

        def initialize(@boost_info : BoostInfo)
        end
      end

      struct BoostEndedEvent
        include TLV::Serializable

        def initialize
        end
      end

      attribute 0x0000, :heater_types, HeatSource, default: HeatSource::None,
        fixed: true, validate: :reject_fixed_heater_types!
      attribute 0x0001, :heat_demand, HeatSource, default: HeatSource::None,
        validate: :validate_heat_demand!
      attribute 0x0002, :tank_volume, UInt16, default: 0_u16,
        requires: :energy_management, fixed: true, validate: :reject_fixed_tank_volume!
      attribute 0x0003, :estimated_heat_required, Int64, default: 0_i64,
        requires: :energy_management, min: 0
      attribute 0x0004, :tank_percentage, UInt8, default: 0_u8,
        requires: :tank_percent, max: MAX_PERCENT
      attribute 0x0005, :boost_state, BoostState, default: BoostState::Inactive

      command 0x00, :boost, request: BoostRequest, access: :manage
      command 0x01, :cancel_boost, access: :manage

      event 0x00, :boost_started, priority: :info, payload: BoostStartedEvent
      event 0x01, :boost_ended, priority: :info, payload: BoostEndedEvent

      @boost_callback : Proc(BoostInfo, InteractionModel::Status)?
      @cancel_callback : Proc(InteractionModel::Status)?
      @active_boost : BoostInfo?
      @boost_generation : UInt64 = 0_u64

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @heater_types : HeatSource,
                     @feature_map : Feature = Feature::None,
                     @heat_demand : HeatSource = HeatSource::None,
                     @tank_volume : UInt16 = 0_u16,
                     @estimated_heat_required : Int64 = 0_i64,
                     @tank_percentage : UInt8 = 0_u8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_heater_types!(@heater_types)
        validate_heat_demand!(@heat_demand)
        raise ArgumentError.new("EnergyManagement is required for energy values") if !@feature_map.energy_management? && (@tank_volume != 0 || @estimated_heat_required != 0)
        raise ArgumentError.new("TankPercent is required for TankPercentage") if !@feature_map.tank_percent? && @tank_percentage != 0
        raise ArgumentError.new("EstimatedHeatRequired must be nonnegative") if @estimated_heat_required < 0
        raise ArgumentError.new("TankPercentage exceeds 100") if @tank_percentage > MAX_PERCENT
        @boost_state = BoostState::Inactive
      end

      def on_boost(&block : BoostInfo -> InteractionModel::Status) : Nil
        @boost_callback = block
      end

      def on_cancel_boost(&block : -> InteractionModel::Status) : Nil
        @cancel_callback = block
      end

      def report_heat_demand(source : HeatSource) : Nil
        self.heat_demand = source
      end

      def report_estimated_heat_required(value : Int64) : Nil
        raise ArgumentError.new("EnergyManagement feature is absent") unless @feature_map.energy_management?
        raise ArgumentError.new("EstimatedHeatRequired must be nonnegative") if value < 0
        self.estimated_heat_required = value
      end

      def report_tank_percentage(value : UInt8) : Nil
        raise ArgumentError.new("TankPercent feature is absent") unless @feature_map.tank_percent?
        raise ArgumentError.new("TankPercentage exceeds 100") if value > MAX_PERCENT
        self.tank_percentage = value
      end

      def boost(request : BoostRequest) : InteractionModel::Status
        info = request.boost_info
        return InteractionModel::Status.constraint_error unless valid_boost?(info)
        callback = @boost_callback
        return InteractionModel::Status.invalid_in_state unless callback && @cancel_callback
        status = callback.call(info)
        return status unless status.success?
        @boost_generation &+= 1_u64
        @active_boost = info
        self.boost_state = BoostState::Active
        emit_boost_started(BoostStartedEvent.new(info))
        schedule_boost_timeout(info.duration, @boost_generation)
        status
      end

      def cancel_boost : InteractionModel::Status
        return InteractionModel::Status.success if @boost_state.inactive?
        callback = @cancel_callback
        return InteractionModel::Status.invalid_in_state unless callback
        status = callback.call
        finish_boost if status.success?
        status
      end

      # Call when the thermostat setpoint or target percentage is reached.
      def finish_boost : Nil
        return if @boost_state.inactive?
        @boost_generation &+= 1_u64
        @active_boost = nil
        self.boost_state = BoostState::Inactive
        emit_boost_ended(BoostEndedEvent.new)
      end

      private def schedule_boost_timeout(duration : UInt32, generation : UInt64) : Nil
        spawn do
          sleep duration.seconds
          cancel_boost if @boost_generation == generation
        end
      end

      private def valid_boost?(info : BoostInfo) : Bool
        return false if info.duration == 0
        return false if info.target_percentage && !@feature_map.tank_percent?
        return false if info.target_reheat && !@feature_map.tank_percent?
        return false if info.target_reheat && !info.target_percentage
        return false if info.target_reheat && info.one_shot
        return false if (value = info.target_percentage) && value > MAX_PERCENT
        return false if (value = info.target_reheat) && value > MAX_PERCENT
        return false if (reheat = info.target_reheat) && (target = info.target_percentage) && reheat > target
        true
      end

      private def validate_heater_types!(source : HeatSource) : Nil
        raise ArgumentError.new("unknown heat source bits") if source.value & ~HEAT_SOURCE_MASK != 0
      end

      private def validate_heat_demand!(source : HeatSource) : Nil
        validate_heater_types!(source)
        raise ArgumentError.new("HeatDemand is not a subset of HeaterTypes") if source.value & ~@heater_types.value != 0
      end

      private def reject_fixed_heater_types!(_source) : Nil
        raise ArgumentError.new("HeaterTypes is fixed")
      end

      private def reject_fixed_tank_volume!(_volume) : Nil
        raise ArgumentError.new("TankVolume is fixed")
      end
    end
  end
end
