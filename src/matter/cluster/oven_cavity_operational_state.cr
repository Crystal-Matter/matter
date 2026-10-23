require "./operational_state"

module Matter
  module Cluster
    # Matter 1.6 Oven Cavity Operational State (0x0048). The appliance owns
    # physical state; remote Start and Stop are enabled explicitly by the host.
    class OvenCavityOperationalState < Base
      cluster 0x0048, revision: 2, persist_state: false

      alias Command = OperationalState::Command
      alias StateDescription = OperationalState::StateDescription
      alias ErrorState = OperationalState::ErrorState
      alias OperationalCommandResponse = OperationalState::OperationalCommandResponse
      alias OperationalErrorEvent = OperationalState::OperationalErrorEvent
      alias OperationCompletionEvent = OperationalState::OperationCompletionEvent

      STOPPED                          = OperationalState::STOPPED
      RUNNING                          = OperationalState::RUNNING
      PAUSED                           = OperationalState::PAUSED
      ERROR                            = OperationalState::ERROR
      NO_ERROR                         = OperationalState::NO_ERROR
      UNABLE_TO_START_OR_RESUME        = OperationalState::UNABLE_TO_START_OR_RESUME
      UNABLE_TO_COMPLETE_OPERATION     = OperationalState::UNABLE_TO_COMPLETE_OPERATION
      COMMAND_INVALID_IN_STATE         = OperationalState::COMMAND_INVALID_IN_STATE
      CMD_OPERATIONAL_COMMAND_RESPONSE = 0x04_u32

      attribute 0x0000, :phase_list, Array(String), nullable: true, copy_on_assign: true
      attribute 0x0001, :current_phase, UInt8, nullable: true
      attribute 0x0002, :countdown_time, UInt32, nullable: true, optional: true,
        present_if: :countdown_supported?, max: OperationalState::MAX_COUNTDOWN
      attribute 0x0003, :operational_state_list, Array(StateDescription), default: [] of StateDescription,
        copy_on_assign: true
      attribute 0x0004, :operational_state, UInt8, default: STOPPED
      attribute 0x0005, :operational_error, ErrorState, default: ErrorState.new(NO_ERROR)

      command 0x01, :stop, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true
      command 0x02, :start, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true

      event 0x00, :operational_error, priority: :critical, payload: OperationalErrorEvent
      event 0x01, :operation_completion, priority: :info, payload: OperationCompletionEvent

      @supported_commands : Array(Command)
      @on_command : Proc(Command, ErrorState)? = nil
      @countdown_supported : Bool

      def initialize(endpoint_id : DataType::EndpointNumber,
                     supported_commands : Array(Command) = [] of Command,
                     states : Array(StateDescription) = [
                       StateDescription.new(STOPPED), StateDescription.new(RUNNING),
                       StateDescription.new(ERROR),
                     ],
                     phase_list : Array(String)? = nil, current_phase : UInt8? = nil,
                     countdown_time : UInt32? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_configuration!(supported_commands, states)
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
        unless @operational_state_list.any?(&.operational_state_id.==(state_id))
          raise ArgumentError.new("state is absent from OperationalStateList")
        end
        self.operational_error = ErrorState.new(NO_ERROR)
        self.operational_state = state_id
      end

      def report_error(error : ErrorState) : Nil
        raise ArgumentError.new("NoError cannot be reported as an OperationalError event") if error.error_state_id == NO_ERROR
        self.operational_error = error
        self.operational_state = ERROR
        emit_operational_error(OperationalErrorEvent.new(error))
      end

      def report_completion(error_code : UInt8, total_time : UInt32? = nil,
                            paused_time : UInt32? = nil) : Nil
        validate_error_code!(error_code)
        emit_operation_completion(OperationCompletionEvent.new(error_code, total_time, paused_time))
      end

      def stop : OperationalCommandResponse
        transition(Command::Stop, STOPPED, COMMAND_INVALID_IN_STATE)
      end

      def start : OperationalCommandResponse
        transition(Command::Start, RUNNING, UNABLE_TO_START_OR_RESUME)
      end

      private def transition(command : Command, target : UInt8, denial : UInt8) : OperationalCommandResponse
        current = @operational_state
        return command_response(NO_ERROR) if (command.stop? && current == STOPPED) || (command.start? && current == RUNNING)
        decision = @on_command.try(&.call(command)) || ErrorState.new(denial)
        unless decision.error_state_id == NO_ERROR || decision.error_state_id == denial ||
               (command.start? && decision.error_state_id == COMMAND_INVALID_IN_STATE)
          decision = ErrorState.new(denial)
        end
        report_state(target) if decision.error_state_id == NO_ERROR
        OperationalCommandResponse.new(decision)
      end

      private def command_response(error_id : UInt8) : OperationalCommandResponse
        OperationalCommandResponse.new(ErrorState.new(error_id))
      end

      private def command_supported?(id : UInt32) : Bool
        @supported_commands.any? { |command| command.value.to_u32 == id }
      end

      private def countdown_supported? : Bool
        @countdown_supported
      end

      private def validate_configuration!(commands : Array(Command), states : Array(StateDescription)) : Nil
        raise ArgumentError.new("duplicate operational commands") unless commands.uniq.size == commands.size
        if commands.any? { |command| command.pause? || command.resume? }
          raise ArgumentError.new("Oven Cavity disallows Pause and Resume")
        end
        if commands.includes?(Command::Start) && !commands.includes?(Command::Stop)
          raise ArgumentError.new("Start requires Stop")
        end
        ids = states.map(&.operational_state_id)
        raise ArgumentError.new("duplicate OperationalStateList ID") unless ids.uniq.size == ids.size
        raise ArgumentError.new("OperationalStateList requires Error") unless ids.includes?(ERROR)
        raise ArgumentError.new("OperationalStateList requires Stopped initial state") unless ids.includes?(STOPPED)
        if commands.includes?(Command::Start) && !ids.includes?(RUNNING)
          raise ArgumentError.new("OperationalStateList omits Running required by Start")
        end
      end

      private def validate_phases!(phases : Array(String)?, current : UInt8?) : Nil
        if phases
          raise ArgumentError.new("PhaseList exceeds 32 entries") if phases.size > OperationalState::MAX_PHASES
          if phases.any? { |phase| phase.bytesize > OperationalState::MAX_LABEL_BYTES }
            raise ArgumentError.new("PhaseList entry exceeds 64 bytes")
          end
        end
        if current && (phases.nil? || current >= phases.size)
          raise ArgumentError.new("CurrentPhase is outside PhaseList")
        end
      end

      private def validate_countdown!(seconds : UInt32?) : Nil
        if seconds && seconds > OperationalState::MAX_COUNTDOWN
          raise ArgumentError.new("CountdownTime exceeds 259200 seconds")
        end
      end

      private def validate_error_code!(code : UInt8) : Nil
        valid = code.in?(NO_ERROR..COMMAND_INVALID_IN_STATE) ||
                code.in?(OperationalState::MANUFACTURER_FIRST..OperationalState::MANUFACTURER_LAST)
        raise ArgumentError.new("completion error code is reserved") unless valid
      end
    end
  end
end
