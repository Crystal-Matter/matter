require "./cluster"
require "uri"

module Matter
  module Cluster
    # Matter 1.6 Actions (0x0025, revision 1). The application owns the
    # actual action; this cluster validates requests and publishes its state.
    class Actions < Base
      cluster 0x0025, revision: 1

      MAX_ENTRIES    = 256
      MAX_NAME_BYTES = 128
      MAX_NAME_CHARS =  32
      MAX_URL_BYTES  = 512

      enum ActionType : UInt8
        Other
        Scene
        Sequence
        Automation
        Exception
        Notification
        Alarm
      end

      enum ActionState : UInt8
        Inactive
        Active
        Paused
        Disabled
      end

      enum ActionError : UInt8
        Unknown
        Interrupted
      end

      enum EndpointListType : UInt8
        Other
        Room
        Zone
      end

      enum ActionCommand : UInt8
        InstantAction
        InstantActionWithTransition
        StartAction
        StartActionWithDuration
        StopAction
        PauseAction
        PauseActionWithDuration
        ResumeAction
        EnableAction
        EnableActionWithDuration
        DisableAction
        DisableActionWithDuration
      end

      @[Flags]
      enum CommandBits : UInt16
        InstantAction               = 1 << 0
        InstantActionWithTransition = 1 << 1
        StartAction                 = 1 << 2
        StartActionWithDuration     = 1 << 3
        StopAction                  = 1 << 4
        PauseAction                 = 1 << 5
        PauseActionWithDuration     = 1 << 6
        ResumeAction                = 1 << 7
        EnableAction                = 1 << 8
        EnableActionWithDuration    = 1 << 9
        DisableAction               = 1 << 10
        DisableActionWithDuration   = 1 << 11
      end

      struct Action
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property action_id : UInt16

        @[TLV::Field(tag: 1)]
        property name : String

        @[TLV::Field(tag: 2)]
        property type : ActionType

        @[TLV::Field(tag: 3)]
        property endpoint_list_id : UInt16

        @[TLV::Field(tag: 4)]
        property supported_commands : CommandBits

        @[TLV::Field(tag: 5)]
        property state : ActionState

        def initialize(@action_id : UInt16, @name : String, @type : ActionType,
                       @endpoint_list_id : UInt16, @supported_commands : CommandBits,
                       @state : ActionState)
          Actions.validate_name!(@name)
          if @supported_commands.value & ~0x0FFF_u16 != 0
            raise ArgumentError.new("action supported commands exceed the revision-one bitmap")
          end
        end
      end

      struct EndpointList
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property endpoint_list_id : UInt16

        @[TLV::Field(tag: 1)]
        property name : String

        @[TLV::Field(tag: 2)]
        property type : EndpointListType

        @[TLV::Field(tag: 3)]
        property endpoints : Array(UInt16)

        def initialize(@endpoint_list_id : UInt16, @name : String, @type : EndpointListType,
                       @endpoints : Array(UInt16))
          Actions.validate_name!(@name)
          raise ArgumentError.new("endpoint list exceeds 256 endpoints") if @endpoints.size > MAX_ENTRIES
          raise ArgumentError.new("endpoint list contains duplicate endpoints") if @endpoints.uniq.size != @endpoints.size
          @endpoints = @endpoints.dup
        end
      end

      struct ActionRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property action_id : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        property invoke_id : UInt32?

        def initialize(@action_id : UInt16, @invoke_id : UInt32? = nil)
        end
      end

      struct TransitionRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property action_id : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        property invoke_id : UInt32?

        @[TLV::Field(tag: 2)]
        property transition_time : UInt16

        def initialize(@action_id : UInt16, @transition_time : UInt16, @invoke_id : UInt32? = nil)
        end
      end

      struct DurationRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property action_id : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        property invoke_id : UInt32?

        @[TLV::Field(tag: 2)]
        property duration : UInt32

        def initialize(@action_id : UInt16, @duration : UInt32, @invoke_id : UInt32? = nil)
        end
      end

      struct StateChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property action_id : UInt16

        @[TLV::Field(tag: 1)]
        property invoke_id : UInt32

        @[TLV::Field(tag: 2)]
        property new_state : ActionState

        def initialize(@action_id : UInt16, @invoke_id : UInt32, @new_state : ActionState)
        end
      end

      struct ActionFailedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property action_id : UInt16

        @[TLV::Field(tag: 1)]
        property invoke_id : UInt32

        @[TLV::Field(tag: 2)]
        property new_state : ActionState

        @[TLV::Field(tag: 3)]
        property error : ActionError

        def initialize(@action_id : UInt16, @invoke_id : UInt32, @new_state : ActionState,
                       @error : ActionError)
        end
      end

      alias ExecuteCallback = Proc(Action, ActionCommand, UInt32?, UInt32?, InteractionModel::Status)

      attribute 0x0000, :action_list, Array(Action), default: [] of Action
      attribute 0x0001, :endpoint_lists, Array(EndpointList), default: [] of EndpointList
      attribute 0x0002, :setup_url, String, default: "", optional: true,
        present_if: :setup_url_present?, max_length: MAX_URL_BYTES

      command 0x00, :instant_action, request: ActionRequest, access: :operate, present_if: :command_advertised?
      command 0x01, :instant_action_with_transition, request: TransitionRequest, access: :operate, present_if: :command_advertised?
      command 0x02, :start_action, request: ActionRequest, access: :operate, present_if: :command_advertised?
      command 0x03, :start_action_with_duration, request: DurationRequest, access: :operate, present_if: :command_advertised?
      command 0x04, :stop_action, request: ActionRequest, access: :operate, present_if: :command_advertised?
      command 0x05, :pause_action, request: ActionRequest, access: :operate, present_if: :command_advertised?
      command 0x06, :pause_action_with_duration, request: DurationRequest, access: :operate, present_if: :command_advertised?
      command 0x07, :resume_action, request: ActionRequest, access: :operate, present_if: :command_advertised?
      command 0x08, :enable_action, request: ActionRequest, access: :operate, present_if: :command_advertised?
      command 0x09, :enable_action_with_duration, request: DurationRequest, access: :operate, present_if: :command_advertised?
      command 0x0A, :disable_action, request: ActionRequest, access: :operate, present_if: :command_advertised?
      command 0x0B, :disable_action_with_duration, request: DurationRequest, access: :operate, present_if: :command_advertised?

      event 0x00, :state_changed, priority: :info, payload: StateChangedEvent
      event 0x01, :action_failed, priority: :info, payload: ActionFailedEvent

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @action_list : Array(Action) = [] of Action,
                     @endpoint_lists : Array(EndpointList) = [] of EndpointList,
                     setup_url : String? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_lists!(@action_list, @endpoint_lists)
        validate_url!(setup_url)
        @action_list = @action_list.dup
        @endpoint_lists = @endpoint_lists.dup
        @setup_url = setup_url || ""
        @execute_callback = nil
        @timer_generation = {} of UInt16 => UInt64
        @last_invoke_id = {} of UInt16 => UInt32?
      end

      def self.validate_name!(name : String) : Nil
        if name.bytesize > MAX_NAME_BYTES || name.size > MAX_NAME_CHARS
          raise ArgumentError.new("action or endpoint list name exceeds Matter limits")
        end
      end

      def on_execute(&block : Action, ActionCommand, UInt32?, UInt32? -> InteractionModel::Status) : Nil
        @execute_callback = block
      end

      # For actions whose work completes outside an Invoke, hosts report the
      # resulting state explicitly. Feedback uses the latest command's InvokeID.
      def update_action_state(action_id : UInt16, state : ActionState) : Nil
        index = action_index!(action_id)
        @timer_generation[action_id] = (@timer_generation[action_id]? || 0_u64) &+ 1_u64
        set_state(index, state, @last_invoke_id[action_id]?)
      end

      def fail_action(action_id : UInt16, state : ActionState, error : ActionError) : Nil
        index = action_index!(action_id)
        @timer_generation[action_id] = (@timer_generation[action_id]? || 0_u64) &+ 1_u64
        set_state(index, state, nil)
        if invoke_id = @last_invoke_id[action_id]?
          emit_event(EVENT_ACTION_FAILED, ActionFailedEvent.new(action_id, invoke_id, state, error))
        end
      end

      def instant_action(request : ActionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::InstantAction)
      end

      def instant_action_with_transition(request : TransitionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::InstantActionWithTransition,
          request.transition_time.to_u32)
      end

      def start_action(request : ActionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::StartAction)
      end

      def start_action_with_duration(request : DurationRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::StartActionWithDuration, request.duration)
      end

      def stop_action(request : ActionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::StopAction)
      end

      def pause_action(request : ActionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::PauseAction)
      end

      def pause_action_with_duration(request : DurationRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::PauseActionWithDuration, request.duration)
      end

      def resume_action(request : ActionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::ResumeAction)
      end

      def enable_action(request : ActionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::EnableAction)
      end

      def enable_action_with_duration(request : DurationRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::EnableActionWithDuration, request.duration)
      end

      def disable_action(request : ActionRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::DisableAction)
      end

      def disable_action_with_duration(request : DurationRequest) : InteractionModel::Status
        execute(request.action_id, request.invoke_id, ActionCommand::DisableActionWithDuration, request.duration)
      end

      private def setup_url_present? : Bool
        !@setup_url.empty?
      end

      private def command_advertised?(id : UInt32) : Bool
        bit = CommandBits.from_value(1_u16 << id)
        @action_list.any?(&.supported_commands.includes?(bit))
      end

      private def validate_lists!(actions : Array(Action), lists : Array(EndpointList)) : Nil
        raise ArgumentError.new("Actions lists exceed 256 entries") if actions.size > MAX_ENTRIES || lists.size > MAX_ENTRIES
        list_ids = lists.map(&.endpoint_list_id)
        raise ArgumentError.new("duplicate EndpointListID") if list_ids.uniq.size != list_ids.size
        action_ids = actions.map(&.action_id)
        raise ArgumentError.new("duplicate ActionID") if action_ids.uniq.size != action_ids.size
        unless actions.all? { |action| list_ids.includes?(action.endpoint_list_id) }
          raise ArgumentError.new("action references missing EndpointListID")
        end
        room_endpoints = lists.select(&.type.room?).flat_map(&.endpoints)
        raise ArgumentError.new("endpoint belongs to multiple rooms") if room_endpoints.uniq.size != room_endpoints.size
      end

      private def validate_url!(url : String?) : Nil
        return unless url
        parsed = URI.parse(url)
        if url.bytesize > MAX_URL_BYTES || !url.ascii_only? || parsed.scheme != "https" ||
           parsed.host.nil? || url.includes?(' ')
          raise ArgumentError.new("SetupURL must be an HTTPS URL of at most 512 ASCII bytes")
        end
      rescue URI::Error
        raise ArgumentError.new("SetupURL must be a valid HTTPS URL")
      end

      private def action_index!(id : UInt16) : Int32
        @action_list.index { |action| action.action_id == id } || raise ArgumentError.new("unknown ActionID")
      end

      private def execute(id : UInt16, invoke_id : UInt32?, command : ActionCommand,
                          parameter : UInt32? = nil) : InteractionModel::Status
        index = @action_list.index { |action| action.action_id == id }
        return InteractionModel::Status.not_found unless index
        action = @action_list[index]
        bit = CommandBits.from_value(1_u16 << command.value)
        return InteractionModel::Status.invalid_command unless action.supported_commands.includes?(bit)
        callback = @execute_callback
        return InteractionModel::Status.invalid_in_state unless callback
        result = callback.call(action, command, invoke_id, parameter)
        unless result.success?
          if invoke_id
            emit_event(EVENT_ACTION_FAILED, ActionFailedEvent.new(id, invoke_id, action.state, ActionError::Unknown))
          end
          return result
        end
        @last_invoke_id[id] = invoke_id
        generation = (@timer_generation[id]? || 0_u64) &+ 1_u64
        @timer_generation[id] = generation
        target = case command
                 when .instant_action?, .stop_action?              then ActionState::Inactive
                 when .disable_action_with_duration?               then ActionState::Disabled
                 when .disable_action?                             then ActionState::Inactive
                 when .pause_action?, .pause_action_with_duration? then ActionState::Paused
                 else                                                   ActionState::Active
                 end
        set_state(index, target, invoke_id)
        schedule_completion(id, command, parameter, generation, invoke_id, action.state)
        InteractionModel::Status.success
      end

      private def set_state(index : Int32, state : ActionState, invoke_id : UInt32?) : Nil
        action = @action_list[index]
        return if action.state == state
        action.state = state
        updated = @action_list.dup
        updated[index] = action
        self.action_list = updated
        if invoke_id
          emit_event(EVENT_STATE_CHANGED, StateChangedEvent.new(action.action_id, invoke_id, state))
        end
      end

      private def schedule_completion(id : UInt16, command : ActionCommand, parameter : UInt32?,
                                      generation : UInt64, invoke_id : UInt32?, prior_state : ActionState) : Nil
        return unless value = parameter
        seconds, ending_state, ending_command = case command
                                                when .instant_action_with_transition?
                                                  {value.to_f / 10.0, ActionState::Inactive, ActionCommand::StopAction}
                                                when .start_action_with_duration?
                                                  {value.to_f, ActionState::Inactive, ActionCommand::StopAction}
                                                when .pause_action_with_duration?
                                                  {value.to_f, ActionState::Active, ActionCommand::ResumeAction}
                                                when .enable_action_with_duration?
                                                  {value.to_f, ActionState::Disabled, ActionCommand::DisableAction}
                                                when .disable_action_with_duration?
                                                  restored = prior_state.active? ? ActionState::Active : ActionState::Inactive
                                                  {value.to_f, restored, ActionCommand::EnableAction}
                                                else
                                                  return
                                                end
        spawn do
          sleep seconds.seconds
          next unless @timer_generation[id]? == generation
          index = @action_list.index { |action| action.action_id == id }
          next unless index
          if callback = @execute_callback
            result = callback.call(@action_list[index], ending_command, invoke_id, nil)
            if result.success?
              set_state(index, ending_state, invoke_id)
            elsif invoke_id
              emit_event(EVENT_ACTION_FAILED,
                ActionFailedEvent.new(id, invoke_id, @action_list[index].state, ActionError::Unknown))
            end
          end
        end
      end
    end
  end
end
