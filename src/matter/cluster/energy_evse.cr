require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Energy EVSE (0x0099), revision 4. Charging Preferences is
    # mandatory. SoC Reporting and V2X are opt-in; Plug and Charge and RFID are not advertised.
    class EnergyEvse < Base
      cluster 0x0099, revision: 4

      feature :charging_preferences, bit: 0
      feature :soc_reporting, bit: 1
      feature :plug_and_charge, bit: 2
      feature :rfid, bit: 3
      feature :v2x, bit: 4

      SUPPORTED_FEATURES       = Feature::ChargingPreferences.value | Feature::SocReporting.value | Feature::V2x.value
      MAX_SOC                  =   100_u8
      MAX_TARGET_SCHEDULES     =        7
      MAX_TARGETS_PER_SCHEDULE =       10
      MAX_MINUTE_OF_DAY        = 1439_u16
      DAY_MASK                 =  0x7F_u8
      DISABLED_UNTIL           =    0_u32
      PERSISTED_TARGETS_KEY    = "charging_target_schedules"
      MATTER_EPOCH_UNIX        = 946_684_800_i64
      MAX_TIMER_DELAY_SECONDS  =          60_i64

      alias ExpiryTimer = Proc(Time::Span, Proc(Nil), Nil)

      enum State : UInt8
        NotPluggedIn
        PluggedInNoDemand
        PluggedInDemand
        PluggedInCharging
        PluggedInDischarging
        SessionEnding
        Fault
      end

      enum SupplyState : UInt8
        Disabled
        ChargingEnabled
        DischargingEnabled
        DisabledError
        DisabledDiagnostics
        Enabled
      end

      enum FaultState : UInt8
        NoError
        MeterFailure
        OverVoltage
        UnderVoltage
        OverCurrent
        ContactWetFailure
        ContactDryFailure
        GroundFault
        PowerLoss
        PowerQuality
        PilotShortCircuit
        EmergencyStop
        EvDisconnected
        WrongPowerSupply
        LiveNeutralSwap
        OverTemperature
        Other             = 0xFF
      end

      enum EnergyTransferStoppedReason : UInt8
        EvStopped
        EvseStopped
        Other
      end

      struct ChargingTarget
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter target_time_minutes_past_midnight : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        getter target_soc : UInt8?

        @[TLV::Field(tag: 2, optional: true)]
        getter added_energy : Int64?

        def initialize(@target_time_minutes_past_midnight : UInt16,
                       @added_energy : Int64? = nil, @target_soc : UInt8? = nil)
        end
      end

      struct ChargingTargetSchedule
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter day_of_week_for_sequence : UInt8

        @[TLV::Field(tag: 1)]
        @charging_targets : Array(ChargingTarget)

        def initialize(@day_of_week_for_sequence : UInt8,
                       charging_targets : Array(ChargingTarget))
          @charging_targets = charging_targets.dup
        end

        def charging_targets : Array(ChargingTarget)
          @charging_targets.dup
        end
      end

      struct EnableChargingRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter charging_enabled_until : UInt32?

        @[TLV::Field(tag: 1)]
        getter minimum_charge_current : Int64

        @[TLV::Field(tag: 2)]
        getter maximum_charge_current : Int64

        def initialize(@charging_enabled_until : UInt32?,
                       @minimum_charge_current : Int64, @maximum_charge_current : Int64)
        end
      end

      struct EnableDischargingRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter discharging_enabled_until : UInt32?

        @[TLV::Field(tag: 1)]
        getter maximum_discharge_current : Int64

        def initialize(@discharging_enabled_until : UInt32?, @maximum_discharge_current : Int64)
        end
      end

      struct SetTargetsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter charging_target_schedules : Array(ChargingTargetSchedule)

        def initialize(@charging_target_schedules : Array(ChargingTargetSchedule))
        end
      end

      struct GetTargetsResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter charging_target_schedules : Array(ChargingTargetSchedule)

        def initialize(@charging_target_schedules : Array(ChargingTargetSchedule))
        end
      end

      struct EvConnectedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt32

        def initialize(@session_id : UInt32)
        end
      end

      struct EvNotDetectedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt32

        @[TLV::Field(tag: 1)]
        getter state : State

        @[TLV::Field(tag: 2)]
        getter session_duration : UInt32

        @[TLV::Field(tag: 3)]
        getter session_energy_charged : Int64

        @[TLV::Field(tag: 4, optional: true)]
        getter session_energy_discharged : Int64?

        def initialize(@session_id : UInt32, @state : State,
                       @session_duration : UInt32, @session_energy_charged : Int64,
                       @session_energy_discharged : Int64? = nil)
        end
      end

      struct EnergyTransferStartedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt32

        @[TLV::Field(tag: 1)]
        getter state : State

        @[TLV::Field(tag: 2)]
        getter maximum_current : Int64

        @[TLV::Field(tag: 3, optional: true)]
        getter maximum_discharge_current : Int64?

        def initialize(@session_id : UInt32, @state : State, @maximum_current : Int64,
                       @maximum_discharge_current : Int64? = nil)
        end
      end

      struct EnergyTransferStoppedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt32

        @[TLV::Field(tag: 1)]
        getter state : State

        @[TLV::Field(tag: 2)]
        getter reason : EnergyTransferStoppedReason

        @[TLV::Field(tag: 4)]
        getter energy_transferred : Int64

        @[TLV::Field(tag: 5, optional: true)]
        getter energy_discharged : Int64?

        def initialize(@session_id : UInt32, @state : State,
                       @reason : EnergyTransferStoppedReason, @energy_transferred : Int64,
                       @energy_discharged : Int64? = nil)
        end
      end

      struct FaultEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter session_id : UInt32?

        @[TLV::Field(tag: 1)]
        getter state : State

        @[TLV::Field(tag: 2)]
        getter fault_state_previous_state : FaultState

        @[TLV::Field(tag: 4)]
        getter fault_state_current_state : FaultState

        def initialize(@session_id : UInt32?, @state : State,
                       @fault_state_previous_state : FaultState,
                       @fault_state_current_state : FaultState)
        end
      end

      private struct PersistedTargets
        include Storage::Record

        getter schedules : Array(ChargingTargetSchedule)

        def initialize(@schedules : Array(ChargingTargetSchedule))
        end
      end

      attribute 0x0000, :state, State, nullable: true
      attribute 0x0001, :supply_state, SupplyState, default: SupplyState::Disabled, persist: true
      attribute 0x0002, :fault_state, FaultState, default: FaultState::NoError, persist: true
      attribute 0x0003, :charging_enabled_until, UInt32, nullable: true, persist: true
      attribute 0x0004, :discharging_enabled_until, UInt32, nullable: true, persist: true, requires: :v2x
      attribute 0x0005, :circuit_capacity, Int64, default: 0_i64,
        persist: true, validate: :validate_capacity!, on_change: :cap_maximum_current
      attribute 0x0006, :minimum_charge_current, Int64, default: 0_i64, persist: true
      attribute 0x0007, :maximum_charge_current, Int64, default: 0_i64, persist: true
      attribute 0x0008, :maximum_discharge_current, Int64, default: 0_i64, persist: true, requires: :v2x
      attribute 0x0023, :next_charge_start_time, UInt32, nullable: true,
        requires: :charging_preferences
      attribute 0x0024, :next_charge_target_time, UInt32, nullable: true,
        requires: :charging_preferences
      attribute 0x0025, :next_charge_required_energy, Int64, nullable: true,
        requires: :charging_preferences
      attribute 0x0026, :next_charge_target_soc, UInt8, nullable: true,
        requires: :charging_preferences
      attribute 0x0030, :state_of_charge, UInt8, nullable: true,
        requires: :soc_reporting, validate: :validate_state_of_charge!
      attribute 0x0031, :battery_capacity, Int64, nullable: true,
        requires: :soc_reporting, validate: :validate_battery_capacity!
      attribute 0x0040, :session_id, UInt32, nullable: true, persist: true
      attribute 0x0041, :session_duration, UInt32, nullable: true, persist: true
      attribute 0x0042, :session_energy_charged, Int64, nullable: true, persist: true
      attribute 0x0043, :session_energy_discharged, Int64, nullable: true, persist: true,
        omit_changes: true, requires: :v2x

      command 0x01, :disable, access: :operate, timed: true
      command 0x02, :enable_charging, request: EnableChargingRequest,
        access: :operate, timed: true
      command 0x03, :enable_discharging, request: EnableDischargingRequest,
        access: :operate, timed: true, requires: :v2x
      command 0x05, :set_targets, request: SetTargetsRequest,
        access: :operate, timed: true, requires: :charging_preferences
      command 0x06, :get_targets, response: GetTargetsResponse, response_id: 0x00,
        access: :operate, timed: true, requires: :charging_preferences
      command 0x07, :clear_targets, access: :operate, timed: true,
        requires: :charging_preferences

      event 0x00, :ev_connected, priority: :info, payload: EvConnectedEvent
      event 0x01, :ev_not_detected, priority: :info, payload: EvNotDetectedEvent
      event 0x02, :energy_transfer_started, priority: :info, payload: EnergyTransferStartedEvent
      event 0x03, :energy_transfer_stopped, priority: :info, payload: EnergyTransferStoppedEvent
      event 0x04, :fault, priority: :critical, payload: FaultEvent

      alias EnableCallback = Proc(UInt32?, Int64, Int64, InteractionModel::Status)
      alias DischargeCallback = Proc(UInt32?, Int64, InteractionModel::Status)
      alias DisableCallback = Proc(InteractionModel::Status)
      alias TargetsCallback = Proc(Array(ChargingTargetSchedule), InteractionModel::Status)

      property on_enable_charging : EnableCallback? = nil
      property on_enable_discharging : DischargeCallback? = nil
      property on_disable : DisableCallback? = nil
      property on_targets_changed : TargetsCallback? = nil

      @charging_target_schedules : Array(ChargingTargetSchedule)
      @transfer_start_energy : Int64 = 0_i64
      @transfer_start_discharge_energy : Int64 = 0_i64
      @expiry_generation : UInt64 = 0_u64
      @expiry_timer : ExpiryTimer

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @circuit_capacity : Int64,
                     @feature_map : Feature = Feature::ChargingPreferences,
                     @state : State? = nil,
                     @supply_state : SupplyState = SupplyState::Disabled,
                     @fault_state : FaultState = FaultState::NoError,
                     @charging_enabled_until : UInt32? = DISABLED_UNTIL,
                     @discharging_enabled_until : UInt32? = DISABLED_UNTIL,
                     @minimum_charge_current : Int64 = 0_i64,
                     @maximum_charge_current : Int64 = 0_i64,
                     @maximum_discharge_current : Int64 = 0_i64,
                     @next_charge_start_time : UInt32? = nil,
                     @next_charge_target_time : UInt32? = nil,
                     @next_charge_required_energy : Int64? = nil,
                     @next_charge_target_soc : UInt8? = nil,
                     @state_of_charge : UInt8? = nil,
                     @battery_capacity : Int64? = nil,
                     @session_id : UInt32? = nil,
                     @session_duration : UInt32? = nil,
                     @session_energy_charged : Int64? = nil,
                     @session_energy_discharged : Int64? = nil,
                     @clock : Proc(Time) = -> { Time.utc },
                     expiry_timer : ExpiryTimer? = nil)
        @expiry_timer = expiry_timer || ->(delay : Time::Span, callback : Proc(Nil)) do
          spawn do
            sleep delay
            callback.call
          end
          nil
        end
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("Energy EVSE requires Charging Preferences") unless @feature_map.charging_preferences?
        raise ArgumentError.new("unsupported Energy EVSE feature bits") if (@feature_map.value & ~SUPPORTED_FEATURES) != 0
        validate_state_of_charge!(@state_of_charge)
        validate_battery_capacity!(@battery_capacity)
        validate_capacity!(@circuit_capacity)
        raise ArgumentError.new("invalid charge current") if @minimum_charge_current < 0 || @maximum_charge_current < 0 ||
                                                             @maximum_discharge_current < 0
        raise ArgumentError.new("fault state and supply state disagree") if (@fault_state == FaultState::NoError) != (@supply_state != SupplyState::DisabledError)
        @charging_target_schedules = [] of ChargingTargetSchedule
      end

      def charging_target_schedules : Array(ChargingTargetSchedule)
        @charging_target_schedules.dup
      end

      # Publish live EV telemetry. Unknown values are null; a restarted EVSE
      # waits for the host to provide fresh readings instead of replaying stale data.
      def report_soc(state_of_charge : UInt8?, battery_capacity : Int64?) : Nil
        raise ArgumentError.new("SoC Reporting is not enabled") unless @feature_map.soc_reporting?
        validate_state_of_charge!(state_of_charge)
        validate_battery_capacity!(battery_capacity)
        self.state_of_charge = state_of_charge
        self.battery_capacity = battery_capacity
      end

      # The host owns the charging forecast because it has the charger and EV
      # telemetry. Publish its current estimate through the PREF attributes.
      def report_next_charge(start_time : UInt32?, target_time : UInt32?,
                             required_energy : Int64?, target_soc : UInt8?) : Nil
        if start_time && target_time && target_time < start_time
          raise ArgumentError.new("target time precedes charge start")
        end
        raise ArgumentError.new("required energy must be nonnegative") if required_energy && required_energy < 0
        if target_soc
          raise ArgumentError.new("TargetSoC exceeds 100 percent") if target_soc > MAX_SOC
          if !@feature_map.soc_reporting? && target_soc != MAX_SOC
            raise ArgumentError.new("TargetSoC requires the SoC Reporting feature")
          end
        end
        self.next_charge_start_time = start_time
        self.next_charge_target_time = target_time
        self.next_charge_required_energy = required_energy
        self.next_charge_target_soc = target_soc
      end

      def disable : InteractionModel::Status
        if charging_grant_active? || discharging_grant_active?
          callback = @on_disable || return InteractionModel::Status.invalid_in_state
          status = callback.call
          return status unless status.success?
        end
        self.charging_enabled_until = DISABLED_UNTIL
        self.discharging_enabled_until = DISABLED_UNTIL if @feature_map.v2x?
        self.minimum_charge_current = 0_i64
        self.maximum_charge_current = 0_i64
        self.maximum_discharge_current = 0_i64 if @feature_map.v2x?
        self.supply_state = SupplyState::Disabled unless @supply_state.disabled_error?
        schedule_expiry
        InteractionModel::Status.success
      end

      def enable_charging(request : EnableChargingRequest) : InteractionModel::Status
        minimum = request.minimum_charge_current
        maximum = request.maximum_charge_current
        return InteractionModel::Status.constraint_error if minimum < 0 || maximum < minimum || minimum > @circuit_capacity
        effective_maximum = {maximum, @circuit_capacity}.min
        should_enable = enabled_now?(request.charging_enabled_until)
        discharge_active = discharging_grant_active?
        if should_enable
          return InteractionModel::Status.failure unless @fault_state.no_error?
          callback = @on_enable_charging || return InteractionModel::Status.invalid_in_state
          status = callback.call(request.charging_enabled_until, minimum, effective_maximum)
          return status unless status.success?
        elsif charging_grant_active?
          if discharge_active
            callback = @on_enable_discharging || return InteractionModel::Status.invalid_in_state
            status = callback.call(@discharging_enabled_until, @maximum_discharge_current)
            return status unless status.success?
          else
            callback = @on_disable || return InteractionModel::Status.invalid_in_state
            status = callback.call
            return status unless status.success?
          end
        end
        self.minimum_charge_current = should_enable ? minimum : 0_i64
        self.maximum_charge_current = should_enable ? effective_maximum : 0_i64
        self.charging_enabled_until = should_enable ? request.charging_enabled_until : DISABLED_UNTIL
        self.supply_state = if @fault_state.no_error?
                              supply_state_for(should_enable, discharge_active)
                            else
                              SupplyState::DisabledError
                            end
        schedule_expiry
        InteractionModel::Status.success
      end

      def enable_discharging(request : EnableDischargingRequest) : InteractionModel::Status
        maximum = request.maximum_discharge_current
        return InteractionModel::Status.constraint_error if maximum < 0
        effective_maximum = {maximum, @circuit_capacity}.min
        should_enable = enabled_now?(request.discharging_enabled_until)
        charge_active = charging_grant_active?
        if should_enable
          return InteractionModel::Status.failure unless @fault_state.no_error?
          callback = @on_enable_discharging || return InteractionModel::Status.invalid_in_state
          status = callback.call(request.discharging_enabled_until, effective_maximum)
          return status unless status.success?
        elsif discharging_grant_active?
          if charge_active
            callback = @on_enable_charging || return InteractionModel::Status.invalid_in_state
            status = callback.call(@charging_enabled_until, @minimum_charge_current, @maximum_charge_current)
            return status unless status.success?
          else
            callback = @on_disable || return InteractionModel::Status.invalid_in_state
            status = callback.call
            return status unless status.success?
          end
        end
        self.maximum_discharge_current = should_enable ? effective_maximum : 0_i64
        self.discharging_enabled_until = should_enable ? request.discharging_enabled_until : DISABLED_UNTIL
        self.supply_state = if @fault_state.no_error?
                              supply_state_for(charge_active, should_enable)
                            else
                              SupplyState::DisabledError
                            end
        schedule_expiry
        InteractionModel::Status.success
      end

      # The command handlers must retain their Matter command names.
      # ameba:disable Naming/AccessorMethodName
      def set_targets(request : SetTargetsRequest) : InteractionModel::Status
        schedules = request.charging_target_schedules
        if @feature_map.soc_reporting? && schedules.any? { |schedule| schedule.charging_targets.any?(&.target_soc.nil?) }
          return InteractionModel::Status.invalid_command
        end
        return InteractionModel::Status.constraint_error unless valid_schedules?(schedules)
        if callback = @on_targets_changed
          status = callback.call(copy_schedules(schedules))
          return status unless status.success?
        end
        @charging_target_schedules = copy_schedules(schedules)
        increment_version
        InteractionModel::Status.success
      end

      # ameba:disable Naming/AccessorMethodName
      def get_targets : GetTargetsResponse
        GetTargetsResponse.new(copy_schedules(@charging_target_schedules))
      end

      def clear_targets : InteractionModel::Status
        unless @charging_target_schedules.empty?
          if callback = @on_targets_changed
            status = callback.call([] of ChargingTargetSchedule)
            return status unless status.success?
          end
          @charging_target_schedules.clear
          increment_version
        end
        InteractionModel::Status.success
      end

      # The host passes the physical EVSE state after observing its pilot and
      # metering signals. This is the authoritative source for transfer events.
      def report_ev_connected(session_id : UInt32) : Nil
        raise ArgumentError.new("EVSE session already active") if @session_id
        self.session_id = session_id
        self.session_duration = 0_u32
        self.session_energy_charged = 0_i64
        self.session_energy_discharged = 0_i64 if @feature_map.v2x?
        self.state = State::PluggedInNoDemand
        emit_event(EVENT_EV_CONNECTED, EvConnectedEvent.new(session_id))
      end

      def report_transfer_started : Nil
        id = @session_id || raise ArgumentError.new("no EVSE session")
        raise ArgumentError.new("EVSE charging is disabled") unless charging_grant_active?
        raise ArgumentError.new("EVSE transfer already active") if transfer_active?
        @transfer_start_energy = @session_energy_charged || 0_i64
        self.state = State::PluggedInCharging
        emit_event(EVENT_ENERGY_TRANSFER_STARTED,
          EnergyTransferStartedEvent.new(id, State::PluggedInCharging, @maximum_charge_current,
            @feature_map.v2x? ? (discharging_grant_active? ? @maximum_discharge_current : 0_i64) : nil))
      end

      def report_discharge_started : Nil
        raise ArgumentError.new("V2X is not enabled") unless @feature_map.v2x?
        id = @session_id || raise ArgumentError.new("no EVSE session")
        raise ArgumentError.new("EVSE discharging is disabled") unless discharging_grant_active?
        raise ArgumentError.new("EVSE transfer already active") if transfer_active?
        @transfer_start_discharge_energy = @session_energy_discharged || 0_i64
        self.state = State::PluggedInDischarging
        emit_event(EVENT_ENERGY_TRANSFER_STARTED,
          EnergyTransferStartedEvent.new(id, State::PluggedInDischarging,
            charging_grant_active? ? @maximum_charge_current : 0_i64, @maximum_discharge_current))
      end

      def report_transfer_stopped(reason : EnergyTransferStoppedReason,
                                  energy_transferred : Int64) : Nil
        id = @session_id || raise ArgumentError.new("no EVSE session")
        raise ArgumentError.new("EVSE transfer is not active") unless @state == State::PluggedInCharging
        raise ArgumentError.new("negative energy transfer") if energy_transferred < 0
        self.session_energy_charged = {(@session_energy_charged || 0_i64), @transfer_start_energy + energy_transferred}.max
        self.state = State::PluggedInNoDemand
        emit_event(EVENT_ENERGY_TRANSFER_STOPPED,
          EnergyTransferStoppedEvent.new(id, State::PluggedInNoDemand, reason, energy_transferred,
            @feature_map.v2x? ? 0_i64 : nil))
      end

      def report_discharge_stopped(reason : EnergyTransferStoppedReason,
                                   energy_discharged : Int64) : Nil
        raise ArgumentError.new("V2X is not enabled") unless @feature_map.v2x?
        id = @session_id || raise ArgumentError.new("no EVSE session")
        raise ArgumentError.new("EVSE discharge is not active") unless @state == State::PluggedInDischarging
        raise ArgumentError.new("negative discharged energy") if energy_discharged < 0
        self.session_energy_discharged = {(@session_energy_discharged || 0_i64),
                                          @transfer_start_discharge_energy + energy_discharged}.max
        self.state = State::PluggedInNoDemand
        emit_event(EVENT_ENERGY_TRANSFER_STOPPED,
          EnergyTransferStoppedEvent.new(id, State::PluggedInNoDemand, reason, 0_i64, energy_discharged))
      end

      def report_ev_disconnected(duration : UInt32) : Nil
        id = @session_id || raise ArgumentError.new("no EVSE session")
        previous_state = @state || State::PluggedInNoDemand
        energy = @session_energy_charged || 0_i64
        emit_event(EVENT_EV_NOT_DETECTED, EvNotDetectedEvent.new(id, previous_state, duration, energy,
          @feature_map.v2x? ? (@session_energy_discharged || 0_i64) : nil))
        self.state = State::NotPluggedIn
        self.session_id = nil
        self.session_duration = nil
        self.session_energy_charged = nil
        self.session_energy_discharged = nil if @feature_map.v2x?
      end

      def report_fault(fault : FaultState) : Nil
        previous = @fault_state
        return if previous == fault
        self.fault_state = fault
        if fault.no_error?
          self.supply_state = SupplyState::Disabled
          self.state = State::NotPluggedIn if @state == State::Fault
        else
          self.supply_state = SupplyState::DisabledError
          self.state = State::Fault
        end
        emit_event(EVENT_FAULT, FaultEvent.new(@session_id, @state || State::NotPluggedIn, previous, fault))
        schedule_expiry
      end

      def update_session(duration : UInt32, energy_charged : Int64,
                         energy_discharged : Int64? = nil) : Nil
        raise ArgumentError.new("no EVSE session") unless @session_id
        raise ArgumentError.new("negative charged energy") if energy_charged < 0
        raise ArgumentError.new("negative discharged energy") if energy_discharged && energy_discharged < 0
        raise ArgumentError.new("V2X is not enabled") if energy_discharged && !@feature_map.v2x?
        raise ArgumentError.new("session duration cannot decrease") if (previous = @session_duration) && duration < previous
        raise ArgumentError.new("charged energy cannot decrease") if (previous = @session_energy_charged) && energy_charged < previous
        if energy_discharged && (previous = @session_energy_discharged) && energy_discharged < previous
          raise ArgumentError.new("discharged energy cannot decrease")
        end
        self.session_duration = duration
        self.session_energy_charged = energy_charged
        self.session_energy_discharged = energy_discharged if energy_discharged
      end

      def expire_charging(now : UInt32 = matter_epoch_seconds) : Nil
        until_time = @charging_enabled_until
        unless until_time && until_time <= now && charging_grant_active?
          schedule_expiry
          return
        end
        discharge_active = discharging_grant_active?
        if discharge_active && !@on_enable_discharging
          report_fault(FaultState::Other)
          return
        end
        callback = discharge_active ? @on_enable_discharging.try { |enable| -> { enable.call(@discharging_enabled_until, @maximum_discharge_current) } } : @on_disable
        if callback
          status = callback.call
          unless status.success?
            report_fault(FaultState::Other)
            return
          end
        end
        self.charging_enabled_until = DISABLED_UNTIL
        self.minimum_charge_current = 0_i64
        self.maximum_charge_current = 0_i64
        self.supply_state = supply_state_for(false, discharge_active)
        schedule_expiry
      end

      def expire_discharging(now : UInt32 = matter_epoch_seconds) : Nil
        return unless @feature_map.v2x?
        until_time = @discharging_enabled_until
        unless until_time && until_time <= now && discharging_grant_active?
          schedule_expiry
          return
        end
        charge_active = charging_grant_active?
        if charge_active && !@on_enable_charging
          report_fault(FaultState::Other)
          return
        end
        callback = charge_active ? @on_enable_charging.try { |enable| -> { enable.call(@charging_enabled_until, @minimum_charge_current, @maximum_charge_current) } } : @on_disable
        if callback
          status = callback.call
          unless status.success?
            report_fault(FaultState::Other)
            return
          end
        end
        self.discharging_enabled_until = DISABLED_UNTIL
        self.maximum_discharge_current = 0_i64
        self.supply_state = supply_state_for(charge_active, false)
        schedule_expiry
      end

      private def validate_capacity!(capacity : Int64) : Nil
        raise ArgumentError.new("CircuitCapacity must be nonnegative") if capacity < 0
        if charging_grant_active? && capacity < @maximum_charge_current
          raise ArgumentError.new("disable charging before reducing CircuitCapacity")
        end
        if discharging_grant_active? && capacity < @maximum_discharge_current
          raise ArgumentError.new("disable discharging before reducing CircuitCapacity")
        end
      end

      private def validate_state_of_charge!(value : UInt8?) : Nil
        raise ArgumentError.new("SoC telemetry requires SoC Reporting") if value && !@feature_map.soc_reporting?
        raise ArgumentError.new("StateOfCharge exceeds 100 percent") if value && value > MAX_SOC
      end

      private def validate_battery_capacity!(value : Int64?) : Nil
        raise ArgumentError.new("SoC telemetry requires SoC Reporting") if value && !@feature_map.soc_reporting?
        raise ArgumentError.new("BatteryCapacity must be nonnegative") if value && value < 0
      end

      protected def validate_feature_map_change(value : Feature) : Nil
        raise ArgumentError.new("Energy EVSE feature profile is fixed after construction") unless value == @feature_map
      end

      private def cap_maximum_current(capacity : Int64) : Nil
        self.maximum_charge_current = capacity if @maximum_charge_current > capacity
        if @feature_map.v2x? && @maximum_discharge_current > capacity
          self.maximum_discharge_current = capacity
        end
      end

      private def transfer_active? : Bool
        @state.in?(State::PluggedInCharging, State::PluggedInDischarging)
      end

      private def charging_grant_active? : Bool
        @supply_state.in?(SupplyState::ChargingEnabled, SupplyState::Enabled)
      end

      private def discharging_grant_active? : Bool
        @supply_state.in?(SupplyState::DischargingEnabled, SupplyState::Enabled)
      end

      private def supply_state_for(charge : Bool, discharge : Bool) : SupplyState
        return SupplyState::Enabled if charge && discharge
        return SupplyState::ChargingEnabled if charge
        return SupplyState::DischargingEnabled if discharge
        SupplyState::Disabled
      end

      private def enabled_now?(until_time : UInt32?) : Bool
        until_time.nil? || until_time > matter_epoch_seconds
      end

      private def matter_epoch_seconds : UInt32
        seconds = @clock.call.to_unix - MATTER_EPOCH_UNIX
        seconds.clamp(0_i64, UInt32::MAX.to_i64).to_u32
      end

      private def schedule_expiry : Nil
        @expiry_generation &+= 1
        until_times = [] of UInt32
        if charging_grant_active? && (deadline = @charging_enabled_until)
          until_times << deadline
        end
        if discharging_grant_active? && (deadline = @discharging_enabled_until)
          until_times << deadline
        end
        until_time = until_times.min?
        return unless until_time
        remaining = until_time.to_i64 - matter_epoch_seconds.to_i64
        if remaining <= 0
          if charging_grant_active? && @charging_enabled_until == until_time
            expire_charging(until_time)
          elsif discharging_grant_active? && @discharging_enabled_until == until_time
            expire_discharging(until_time)
          end
          return
        end
        delay = {remaining, MAX_TIMER_DELAY_SECONDS}.min.seconds
        generation = @expiry_generation
        @expiry_timer.call(delay, -> { expire_if_current(generation) })
      end

      private def expire_if_current(generation : UInt64) : Nil
        return unless generation == @expiry_generation
        schedule_expiry
      end

      private def valid_schedules?(schedules : Array(ChargingTargetSchedule)) : Bool
        return false if schedules.size > MAX_TARGET_SCHEDULES
        used_days = 0_u8
        schedules.each do |schedule|
          days = schedule.day_of_week_for_sequence
          return false if days.zero? || (days & ~DAY_MASK) != 0 || (used_days & days) != 0
          used_days |= days
          targets = schedule.charging_targets
          return false if targets.size > MAX_TARGETS_PER_SCHEDULE
          targets.each do |target|
            return false if target.target_time_minutes_past_midnight > MAX_MINUTE_OF_DAY
            if soc = target.target_soc
              return false if soc > MAX_SOC || (!@feature_map.soc_reporting? && soc != MAX_SOC)
            end
            energy = target.added_energy
            return false if @feature_map.soc_reporting? && target.target_soc.nil?
            return false if energy.nil? && target.target_soc.nil?
            return false if energy && energy < 0
          end
        end
        true
      end

      private def copy_schedules(schedules : Array(ChargingTargetSchedule)) : Array(ChargingTargetSchedule)
        schedules.map { |schedule| ChargingTargetSchedule.new(schedule.day_of_week_for_sequence, schedule.charging_targets) }
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        document[PERSISTED_TARGETS_KEY] = PersistedTargets.new(@charging_target_schedules).to_document
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        if raw = document[PERSISTED_TARGETS_KEY]?
          record = PersistedTargets.from_document(raw.as?(Storage::Document) ||
                                                  raise StorageError.new("invalid EVSE target schedules"))
          raise StorageError.new("invalid EVSE target schedules") unless valid_schedules?(record.schedules)
          @charging_target_schedules = copy_schedules(record.schedules)
        end
      end

      private def after_restore_state : Nil
        expire_charging
        expire_discharging if @feature_map.v2x?
      end
    end
  end
end
