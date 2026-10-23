require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Messages (0x0097), revision 3. Message contents and events
    # belong to the fabric that submitted them; active IDs span all fabrics.
    class Messages < Base
      cluster 0x0097, revision: 3, persist_state: false

      alias ExpiryTimer = Proc(Time::Span, Proc(Nil), Nil)

      MATTER_EPOCH_UNIX_SECONDS = 946_684_800_i64
      MAX_TIMER_DELAY           =      60_000_u64

      feature :received_confirmation, bit: 0
      feature :confirmation_response, bit: 1
      feature :confirmation_reply, bit: 2
      feature :protected_messages, bit: 3

      MAX_MESSAGES         =   8
      MESSAGE_ID_SIZE      =  16
      MAX_TEXT_BYTES       = 256
      MAX_RESPONSE_OPTIONS =   4
      MAX_LABEL_BYTES      =  32
      SUPPORTED_FEATURES   = Feature::None.value
      CONTROL_CONFIRMATION = 0x0001_u16
      CONTROL_RESPONSE     = 0x0002_u16
      CONTROL_REPLY        = 0x0004_u16
      CONTROL_CONFIRMED    = 0x0008_u16
      CONTROL_PROTECTED    = 0x0010_u16
      SUPPORTED_CONTROL    = CONTROL_CONFIRMATION | CONTROL_RESPONSE |
                             CONTROL_REPLY | CONTROL_CONFIRMED | CONTROL_PROTECTED

      enum Priority : UInt8
        Low
        Medium
        High
        Critical
      end

      enum FuturePreference : UInt8
        Allowed
        Increased
        Reduced
        Disallowed
        Banned
      end

      struct ResponseOption
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter response_id : UInt32

        @[TLV::Field(tag: 1)]
        getter label : String

        def initialize(@response_id : UInt32, @label : String)
        end
      end

      struct PresentRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, fixed_size: true)]
        getter message_id : Bytes

        @[TLV::Field(tag: 1)]
        getter priority : Priority

        @[TLV::Field(tag: 2)]
        getter control : UInt16

        @[TLV::Field(tag: 3, optional: false)]
        getter start_time : UInt32?

        @[TLV::Field(tag: 4, optional: false)]
        getter duration : UInt64?

        @[TLV::Field(tag: 5)]
        getter text : String

        @[TLV::Field(tag: 6, optional: true)]
        getter responses : Array(ResponseOption)?

        def initialize(@message_id : Bytes, @priority : Priority, @control : UInt16,
                       @start_time : UInt32?, @duration : UInt64?, @text : String,
                       @responses : Array(ResponseOption)? = nil)
          raise ArgumentError.new("MessageID must be 16 bytes") unless @message_id.size == MESSAGE_ID_SIZE
        end
      end

      struct CancelRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter message_ids : Array(Bytes)

        def initialize(@message_ids : Array(Bytes))
        end
      end

      struct Message
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, fixed_size: true)]
        getter message_id : Bytes

        @[TLV::Field(tag: 1)]
        getter priority : Priority

        @[TLV::Field(tag: 2)]
        getter control : UInt16

        @[TLV::Field(tag: 3, optional: false)]
        getter start_time : UInt32?

        @[TLV::Field(tag: 4, optional: false)]
        getter duration : UInt64?

        @[TLV::Field(tag: 5)]
        getter text : String

        @[TLV::Field(tag: 6, optional: true)]
        getter responses : Array(ResponseOption)?

        @[TLV::Field(tag: 254)]
        getter fabric_index : UInt8

        def initialize(request : PresentRequest, @fabric_index : UInt8)
          @message_id = request.message_id.dup
          @priority = request.priority
          @control = request.control
          @start_time = request.start_time
          @duration = request.duration
          @text = request.text
          @responses = request.responses.try(&.dup)
        end

        def initialize(@message_id : Bytes, @priority : Priority, @control : UInt16,
                       @start_time : UInt32?, @duration : UInt64?, @text : String,
                       @responses : Array(ResponseOption)?, @fabric_index : UInt8)
        end
      end

      struct MessageIdEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, fixed_size: true)]
        getter message_id : Bytes

        def initialize(@message_id : Bytes)
        end
      end

      struct MessageCompleteEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, fixed_size: true)]
        getter message_id : Bytes

        @[TLV::Field(tag: 1, optional: true)]
        getter response_id : UInt32?

        @[TLV::Field(tag: 2, optional: true)]
        getter reply : String?

        @[TLV::Field(tag: 3, optional: false)]
        getter future_preference : FuturePreference?

        def initialize(@message_id : Bytes, @response_id : UInt32? = nil,
                       @reply : String? = nil, @future_preference : FuturePreference? = nil)
        end
      end

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter messages : Array(Message)
        getter active_message_ids : Array(Bytes)
        getter accepted_at_ms : Hash(String, Int64) = {} of String => Int64

        def initialize(@data_version : UInt32, @messages : Array(Message), @active_message_ids : Array(Bytes),
                       @accepted_at_ms : Hash(String, Int64) = {} of String => Int64)
        end
      end

      attribute 0x0000, :messages, Array(Message), computed: true, fabric_scoped: true
      attribute 0x0001, :active_message_ids, Array(Bytes), computed: true

      command 0x00, :present_messages_request, request: PresentRequest, access: :operate
      command 0x01, :cancel_messages_request, request: CancelRequest, access: :operate

      event 0x00, :message_queued, priority: :info, payload: MessageIdEvent
      event 0x01, :message_presented, priority: :info, payload: MessageIdEvent
      event 0x02, :message_complete, priority: :info, payload: MessageCompleteEvent

      @messages = [] of Message
      @active_message_ids = [] of Bytes
      @accepted_at_ms = {} of String => Int64
      @expiry_generation = 0_u64

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
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
        raise ArgumentError.new("optional Messages features require a host implementation") if (@feature_map.value & ~SUPPORTED_FEATURES) != 0
      end

      def messages(fabric_index : UInt8?) : Array(Message) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        entries = request_fabric_filtered? ? @messages.select(&.fabric_index.==(fabric_index)) : @messages
        entries.map { |entry| Message.from_document(entry.to_document) }
      end

      def active_message_ids : Array(Bytes)
        @active_message_ids.map(&.dup)
      end

      def present_messages_request(request : PresentRequest) : InteractionModel::Status
        fabric_index = command_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric_index
        validate_request!(request)
        return InteractionModel::Status.constraint_error if @messages.any? { |entry| entry.message_id == request.message_id }
        return InteractionModel::Status.resource_exhausted if @messages.size >= MAX_MESSAGES
        @messages << Message.new(request, fabric_index)
        @accepted_at_ms[request.message_id.hexstring] = @clock.call.to_unix_ms if request.start_time.nil? && request.duration
        increment_version_and_notify(ATTR_MESSAGES)
        emit_message_queued(MessageIdEvent.new(request.message_id.dup), fabric_index)
        schedule_expiry
        InteractionModel::Status.success
      end

      def cancel_messages_request(request : CancelRequest) : InteractionModel::Status
        fabric_index = command_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric_index
        raise ArgumentError.new("too many MessageIDs") if request.message_ids.size > MAX_MESSAGES
        request.message_ids.each { |id| validate_message_id!(id) }
        owned = @messages.select { |entry| entry.fabric_index == fabric_index && request.message_ids.includes?(entry.message_id) }
        return InteractionModel::Status.success if owned.empty?
        @messages.reject! { |entry| owned.any? { |other| other.message_id == entry.message_id } }
        @active_message_ids.reject! { |id| owned.any? { |entry| entry.message_id == id } }
        owned.each { |entry| @accepted_at_ms.delete(entry.message_id.hexstring) }
        increment_version_and_notify(ATTR_MESSAGES)
        notify_changed(ATTR_ACTIVE_MESSAGE_IDS)
        schedule_expiry
        InteractionModel::Status.success
      end

      def present(message_id : Bytes, fabric_index : UInt8) : Nil
        message = @messages.find { |entry| entry.fabric_index == fabric_index && entry.message_id == message_id }
        raise ArgumentError.new("unknown message") unless message
        now_ms = @clock.call.to_unix_ms.to_u128
        raise ArgumentError.new("message is not yet available") if now_ms < start_ms(message)
        if (deadline = deadline_ms(message)) && now_ms >= deadline
          process_due_messages
          raise ArgumentError.new("message has expired")
        end
        return if @active_message_ids.includes?(message_id)
        @active_message_ids << message_id.dup
        increment_version_and_notify(ATTR_ACTIVE_MESSAGE_IDS)
        emit_message_presented(MessageIdEvent.new(message_id.dup), fabric_index)
      end

      def complete(message_id : Bytes, fabric_index : UInt8,
                   response_id : UInt32? = nil, reply : String? = nil,
                   future_preference : FuturePreference? = nil) : Nil
        raise ArgumentError.new("responses require optional Messages features") if response_id || reply
        message = @messages.find { |entry| entry.fabric_index == fabric_index && entry.message_id == message_id }
        raise ArgumentError.new("unknown message") unless message
        @active_message_ids.reject!(&.==(message_id))
        @messages.reject! { |entry| entry.fabric_index == fabric_index && entry.message_id == message_id }
        @accepted_at_ms.delete(message_id.hexstring)
        increment_version_and_notify(ATTR_MESSAGES)
        notify_changed(ATTR_ACTIVE_MESSAGE_IDS)
        emit_message_complete(MessageCompleteEvent.new(message_id.dup, response_id, reply, future_preference), fabric_index)
        schedule_expiry
      end

      # Processes elapsed message durations; also useful for hosts with a
      # deterministic clock or their own event loop.
      def process_due_messages : Nil
        now_ms = @clock.call.to_unix_ms.to_u128
        expired = @messages.select { |message| (deadline = deadline_ms(message)) && deadline <= now_ms }
        expired.each { |message| complete(message.message_id, message.fabric_index) }
        schedule_expiry if expired.empty?
      end

      def remove_fabric(fabric_index : UInt8) : Nil
        ids = @messages.select(&.fabric_index.==(fabric_index)).map(&.message_id)
        return if ids.empty?
        @messages.reject!(&.fabric_index.==(fabric_index))
        @active_message_ids.reject! { |id| ids.includes?(id) }
        ids.each { |id| @accepted_at_ms.delete(id.hexstring) }
        increment_version_and_notify(ATTR_MESSAGES)
        notify_changed(ATTR_ACTIVE_MESSAGE_IDS)
        schedule_expiry
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @messages, @active_message_ids, @accepted_at_ms).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        raise ArgumentError.new("too many messages") if state.messages.size > MAX_MESSAGES
        state.messages.each { |message| validate_message!(message) }
        ids = state.messages.map(&.message_id)
        raise ArgumentError.new("duplicate MessageIDs") if ids.uniq.size != ids.size
        raise ArgumentError.new("duplicate active MessageIDs") if state.active_message_ids.uniq.size != state.active_message_ids.size
        raise ArgumentError.new("unknown active MessageID") unless state.active_message_ids.all? { |id| ids.includes?(id) }
        @data_version = state.data_version
        @messages = state.messages
        @active_message_ids = state.active_message_ids
        @accepted_at_ms = state.accepted_at_ms
        now_ms = @clock.call.to_unix_ms
        @messages.each do |message|
          if message.start_time.nil? && message.duration
            @accepted_at_ms[message.message_id.hexstring] ||= now_ms
          end
        end
        process_due_messages
      end

      private def start_ms(message : Message) : UInt128
        if start = message.start_time
          (start.to_u128 + MATTER_EPOCH_UNIX_SECONDS.to_u128) * 1000_u128
        else
          (@accepted_at_ms[message.message_id.hexstring]? || @clock.call.to_unix_ms).to_u128
        end
      end

      private def deadline_ms(message : Message) : UInt128?
        message.duration.try { |duration| start_ms(message) + duration.to_u128 }
      end

      private def schedule_expiry : Nil
        @expiry_generation &+= 1
        generation = @expiry_generation
        deadline = @messages.compact_map { |message| deadline_ms(message) }.min?
        return unless deadline
        now_ms = @clock.call.to_unix_ms.to_u128
        remaining = deadline > now_ms ? deadline - now_ms : 0_u128
        delay = {remaining, MAX_TIMER_DELAY.to_u128}.min.to_i64.milliseconds
        @expiry_timer.call(delay, -> { expire_if_current(generation) })
      end

      private def expire_if_current(generation : UInt64) : Nil
        process_due_messages if generation == @expiry_generation
      end

      private def command_fabric_index : UInt8?
        return unless request_is_case_session?
        request_fabric_index
      end

      private def validate_request!(request : PresentRequest) : Nil
        validate_message_id!(request.message_id)
        validate_fields!(request.control, request.text, request.responses)
      end

      private def validate_message!(message : Message) : Nil
        validate_message_id!(message.message_id)
        raise ArgumentError.new("fabric index must be nonzero") if message.fabric_index == DataType::NO_FABRIC
        validate_fields!(message.control, message.text, message.responses)
      end

      private def validate_message_id!(id : Bytes) : Nil
        raise ArgumentError.new("MessageID must be 16 bytes") unless id.size == MESSAGE_ID_SIZE
      end

      private def validate_fields!(control : UInt16, content : String, responses : Array(ResponseOption)?) : Nil
        raise ArgumentError.new("unknown MessageControl bits") if (control & ~SUPPORTED_CONTROL) != 0
        raise ArgumentError.new("message text exceeds 256 bytes") if content.bytesize > MAX_TEXT_BYTES
        raise ArgumentError.new("CONF required") if (control & (CONTROL_CONFIRMATION | CONTROL_CONFIRMED)) != 0 && !@feature_map.received_confirmation?
        raise ArgumentError.new("RESP required") if (control & CONTROL_RESPONSE) != 0 && !@feature_map.confirmation_response?
        raise ArgumentError.new("RPLY required") if (control & CONTROL_REPLY) != 0 && !@feature_map.confirmation_reply?
        raise ArgumentError.new("PROT required") if (control & CONTROL_PROTECTED) != 0 && !@feature_map.protected_messages?
        if responses
          raise ArgumentError.new("too many responses") if responses.size > MAX_RESPONSE_OPTIONS
          raise ArgumentError.new("RESP required") unless @feature_map.confirmation_response?
          raise ArgumentError.new("response IDs must be unique and positive") if responses.any?(&.response_id.==(0_u32)) || responses.map(&.response_id).uniq!.size != responses.size
          raise ArgumentError.new("response label too long") if responses.any? { |option| option.label.bytesize > MAX_LABEL_BYTES }
        end
      end
    end
  end
end
