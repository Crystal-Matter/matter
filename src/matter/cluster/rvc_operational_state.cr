require "./operational_state"
require "./rvc_run_mode"

module Matter
  module Cluster
    # Matter 1.6 RVC Operational State. Physical actions are host decisions.
    class RvcOperationalState < Base
      cluster 0x0061, revision: 3, persist_state: false

      STOPPED            = OperationalState::STOPPED
      RUNNING            = OperationalState::RUNNING
      PAUSED             = OperationalState::PAUSED
      ERROR              = OperationalState::ERROR
      SEEKING_CHARGER    = 0x40_u8
      CHARGING           = 0x41_u8
      DOCKED             = 0x42_u8
      EMPTYING_DUST_BIN  = 0x43_u8
      CLEANING_MOP       = 0x44_u8
      FILLING_WATER_TANK = 0x45_u8
      UPDATING_MAPS      = 0x46_u8

      NO_ERROR                         = OperationalState::NO_ERROR
      UNABLE_TO_START_OR_RESUME        = OperationalState::UNABLE_TO_START_OR_RESUME
      UNABLE_TO_COMPLETE_OPERATION     = OperationalState::UNABLE_TO_COMPLETE_OPERATION
      COMMAND_INVALID_IN_STATE         = OperationalState::COMMAND_INVALID_IN_STATE
      FAILED_TO_FIND_CHARGING_DOCK     =  0x40_u8
      STUCK                            =  0x41_u8
      DUST_BIN_MISSING                 =  0x42_u8
      DUST_BIN_FULL                    =  0x43_u8
      WATER_TANK_EMPTY                 =  0x44_u8
      WATER_TANK_MISSING               =  0x45_u8
      WATER_TANK_LID_OPEN              =  0x46_u8
      MOP_CLEANING_PAD_MISSING         =  0x47_u8
      LOW_BATTERY                      =  0x48_u8
      CANNOT_REACH_TARGET_AREA         =  0x49_u8
      DIRTY_WATER_TANK_FULL            =  0x4A_u8
      DIRTY_WATER_TANK_MISSING         =  0x4B_u8
      WHEELS_JAMMED                    =  0x4C_u8
      BRUSH_JAMMED                     =  0x4D_u8
      NAVIGATION_SENSOR_OBSCURED       =  0x4E_u8
      CMD_OPERATIONAL_COMMAND_RESPONSE = 0x04_u32

      enum Command : UInt8
        Pause  = 0x00
        Resume = 0x03
      end

      struct StateDescription
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter operational_state_id : UInt8

        @[TLV::Field(tag: 1, optional: true)]
        getter operational_state_label : String?

        def initialize(@operational_state_id : UInt8, @operational_state_label : String? = nil)
          RvcOperationalState.validate_identifier!(@operational_state_id, @operational_state_label, "state")
        end
      end

      struct ErrorState
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter error_state_id : UInt8

        @[TLV::Field(tag: 1, optional: true)]
        getter error_state_label : String?

        @[TLV::Field(tag: 2, optional: true)]
        getter error_state_details : String?

        def initialize(@error_state_id : UInt8, @error_state_label : String? = nil,
                       @error_state_details : String? = nil)
          RvcOperationalState.validate_identifier!(@error_state_id, @error_state_label, "error")
          if details = @error_state_details
            raise ArgumentError.new("error details exceed 64 bytes") if details.bytesize > OperationalState::MAX_LABEL_BYTES
          end
        end
      end

      struct OperationalCommandResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter command_response_state : ErrorState

        def initialize(@command_response_state : ErrorState)
        end
      end

      struct OperationalErrorEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter error_state : ErrorState

        def initialize(@error_state : ErrorState)
        end
      end

      alias OperationCompletionEvent = OperationalState::OperationCompletionEvent

      attribute 0x0000, :phase_list, Array(String), nullable: true, copy_on_assign: true
      attribute 0x0001, :current_phase, UInt8, nullable: true
      attribute 0x0002, :countdown_time, UInt32, nullable: true, optional: true,
        present_if: :countdown_supported?, max: OperationalState::MAX_COUNTDOWN
      attribute 0x0003, :operational_state_list, Array(StateDescription), default: [] of StateDescription,
        copy_on_assign: true
      attribute 0x0004, :operational_state, UInt8, default: STOPPED
      attribute 0x0005, :operational_error, ErrorState, default: ErrorState.new(NO_ERROR)

      command 0x00, :pause, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true
      command 0x03, :resume, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true
      command 0x80, :go_home, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true, access: :operate

      event 0x00, :operational_error, priority: :critical, payload: OperationalErrorEvent
      event 0x01, :operation_completion, priority: :info, payload: OperationCompletionEvent

      @supported_commands : Array(Command)
      @on_command : Proc(Command, ErrorState)? = nil
      @on_go_home : Proc(ErrorState)? = nil
      @countdown_supported : Bool
      @last_active_state : UInt8 = RUNNING
      @resumable_dock_state : UInt8? = nil
      @go_home_pending : Bool = false

      def initialize(endpoint_id : DataType::EndpointNumber,
                     supported_commands : Array(Command) = [] of Command,
                     @go_home : Bool = false,
                     @run_mode : RvcRunMode? = nil,
                     states : Array(StateDescription) = [
                       StateDescription.new(STOPPED), StateDescription.new(RUNNING),
                       StateDescription.new(PAUSED), StateDescription.new(ERROR),
                       StateDescription.new(SEEKING_CHARGER), StateDescription.new(CHARGING),
                       StateDescription.new(DOCKED),
                     ],
                     phase_list : Array(String)? = nil, current_phase : UInt8? = nil,
                     countdown_time : UInt32? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("Pause and Resume must be supported together") unless supported_commands.includes?(Command::Pause) == supported_commands.includes?(Command::Resume)
        raise ArgumentError.new("duplicate RVC commands") unless supported_commands.uniq.size == supported_commands.size
        required_states = {STOPPED, RUNNING, PAUSED, ERROR, SEEKING_CHARGER, CHARGING, DOCKED}
        ids = states.map(&.operational_state_id)
        raise ArgumentError.new("duplicate RVC state IDs") unless ids.uniq.size == ids.size
        raise ArgumentError.new("RVC OperationalStateList omits mandatory state") unless required_states.all? { |id| ids.includes?(id) }
        validate_phases!(phase_list, current_phase)
        validate_countdown!(countdown_time)
        @supported_commands = supported_commands.dup
        @operational_state_list = states.dup
        @phase_list = phase_list.try(&.dup)
        @current_phase = current_phase
        @countdown_supported = !countdown_time.nil?
        @countdown_time = countdown_time
      end

      def on_command(&block : Command -> ErrorState) : Nil
        @on_command = block
      end

      def on_go_home(&block : -> ErrorState) : Nil
        @on_go_home = block
      end

      def phase_list : Array(String)?
        @phase_list.try(&.dup)
      end

      def operational_state_list : Array(StateDescription)
        @operational_state_list.dup
      end

      def update_phases(phases : Array(String)?, current : UInt8?) : Nil
        validate_phases!(phases, current)
        self.phase_list = phases.try(&.dup)
        self.current_phase = current
      end

      def update_countdown(seconds : UInt32?, reportable : Bool = true) : Nil
        validate_countdown!(seconds)
        @countdown_supported = true
        previous = @countdown_time
        return if previous == seconds
        boundary = previous.nil? != seconds.nil? || previous == 0_u32 || seconds == 0_u32
        increase = previous && seconds && seconds > previous
        if reportable || boundary || increase
          self.countdown_time = seconds
        else
          @countdown_time = seconds
          increment_version
        end
      end

      def report_state(state_id : UInt8) : Nil
        raise ArgumentError.new("report_error must be used for Error state") if state_id == ERROR
        raise ArgumentError.new("state is absent from OperationalStateList") unless @operational_state_list.any?(&.operational_state_id.==(state_id))
        if state_id == PAUSED && @operational_state != PAUSED && @operational_state != ERROR
          @last_active_state = @operational_state
        end
        if state_id == SEEKING_CHARGER
          @resumable_dock_state = if @go_home_pending
                                    nil
                                  elsif @operational_state == RUNNING
                                    RUNNING
                                  elsif @operational_state == PAUSED
                                    @last_active_state
                                  else
                                    @resumable_dock_state
                                  end
        elsif state_id == CHARGING || state_id == DOCKED
          @resumable_dock_state = if @operational_state == RUNNING
                                    RUNNING
                                  elsif @operational_state == PAUSED
                                    @last_active_state
                                  elsif @operational_state == SEEKING_CHARGER || @operational_state == CHARGING
                                    @resumable_dock_state
                                  end
        else
          @resumable_dock_state = nil
        end
        @go_home_pending = false if state_id == STOPPED || state_id == RUNNING
        self.operational_error = ErrorState.new(NO_ERROR)
        self.operational_state = state_id
        if state_id == DOCKED && @go_home_pending
          @run_mode.try { |run| run.current_mode = run.idle_mode }
          @go_home_pending = false
        end
      end

      def report_error(error : ErrorState) : Nil
        raise ArgumentError.new("NoError cannot be reported as an OperationalError event") if error.error_state_id == NO_ERROR
        @resumable_dock_state = nil
        @go_home_pending = false
        self.operational_error = error
        self.operational_state = ERROR
        emit_operational_error(OperationalErrorEvent.new(error))
      end

      def report_completion(error_code : UInt8, total_time : UInt32? = nil,
                            paused_time : UInt32? = nil) : Nil
        valid = error_code.in?(NO_ERROR..COMMAND_INVALID_IN_STATE) ||
                error_code.in?(FAILED_TO_FIND_CHARGING_DOCK..NAVIGATION_SENSOR_OBSCURED) ||
                error_code.in?(OperationalState::MANUFACTURER_FIRST..OperationalState::MANUFACTURER_LAST)
        raise ArgumentError.new("completion error code is reserved") unless valid
        emit_operation_completion(OperationCompletionEvent.new(error_code, total_time, paused_time))
      end

      def pause : OperationalCommandResponse
        return response(NO_ERROR) if @operational_state == PAUSED
        return response(COMMAND_INVALID_IN_STATE) unless @operational_state == RUNNING || @operational_state == SEEKING_CHARGER
        decision = @on_command.try(&.call(Command::Pause)) || ErrorState.new(COMMAND_INVALID_IN_STATE)
        report_state(PAUSED) if decision.error_state_id == NO_ERROR
        OperationalCommandResponse.new(decision)
      end

      def resume : OperationalCommandResponse
        return response(NO_ERROR) if @operational_state == RUNNING
        target = if @operational_state == PAUSED
                   @last_active_state
                 elsif @operational_state == CHARGING || @operational_state == DOCKED
                   @resumable_dock_state
                 end
        return response(COMMAND_INVALID_IN_STATE) unless target
        decision = @on_command.try(&.call(Command::Resume)) || ErrorState.new(UNABLE_TO_START_OR_RESUME)
        report_state(target) if decision.error_state_id == NO_ERROR
        OperationalCommandResponse.new(decision)
      end

      def go_home : OperationalCommandResponse
        return response(NO_ERROR) if @operational_state == SEEKING_CHARGER
        return response(COMMAND_INVALID_IN_STATE) if @operational_state == CHARGING || @operational_state == DOCKED
        decision = @on_go_home.try(&.call) || ErrorState.new(COMMAND_INVALID_IN_STATE)
        if decision.error_state_id == NO_ERROR
          @go_home_pending = true
          report_state(SEEKING_CHARGER)
        end
        OperationalCommandResponse.new(decision)
      end

      def self.validate_identifier!(id : UInt8, label : String?, kind : String) : Nil
        manufacturer = id.in?(OperationalState::MANUFACTURER_FIRST..OperationalState::MANUFACTURER_LAST)
        if manufacturer && (label.nil? || label.empty?)
          raise ArgumentError.new("manufacturer #{kind} requires a label")
        end
        raise ArgumentError.new("#{kind} label is only allowed for manufacturer IDs") if !manufacturer && label
        raise ArgumentError.new("#{kind} label exceeds 64 bytes") if label && label.bytesize > OperationalState::MAX_LABEL_BYTES
        valid = kind == "state" ? id.in?(STOPPED..ERROR) || id.in?(SEEKING_CHARGER..UPDATING_MAPS) : id.in?(NO_ERROR..COMMAND_INVALID_IN_STATE) || id.in?(FAILED_TO_FIND_CHARGING_DOCK..NAVIGATION_SENSOR_OBSCURED)
        raise ArgumentError.new("unknown RVC #{kind} ID") unless valid || manufacturer
      end

      private def response(error_id : UInt8) : OperationalCommandResponse
        OperationalCommandResponse.new(ErrorState.new(error_id))
      end

      private def command_supported?(id : UInt32) : Bool
        id == 0x80_u32 ? @go_home : @supported_commands.any? { |command| command.value.to_u32 == id }
      end

      private def countdown_supported? : Bool
        @countdown_supported
      end

      private def validate_phases!(phases : Array(String)?, current : UInt8?) : Nil
        raise ArgumentError.new("CurrentPhase requires PhaseList") if current && (!phases || phases.empty?)
        raise ArgumentError.new("CurrentPhase exceeds PhaseList") if current && phases && current >= phases.size
        raise ArgumentError.new("PhaseList exceeds 32 entries") if phases && phases.size > OperationalState::MAX_PHASES
        if phases && phases.any? { |phase| phase.bytesize > OperationalState::MAX_LABEL_BYTES }
          raise ArgumentError.new("phase label exceeds 64 bytes")
        end
      end

      private def validate_countdown!(seconds : UInt32?) : Nil
        raise ArgumentError.new("CountdownTime exceeds 259200") if seconds && seconds > OperationalState::MAX_COUNTDOWN
      end
    end
  end
end
