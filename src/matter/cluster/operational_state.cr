require "./cluster"

module Matter
  module Cluster
    # Generic Operational State server (0x0060), Matter 1.6 revision 3.
    #
    # Hosts publish appliance state explicitly. Remote actuation is opt-in and
    # every non-idempotent command is handed to the host before state changes.
    # The callback must perform its own safety, permission and mode checks.
    class OperationalState < Base
      cluster 0x0060, revision: 3, persist_state: false

      STOPPED = 0x00_u8
      RUNNING = 0x01_u8
      PAUSED  = 0x02_u8
      ERROR   = 0x03_u8

      NO_ERROR                     = 0x00_u8
      UNABLE_TO_START_OR_RESUME    = 0x01_u8
      UNABLE_TO_COMPLETE_OPERATION = 0x02_u8
      COMMAND_INVALID_IN_STATE     = 0x03_u8

      MANUFACTURER_FIRST               =     0x80_u8
      MANUFACTURER_LAST                =     0xBF_u8
      MAX_LABEL_BYTES                  =          64
      MAX_PHASES                       =          32
      MAX_COUNTDOWN                    = 259_200_u32
      CMD_OPERATIONAL_COMMAND_RESPONSE =    0x04_u32

      enum Command : UInt8
        Pause  = 0x00
        Stop   = 0x01
        Start  = 0x02
        Resume = 0x03
      end

      struct StateDescription
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter operational_state_id : UInt8

        @[TLV::Field(tag: 1, optional: true)]
        getter operational_state_label : String?

        def initialize(@operational_state_id : UInt8, @operational_state_label : String? = nil)
          OperationalState.validate_identifier!(@operational_state_id, @operational_state_label, "state")
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
                       @error_state_details : String? = nil, *, details : String? = nil)
          @error_state_details = details if details
          OperationalState.validate_identifier!(@error_state_id, @error_state_label, "error")
          if value = @error_state_details
            raise ArgumentError.new("error details exceed 64 bytes") if value.bytesize > MAX_LABEL_BYTES
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

      struct OperationCompletionEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter completion_error_code : UInt8

        @[TLV::Field(tag: 1, optional: true)]
        getter total_operational_time : UInt32?

        @[TLV::Field(tag: 2, optional: true)]
        getter paused_time : UInt32?

        def initialize(@completion_error_code : UInt8,
                       @total_operational_time : UInt32? = nil,
                       @paused_time : UInt32? = nil)
        end
      end

      attribute 0x0000, :phase_list, Array(String), nullable: true
      attribute 0x0001, :current_phase, UInt8, nullable: true
      attribute 0x0002, :countdown_time, UInt32, nullable: true, optional: true,
        present_if: :countdown_supported?, max: MAX_COUNTDOWN
      attribute 0x0003, :operational_state_list, Array(StateDescription), default: [] of StateDescription
      attribute 0x0004, :operational_state, UInt8, default: STOPPED
      attribute 0x0005, :operational_error, ErrorState, default: ErrorState.new(NO_ERROR)

      command 0x00, :pause, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true
      command 0x01, :stop, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true
      command 0x02, :start, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true
      command 0x03, :resume, response: OperationalCommandResponse,
        response_id: 0x04, present_if: :command_supported?, optional: true

      event 0x00, :operational_error, priority: :critical, payload: OperationalErrorEvent
      event 0x01, :operation_completion, priority: :info, payload: OperationCompletionEvent

      @on_command : Proc(Command, ErrorState)? = nil
      @last_active_state : UInt8 = RUNNING

      def initialize(endpoint_id : DataType::EndpointNumber,
                     supported_commands : Array(Command) = [] of Command,
                     states : Array(StateDescription) = [
                       StateDescription.new(STOPPED), StateDescription.new(RUNNING),
                       StateDescription.new(PAUSED), StateDescription.new(ERROR),
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

      # The host may update phase names when a program changes. A nil or empty
      # phase list requires a null CurrentPhase on the wire.
      def update_phases(phases : Array(String)?, current : UInt8?) : Nil
        validate_phases!(phases, current)
        self.phase_list = phases.try(&.dup)
        self.current_phase = current
      end

      # Normal one-second countdown ticks change the value without notifying
      # subscriptions. Set reportable for control-logic changes or time jumps.
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

      # Report a physical or locally initiated transition. Error is reported
      # separately so that an error always has details and emits its event.
      def report_state(state_id : UInt8) : Nil
        raise ArgumentError.new("report_error must be used for Error state") if state_id == ERROR
        unless @operational_state_list.any? { |state| state.operational_state_id == state_id }
          raise ArgumentError.new("state is absent from OperationalStateList")
        end
        @last_active_state = @operational_state if state_id == PAUSED && @operational_state != PAUSED && @operational_state != ERROR
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

      def pause : OperationalCommandResponse
        transition(Command::Pause, PAUSED, COMMAND_INVALID_IN_STATE)
      end

      def stop : OperationalCommandResponse
        transition(Command::Stop, STOPPED, COMMAND_INVALID_IN_STATE)
      end

      def start : OperationalCommandResponse
        transition(Command::Start, RUNNING, UNABLE_TO_START_OR_RESUME)
      end

      def resume : OperationalCommandResponse
        transition(Command::Resume, @last_active_state, UNABLE_TO_START_OR_RESUME)
      end

      def self.validate_identifier!(id : UInt8, label : String?, kind : String) : Nil
        manufacturer = id.in?(MANUFACTURER_FIRST..MANUFACTURER_LAST)
        if manufacturer && (label.nil? || label.empty?)
          raise ArgumentError.new("manufacturer #{kind} requires a label")
        end
        if !manufacturer && label
          raise ArgumentError.new("#{kind} label is only allowed for manufacturer IDs")
        end
        if label && label.bytesize > MAX_LABEL_BYTES
          raise ArgumentError.new("#{kind} label exceeds 64 bytes")
        end
        valid_base = kind == "state" ? id.in?(STOPPED..ERROR) : id.in?(NO_ERROR..COMMAND_INVALID_IN_STATE)
        unless valid_base || manufacturer
          raise ArgumentError.new("#{kind} ID is reserved by the generic cluster")
        end
      end

      private def transition(command : Command, target : UInt8, denial : UInt8) : OperationalCommandResponse
        current = @operational_state
        return command_response(NO_ERROR) if (command.pause? && current == PAUSED) ||
                                             (command.stop? && current == STOPPED) ||
                                             (command.start? || command.resume?) && current == RUNNING
        if command.pause? && current != RUNNING || command.resume? && current != PAUSED
          return command_response(COMMAND_INVALID_IN_STATE)
        end
        decision = @on_command.try(&.call(command)) || ErrorState.new(denial)
        unless decision.error_state_id == NO_ERROR ||
               decision.error_state_id == denial ||
               ((command.start? || command.resume?) && decision.error_state_id == COMMAND_INVALID_IN_STATE)
          decision = ErrorState.new(denial)
        end
        if decision.error_state_id == NO_ERROR
          report_state(target)
        end
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
        if commands.includes?(Command::Start) && !commands.includes?(Command::Stop)
          raise ArgumentError.new("Start requires Stop")
        end
        if commands.includes?(Command::Pause) != commands.includes?(Command::Resume)
          raise ArgumentError.new("Pause requires Resume and vice versa")
        end
        ids = states.map(&.operational_state_id)
        raise ArgumentError.new("duplicate OperationalStateList ID") unless ids.uniq.size == ids.size
        raise ArgumentError.new("OperationalStateList requires Error") unless ids.includes?(ERROR)
        raise ArgumentError.new("OperationalStateList requires Stopped initial state") unless ids.includes?(STOPPED)
        required = [] of UInt8
        required << STOPPED if commands.includes?(Command::Stop)
        required << RUNNING if commands.includes?(Command::Start) || commands.includes?(Command::Resume)
        required << PAUSED if commands.includes?(Command::Pause)
        unless required.all? { |id| ids.includes?(id) }
          raise ArgumentError.new("OperationalStateList omits a state required by an advertised command")
        end
      end

      private def validate_phases!(phases : Array(String)?, current : UInt8?) : Nil
        if phases
          raise ArgumentError.new("PhaseList exceeds 32 entries") if phases.size > MAX_PHASES
          raise ArgumentError.new("PhaseList entry exceeds 64 bytes") if phases.any? { |phase| phase.bytesize > MAX_LABEL_BYTES }
        end
        if current && (phases.nil? || current >= phases.size)
          raise ArgumentError.new("CurrentPhase is outside PhaseList")
        end
      end

      private def validate_countdown!(seconds : UInt32?) : Nil
        if seconds && seconds > MAX_COUNTDOWN
          raise ArgumentError.new("CountdownTime exceeds 259200 seconds")
        end
      end

      private def validate_error_code!(code : UInt8) : Nil
        valid = code.in?(NO_ERROR..COMMAND_INVALID_IN_STATE) || code.in?(MANUFACTURER_FIRST..MANUFACTURER_LAST)
        raise ArgumentError.new("completion error code is reserved") unless valid
      end
    end
  end
end
