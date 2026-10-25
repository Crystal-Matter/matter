require "uri"
require "./cluster"
require "./push_av_stream_transport/types"

module Matter
  module Cluster
    # Matter 1.6 Push AV Stream Transport, revision 2. This server owns the
    # fabric-scoped configuration and events. The application owns transport
    # establishment, stream selection, media capture, and CMAF upload.
    class PushAvStreamTransport < Base
      cluster 0x0555, revision: 2, persist_state: false

      feature :per_zone_sensitivity, bit: 0
      feature :metadata, bit: 1

      MAX_CONNECTION_ID      = 65534_u16
      MIN_URL_BYTES          =        13
      MAX_URL_BYTES          =      2000
      MAX_STREAMS            =        16
      MAX_STREAM_NAME_BYTES  =        16
      MAX_USER_DEFINED_BYTES =       256
      MIN_SEGMENT_DURATION   =   500_u16
      MAX_SEGMENT_DURATION   = 65500_u16
      MIN_SENSITIVITY        =      1_u8
      MAX_SENSITIVITY        =     10_u8
      MAX_TIMER_DELAY        =    60_i64

      alias ExpiryTimer = Proc(Time::Span, Proc(Nil), Nil)

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter connections : Array(Tlv::TransportConfiguration)
        getter next_connection_id : UInt16
        getter expiry_deadlines : Hash(UInt16, Time) = {} of UInt16 => Time

        def initialize(@data_version, @connections, @next_connection_id, @expiry_deadlines); end
      end

      attribute 0x0000, :supported_formats, Array(Tlv::SupportedFormat), computed: true, fixed: true
      attribute 0x0001, :current_connections, Array(Tlv::TransportConfiguration), computed: true, fabric_scoped: true

      command 0x00, :allocate_push_transport, request: Tlv::AllocateRequest, response_id: 0x01, access: :manage
      command 0x02, :deallocate_push_transport, request: Tlv::DeallocateRequest, access: :manage
      command 0x03, :modify_push_transport, request: Tlv::ModifyRequest, access: :manage
      command 0x04, :set_transport_status, request: Tlv::SetStatusRequest, access: :manage
      command 0x05, :manually_trigger_transport, request: Tlv::ManualTriggerRequest, access: :operate
      command 0x06, :find_transport, request: Tlv::FindRequest, response_id: 0x07, access: :operate

      event 0x00, :push_transport_begin, priority: :info, payload: Tlv::BeginEvent
      event 0x01, :push_transport_end, priority: :info, payload: Tlv::EndEvent

      @connections = [] of Tlv::TransportConfiguration
      @next_connection_id = 0_u16
      @expiry_deadlines = {} of UInt16 => Time
      @expiry_generation = 0_u64
      @active_sessions = {} of UInt16 => UInt64

      property fabric_installed : Proc(UInt8, Bool)?
      property tls_endpoint_exists : Proc(UInt8, UInt16, Bool)?
      property video_stream_exists : Proc(UInt16, Bool)?
      property audio_stream_exists : Proc(UInt16, Bool)?
      property select_video_stream : Proc(UInt8, StreamUsage, UInt16)?
      property select_audio_stream : Proc(UInt8, StreamUsage, UInt16)?
      property zone_exists : Proc(UInt16, Bool)?
      property pre_roll_valid : Proc(UInt16, Bool)?
      property time_valid : Proc(Bool)?
      property on_persist : Proc(Nil)?
      property on_status_change : Proc(UInt8, UInt16, TransportStatus, Bool)?
      property on_manual_trigger : Proc(UInt8, UInt16, ActivationReason, Tlv::MotionTimeControl?, Bytes?, Bool)?
      property on_reference_change : Proc(UInt8, UInt16, Int8, Bool)?
      property on_modify_active : Proc(UInt8, UInt16, Tlv::TransportOptions, Bool)?
      property privacy_allows : Proc(StreamUsage, Bool)?
      property transport_busy : Proc(UInt8, UInt16, Bool)?

      def initialize(endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
                     @feature_map : Feature = Feature::None,
                     @clock : Proc(Time) = -> { Time.utc }, expiry_timer : ExpiryTimer? = nil)
        @expiry_timer = expiry_timer || ->(delay : Time::Span, callback : Proc(Nil)) do
          spawn do
            sleep delay
            callback.call
          end
          nil
        end
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # The only mandatory SupportedFormats combination in revision 2.
      def supported_formats : Array(Tlv::SupportedFormat)
        [Tlv::SupportedFormat.new(ContainerFormat::Cmaf, IngestMethod::CmafIngest)]
      end

      def current_connections(fabric_index : UInt8?) : Array(Tlv::TransportConfiguration) | InteractionModel::Status
        expire_due
        return InteractionModel::Status.unsupported_access unless fabric_index && request_is_case_session?
        return InteractionModel::Status.unsupported_access unless valid_fabric?(fabric_index)
        # Attribute reads can run on transports without Large Message support.
        # FindTransport is the complete representation of TransportOptions.
        @connections.select(&.fabric_index.==(fabric_index)).map do |entry|
          Tlv::TransportConfiguration.new(entry.connection_id, entry.transport_status, nil, entry.fabric_index)
        end
      end

      def allocate_push_transport(request : Tlv::AllocateRequest) : Tlv::AllocateResponse | InteractionModel::Status
        expire_due
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        options = resolve_streams(request.transport_options, fabric)
        return options if options.is_a?(InteractionModel::Status)
        validation = validate_options(options, fabric)
        return validation unless validation.success?
        id = next_id
        return InteractionModel::Status.resource_exhausted unless id
        if @on_reference_change.try(&.call(fabric, options.tls_endpoint_id, 1_i8)) == false
          return InteractionModel::Status.invalid_in_state
        end
        entry = Tlv::TransportConfiguration.new(id, TransportStatus::Inactive,
          clone_options(options), fabric)
        @connections << entry
        if ttl = options.expiry_time
          @expiry_deadlines[id] = @clock.call + ttl.seconds
        end
        changed
        schedule_expiry
        Tlv::AllocateResponse.new(clone_configuration(entry))
      end

      def deallocate_push_transport(request : Tlv::DeallocateRequest) : InteractionModel::Status
        expire_due
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.connection_id > MAX_CONNECTION_ID
        entry = find_owned(fabric, request.connection_id)
        return InteractionModel::Status.not_found unless entry
        if entry.transport_status.active?
          return InteractionModel::Status.invalid_in_state unless @on_status_change.try(&.call(fabric, entry.connection_id, TransportStatus::Inactive))
        end
        if options = entry.transport_options
          return InteractionModel::Status.invalid_in_state if @on_reference_change.try(&.call(fabric, options.tls_endpoint_id, -1_i8)) == false
        end
        close_session(entry)
        @connections.delete(entry)
        @expiry_deadlines.delete(entry.connection_id)
        changed
        schedule_expiry
        InteractionModel::Status.success
      end

      def modify_push_transport(request : Tlv::ModifyRequest) : InteractionModel::Status
        expire_due
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.connection_id > MAX_CONNECTION_ID
        entry = find_owned(fabric, request.connection_id)
        return InteractionModel::Status.not_found unless entry
        options = resolve_streams(request.transport_options, fabric)
        return options if options.is_a?(InteractionModel::Status)
        validation = validate_options(options, fabric)
        return validation unless validation.success?
        if entry.transport_status.active?
          return InteractionModel::Status.invalid_in_state unless @on_modify_active.try(&.call(fabric, entry.connection_id, options))
        end
        old_options = entry.transport_options || return InteractionModel::Status.invalid_in_state
        if old_options.tls_endpoint_id != options.tls_endpoint_id
          if @on_reference_change.try(&.call(fabric, options.tls_endpoint_id, 1_i8)) == false
            return InteractionModel::Status.invalid_in_state
          end
          if @on_reference_change.try(&.call(fabric, old_options.tls_endpoint_id, -1_i8)) == false
            @on_reference_change.try(&.call(fabric, options.tls_endpoint_id, -1_i8))
            return InteractionModel::Status.invalid_in_state
          end
        end
        replace(entry, Tlv::TransportConfiguration.new(entry.connection_id, entry.transport_status,
          clone_options(options), fabric))
        if ttl = options.expiry_time
          @expiry_deadlines[entry.connection_id] = @clock.call + ttl.seconds
        else
          @expiry_deadlines.delete(entry.connection_id)
        end
        changed
        schedule_expiry
        InteractionModel::Status.success
      end

      # ameba:disable Naming/AccessorMethodName
      def set_transport_status(request : Tlv::SetStatusRequest) : InteractionModel::Status
        expire_due
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        if id = request.connection_id
          return InteractionModel::Status.constraint_error if id > MAX_CONNECTION_ID
        end
        owned = @connections.select { |entry| entry.fabric_index == fabric && (request.connection_id.nil? || entry.connection_id == request.connection_id) }
        return InteractionModel::Status.not_found if owned.empty? && request.connection_id
        return InteractionModel::Status.success if owned.empty?
        if request.transport_status.active? && @on_status_change.nil?
          return InteractionModel::Status.invalid_in_state
        end
        owned.each do |entry|
          next if entry.transport_status == request.transport_status
          if callback = @on_status_change
            return InteractionModel::Status.invalid_in_state unless callback.call(fabric, entry.connection_id, request.transport_status)
          end
        end
        owned.each do |entry|
          next if entry.transport_status == request.transport_status
          close_session(entry) if request.transport_status.inactive?
          replace(entry, Tlv::TransportConfiguration.new(entry.connection_id, request.transport_status,
            entry.transport_options, fabric))
        end
        changed if owned.any? { |entry| entry.transport_status != request.transport_status }
        InteractionModel::Status.success
      end

      def manually_trigger_transport(request : Tlv::ManualTriggerRequest) : InteractionModel::Status
        expire_due
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.connection_id > MAX_CONNECTION_ID
        return InteractionModel::Status.constraint_error if request.user_defined.try { |bytes| bytes.size > MAX_USER_DEFINED_BYTES }
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if request.user_defined && !feature_map.metadata?
        entry = find_owned(fabric, request.connection_id)
        return InteractionModel::Status.not_found unless entry
        options = entry.transport_options || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state if @privacy_allows.try { |check| !check.call(options.stream_usage) }
        return InteractionModel::Status.busy if @active_sessions.has_key?(entry.connection_id)
        return InteractionModel::Status.busy if @transport_busy.try(&.call(fabric, entry.connection_id))
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidTransportStatus) unless entry.transport_status.active?
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidTriggerType) if options.trigger_options.trigger_type.continuous?
        control = request.time_control || options.trigger_options.motion_time_control
        if options.trigger_options.trigger_type.command? && !control
          return InteractionModel::Status.dynamic_constraint_error
        end
        if control
          return InteractionModel::Status.constraint_error unless valid_time_control?(control)
        end
        callback = @on_manual_trigger
        return InteractionModel::Status.invalid_in_state unless callback
        return InteractionModel::Status.invalid_in_state unless callback.call(fabric, entry.connection_id,
                                                                  request.activation_reason, control, request.user_defined)
        # The host emits Begin/End only when upload actually starts/stops.
        InteractionModel::Status.success
      end

      def find_transport(request : Tlv::FindRequest) : Tlv::FindResponse | InteractionModel::Status
        expire_due
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        if id = request.connection_id
          return InteractionModel::Status.constraint_error if id > MAX_CONNECTION_ID
        end
        entries = @connections.select { |entry| entry.fabric_index == fabric && (request.connection_id.nil? || entry.connection_id == request.connection_id) }
        return InteractionModel::Status.not_found if entries.empty?
        Tlv::FindResponse.new(entries.map { |entry| clone_configuration(entry) })
      end

      # Call only after a host transport actually begins or ends transmission.
      def report_transport_begin(fabric : UInt8, id : UInt16, reason : ActivationReason?, session : UInt64) : Bool
        expire_due
        entry = find_owned(fabric, id)
        return false unless entry
        options = entry.transport_options || return false
        trigger = reason ? TriggerType::Command : options.trigger_options.trigger_type
        report_transport_begin(fabric, id, trigger, reason, session)
      end

      # The actual trigger can be Command for a manually started Motion transport.
      def report_transport_begin(fabric : UInt8, id : UInt16, trigger : TriggerType,
                                 reason : ActivationReason?, session : UInt64) : Bool
        expire_due
        entry = find_owned(fabric, id)
        return false unless entry && entry.transport_status.active?
        options = entry.transport_options || return false
        configured = options.trigger_options.trigger_type
        return false unless trigger == configured || (trigger.command? && configured.motion?)
        return false if trigger.command? && reason.nil?
        return false if !trigger.command? && reason
        return false if @active_sessions.has_key?(id)
        emit_event(EVENT_PUSH_TRANSPORT_BEGIN, Tlv::BeginEvent.new(id, trigger, reason,
          ContainerFormat::Cmaf, session), fabric)
        @active_sessions[id] = session
        true
      end

      def report_transport_end(fabric : UInt8, id : UInt16, session : UInt64) : Bool
        expire_due
        entry = find_owned(fabric, id)
        return false unless entry
        return false unless @active_sessions[id]? == session
        close_session(entry)
        true
      end

      def remove_fabric(fabric : UInt8) : Nil
        size = @connections.size
        @connections.each do |entry|
          next unless entry.fabric_index == fabric
          # Fabric removal must erase ownership even if the host cannot confirm a stop.
          @on_status_change.try(&.call(fabric, entry.connection_id, TransportStatus::Inactive)) if entry.transport_status.active?
          if options = entry.transport_options
            @on_reference_change.try(&.call(fabric, options.tls_endpoint_id, -1_i8))
          end
        end
        @connections.reject!(&.fabric_index.==(fabric))
        @active_sessions.reject! { |id, _| !@connections.any?(&.connection_id.==(id)) }
        @expiry_deadlines.reject! { |id, _| !@connections.any?(&.connection_id.==(id)) }
        changed if size != @connections.size
        schedule_expiry
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @connections, @next_connection_id, @expiry_deadlines).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        state.connections.each do |entry|
          raise StorageError.new("Push AV connection ID is invalid") if entry.connection_id > MAX_CONNECTION_ID
          raise StorageError.new("Push AV connection is missing options") unless entry.transport_options
        end
        ids = state.connections.map(&.connection_id)
        raise StorageError.new("Push AV connection IDs are duplicated") unless ids.uniq.size == ids.size
        unless state.expiry_deadlines.keys.all? { |id| ids.includes?(id) }
          raise StorageError.new("Push AV expiry refers to an unknown connection")
        end
        @connections = state.connections.select { |entry| installed?(entry.fabric_index) }.map do |entry|
          # A restored allocation is never sending until the host reconnects.
          if entry.transport_status.active?
            Tlv::TransportConfiguration.new(entry.connection_id, TransportStatus::Inactive,
              entry.transport_options, entry.fabric_index)
          else
            entry
          end
        end
        @active_sessions.clear
        @next_connection_id = state.next_connection_id
        @expiry_deadlines = state.expiry_deadlines.select { |id, _| @connections.any?(&.connection_id.==(id)) }
        @data_version = state.data_version
        changed if @connections.size != state.connections.size || state.connections.any?(&.transport_status.active?)
        expire_due
        schedule_expiry
      end

      private def accessing_fabric : UInt8 | InteractionModel::Status
        fabric = request_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric && request_is_case_session?
        return InteractionModel::Status.unsupported_access unless valid_fabric?(fabric)
        fabric
      end

      private def valid_fabric?(fabric : UInt8) : Bool
        fabric.in?(Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX) && installed?(fabric)
      end

      private def installed?(fabric : UInt8) : Bool
        @fabric_installed.try(&.call(fabric)) != false
      end

      private def find_owned(fabric : UInt8, id : UInt16) : Tlv::TransportConfiguration?
        @connections.find { |entry| entry.fabric_index == fabric && entry.connection_id == id }
      end

      private def next_id : UInt16?
        start = @next_connection_id
        candidate = start
        loop do
          unless @connections.any?(&.connection_id.==(candidate))
            @next_connection_id = candidate == MAX_CONNECTION_ID ? 0_u16 : candidate + 1_u16
            return candidate
          end
          candidate = candidate == MAX_CONNECTION_ID ? 0_u16 : candidate + 1_u16
          return if candidate == start
        end
      end

      private def replace(old : Tlv::TransportConfiguration, new_entry : Tlv::TransportConfiguration) : Nil
        index = @connections.index(old) || raise StorageError.new("Push AV connection replacement target missing")
        @connections[index] = new_entry
      end

      private def close_session(entry : Tlv::TransportConfiguration) : Nil
        if session = @active_sessions.delete(entry.connection_id)
          emit_event(EVENT_PUSH_TRANSPORT_END,
            Tlv::EndEvent.new(entry.connection_id, ContainerFormat::Cmaf, session), entry.fabric_index)
        end
      end

      private def clone_options(options : Tlv::TransportOptions) : Tlv::TransportOptions
        copy = Tlv::TransportOptions.from_document(options.to_document)
        video_id = copy.video_streams.try(&.first?.try(&.id)) || copy.video_stream_id_state
        audio_id = copy.audio_streams.try(&.first?.try(&.id)) || copy.audio_stream_id_state
        Tlv::TransportOptions.new(copy.stream_usage, copy.tls_endpoint_id, copy.url,
          copy.trigger_options, copy.ingest_method, copy.container_options,
          video_stream_id: video_id, audio_stream_id: audio_id, expiry_time: copy.expiry_time,
          video_streams: copy.video_streams, audio_streams: copy.audio_streams)
      end

      private def resolve_streams(options : Tlv::TransportOptions, fabric : UInt8) : Tlv::TransportOptions | InteractionModel::Status
        videos = options.video_streams.try(&.dup) || [] of Tlv::VideoStream
        audios = options.audio_streams.try(&.dup) || [] of Tlv::AudioStream
        video_id = options.video_stream_id_state
        audio_id = options.audio_stream_id_state
        if video_id.null?
          selector = @select_video_stream || return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream)
          video_id = ::TLV::FieldState(UInt16).value(selector.call(fabric, options.stream_usage))
        end
        if audio_id.null?
          selector = @select_audio_stream || return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream)
          audio_id = ::TLV::FieldState(UInt16).value(selector.call(fabric, options.stream_usage))
        end
        if video_id.value? && videos.none?(&.id.==(video_id.value!))
          videos << Tlv::VideoStream.new("video", video_id.value!)
        end
        if audio_id.value? && audios.none?(&.id.==(audio_id.value!))
          audios << Tlv::AudioStream.new("audio", audio_id.value!)
        end
        Tlv::TransportOptions.new(options.stream_usage, options.tls_endpoint_id, options.url,
          options.trigger_options, options.ingest_method, options.container_options,
          video_stream_id: video_id, audio_stream_id: audio_id, expiry_time: options.expiry_time,
          video_streams: videos.empty? ? nil : videos, audio_streams: audios.empty? ? nil : audios)
      end

      private def clone_configuration(entry : Tlv::TransportConfiguration) : Tlv::TransportConfiguration
        Tlv::TransportConfiguration.from_document(entry.to_document)
      end

      private def valid_time_control?(control : Tlv::MotionTimeControl) : Bool
        !control.initial_duration.zero? && control.max_duration >= control.initial_duration
      end

      private def expire_due : Nil
        now = @clock.call
        due = @expiry_deadlines.select { |_, deadline| deadline <= now }.keys
        due.each do |id|
          entry = @connections.find(&.connection_id.==(id))
          next unless entry
          if entry.transport_status.active?
            next unless @on_status_change.try(&.call(entry.fabric_index, id, TransportStatus::Inactive))
          end
          if options = entry.transport_options
            next if @on_reference_change.try(&.call(entry.fabric_index, options.tls_endpoint_id, -1_i8)) == false
          end
          close_session(entry)
          @connections.delete(entry)
          @expiry_deadlines.delete(id)
          changed
        end
      end

      private def schedule_expiry : Nil
        @expiry_generation &+= 1
        generation = @expiry_generation
        deadline = @expiry_deadlines.values.min?
        return unless deadline
        remaining = deadline - @clock.call
        seconds = remaining.total_seconds.clamp(1.0, MAX_TIMER_DELAY.to_f64)
        @expiry_timer.call(seconds.seconds, -> { expire_if_current(generation) })
      end

      private def expire_if_current(generation : UInt64) : Nil
        return unless generation == @expiry_generation
        expire_due
        schedule_expiry
      end

      private def validate_options(options : Tlv::TransportOptions, fabric : UInt8) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidTlsEndpoint) unless @tls_endpoint_exists.try(&.call(fabric, options.tls_endpoint_id))
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidCombination) unless options.ingest_method.cmaf_ingest? && options.container_options.container_type.cmaf?
        cmaf = options.container_options.cmaf
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) unless cmaf.cmaf_interface.interface1? && cmaf.segment_duration.in?(MIN_SEGMENT_DURATION..MAX_SEGMENT_DURATION) && cmaf.chunk_duration <= cmaf.segment_duration // 2
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if cmaf.track_name.try { |name| name.bytesize < 1 || name.bytesize > MAX_STREAM_NAME_BYTES }
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if cmaf.metadata_enabled && !feature_map.metadata?
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidUrl) unless valid_url?(options.url)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidTime) if options.expiry_time && @time_valid.try(&.call) != true

        videos = options.video_streams || [] of Tlv::VideoStream
        audios = options.audio_streams || [] of Tlv::AudioStream
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream) if videos.size > MAX_STREAMS || audios.size > MAX_STREAMS
        if videos.map(&.id).to_set.size != videos.size || audios.map(&.id).to_set.size != audios.size ||
           videos.map(&.name).to_set.size != videos.size || audios.map(&.name).to_set.size != audios.size
          return InteractionModel::Status.cluster_failure(StatusCode::DuplicateStreamValues)
        end
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream) if videos.any? { |stream| !stream.name.bytesize.in?(1..MAX_STREAM_NAME_BYTES) || !@video_stream_exists.try(&.call(stream.id)) }
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream) if audios.any? { |stream| !stream.name.bytesize.in?(1..MAX_STREAM_NAME_BYTES) || !@audio_stream_exists.try(&.call(stream.id)) }
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream) if options.video_stream_id.try { |id| !@video_stream_exists.try(&.call(id)) }
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream) if options.audio_stream_id.try { |id| !@audio_stream_exists.try(&.call(id)) }
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidStream) if videos.empty? && audios.empty? && options.video_stream_id.nil? && options.audio_stream_id.nil?
        trigger = options.trigger_options
        if trigger.trigger_type.motion?
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if trigger.motion_zones_state.absent?
          time_control = trigger.motion_time_control
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) unless time_control && valid_time_control?(time_control)
          motion_zones = trigger.motion_zones || [] of Tlv::ZoneOptions
          if feature_map.per_zone_sensitivity?
            return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) unless trigger.motion_sensitivity_state.absent?
            return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if motion_zones.any? { |zone| !zone.sensitivity.try(&.in?(MIN_SENSITIVITY..MAX_SENSITIVITY)) }
          else
            return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if trigger.motion_sensitivity_state.absent?
            return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if trigger.motion_sensitivity.try { |value| !value.in?(MIN_SENSITIVITY..MAX_SENSITIVITY) }
            return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if motion_zones.any? { |zone| !zone.sensitivity.nil? }
          end
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidZone) if motion_zones.any? { |zone| zone.zone.try { |id| !@zone_exists.try(&.call(id)) } }
        elsif !trigger.motion_zones_state.absent? || !trigger.motion_sensitivity_state.absent? || trigger.motion_time_control
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions)
        end
        if trigger.trigger_type.continuous?
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) if trigger.max_pre_roll_len
        else
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidOptions) unless trigger.max_pre_roll_len
          if pre_roll = trigger.max_pre_roll_len
            if pre_roll > 0_u16 && !@pre_roll_valid.try(&.call(pre_roll))
              return InteractionModel::Status.cluster_failure(StatusCode::InvalidPreRollLength)
            end
          end
        end
        InteractionModel::Status.success
      end

      private def valid_url?(url : String) : Bool
        return false unless url.bytesize.in?(MIN_URL_BYTES..MAX_URL_BYTES)
        uri = URI.parse(url)
        host = uri.host
        uri.scheme == "https" && !host.nil? && !host.empty?
      rescue URI::Error
        false
      end

      private def changed : Nil
        increment_version_and_notify(ATTR_CURRENT_CONNECTIONS)
        @on_persist.try(&.call)
      end
    end
  end
end
