require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Media Playback server (0x0506, revision 2). The host decides
    # whether each playback operation can be performed and owns media timing.
    class MediaPlayback < Base
      cluster 0x0506, revision: 2

      MAX_TRACK_ID_BYTES     =       32
      MAX_LANGUAGE_BYTES     =       32
      MAX_DISPLAY_NAME_BYTES =      256
      MAX_EVENT_DATA_BYTES   =      900
      CMD_PLAYBACK_RESPONSE  = 0x0A_u32

      feature :advanced_seek, bit: 0
      feature :variable_speed, bit: 1
      feature :text_tracks, bit: 2
      feature :audio_tracks, bit: 3
      feature :audio_advance, bit: 4

      enum PlaybackState : UInt8
        Playing
        Paused
        NotPlaying
        Buffering
      end

      enum PlaybackStatus : UInt8
        Success
        InvalidStateForCommand
        NotAllowed
        NotActive
        SpeedOutOfRange
        SeekOutOfRange
      end

      enum Characteristic : UInt8
        ForcedSubtitles
        DescribesVideo
        EasyToRead
        FrameBased
        MainProgram
        OriginalContent
        VoiceOverTranslation
        Caption
        Subtitle
        Alternate
        Supplementary
        Commentary
        DubbedTranslation
        Description
        Metadata
        EnhancedAudioIntelligibility
        Emergency
        Karaoke
      end

      enum Command : UInt8
        Play
        Pause
        Stop
        StartOver
        Previous
        Next
        Rewind
        FastForward
        SkipForward
        SkipBackward
        Seek                = 0x0B
        ActivateAudioTrack
        ActivateTextTrack
        DeactivateTextTrack
      end

      struct PlaybackPosition
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter updated_at : UInt64

        @[TLV::Field(tag: 1)]
        getter position : UInt64?

        def initialize(@updated_at : UInt64, @position : UInt64?)
        end
      end

      struct TrackAttributes
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter language_code : String

        @[TLV::Field(tag: 1, optional: true)]
        getter characteristics : Array(Characteristic)?

        @[TLV::Field(tag: 2, optional: true)]
        getter display_name : String?

        def initialize(@language_code : String,
                       @characteristics : Array(Characteristic)? = nil,
                       @display_name : String? = nil)
          raise ArgumentError.new("language code exceeds 32 bytes") if @language_code.bytesize > MAX_LANGUAGE_BYTES
          if name = @display_name
            raise ArgumentError.new("track display name exceeds 256 bytes") if name.bytesize > MAX_DISPLAY_NAME_BYTES
          end
          @characteristics = @characteristics.try(&.dup)
        end
      end

      struct Track
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter id : String

        @[TLV::Field(tag: 1)]
        getter track_attributes : TrackAttributes

        def initialize(@id : String, @track_attributes : TrackAttributes)
          MediaPlayback.validate_track_id!(@id)
        end
      end

      struct PlaybackResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : PlaybackStatus

        @[TLV::Field(tag: 1, optional: true)]
        getter data : String?

        def initialize(@status : PlaybackStatus, @data : String? = nil)
        end
      end

      struct AdvanceRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter? audio_advance_unmuted : Bool

        def initialize(@audio_advance_unmuted : Bool = false)
        end
      end

      struct SkipRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter delta_position_milliseconds : UInt64

        def initialize(@delta_position_milliseconds : UInt64)
        end
      end

      struct SeekRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter position : UInt64

        def initialize(@position : UInt64)
        end
      end

      struct ActivateAudioTrackRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter track_id : String

        @[TLV::Field(tag: 1)]
        getter audio_output_index : UInt8?

        def initialize(@track_id : String, @audio_output_index : UInt8? = nil)
          MediaPlayback.validate_track_id!(@track_id)
        end
      end

      struct ActivateTextTrackRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter track_id : String

        def initialize(@track_id : String)
          MediaPlayback.validate_track_id!(@track_id)
        end
      end

      # Generic host request so one callback handles both parameterless and
      # parameterized playback operations without passing wire TLV upstream.
      struct Operation
        getter position : UInt64?
        getter delta_position_milliseconds : UInt64?
        getter? audio_advance_unmuted : Bool
        getter track_id : String?
        getter audio_output_index : UInt8?

        def initialize(@position : UInt64? = nil,
                       @delta_position_milliseconds : UInt64? = nil,
                       @audio_advance_unmuted : Bool = false,
                       @track_id : String? = nil,
                       @audio_output_index : UInt8? = nil)
        end
      end

      struct StateChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter current_state : PlaybackState
        @[TLV::Field(tag: 1, optional: true)]
        getter start_time : UInt64?
        @[TLV::Field(tag: 2, optional: true)]
        getter duration : UInt64?
        @[TLV::Field(tag: 3, optional: true)]
        getter sampled_position : PlaybackPosition?
        @[TLV::Field(tag: 4, optional: true)]
        getter playback_speed : Float32?
        @[TLV::Field(tag: 5, optional: true)]
        getter seek_range_end : UInt64?
        @[TLV::Field(tag: 6, optional: true)]
        getter seek_range_start : UInt64?
        @[TLV::Field(tag: 7, optional: true)]
        getter data : Bytes?
        @[TLV::Field(tag: 8, optional: true)]
        getter? audio_advance_unmuted : Bool?

        def initialize(@current_state : PlaybackState, @start_time : UInt64? = nil,
                       @duration : UInt64? = nil, @sampled_position : PlaybackPosition? = nil,
                       @playback_speed : Float32? = nil, @seek_range_end : UInt64? = nil,
                       @seek_range_start : UInt64? = nil, @data : Bytes? = nil,
                       @audio_advance_unmuted : Bool? = nil)
        end
      end

      attribute 0x0000, :current_state, PlaybackState, default: PlaybackState::NotPlaying, on_change: :state_attribute_changed
      attribute 0x0001, :start_time, UInt64, nullable: true, requires: :advanced_seek, on_change: :state_attribute_changed
      attribute 0x0002, :duration, UInt64, nullable: true, requires: :advanced_seek, on_change: :state_attribute_changed
      attribute 0x0003, :sampled_position, PlaybackPosition, nullable: true, requires: :advanced_seek, on_change: :state_attribute_changed
      attribute 0x0004, :playback_speed, Float32, default: 0_f32, requires: :advanced_seek, on_change: :state_attribute_changed
      attribute 0x0005, :seek_range_end, UInt64, nullable: true, requires: :advanced_seek, on_change: :state_attribute_changed
      attribute 0x0006, :seek_range_start, UInt64, nullable: true, requires: :advanced_seek, on_change: :state_attribute_changed
      attribute 0x0007, :active_audio_track, Track, nullable: true, requires: :audio_tracks, on_change: :state_attribute_changed
      attribute 0x0008, :available_audio_tracks, Array(Track), nullable: true, requires: :audio_tracks, on_change: :state_attribute_changed
      attribute 0x0009, :active_text_track, Track, nullable: true, requires: :text_tracks, on_change: :state_attribute_changed
      attribute 0x000A, :available_text_tracks, Array(Track), nullable: true, requires: :text_tracks, on_change: :state_attribute_changed

      command 0x00, :play, response: PlaybackResponse, response_id: CMD_PLAYBACK_RESPONSE, access: :operate
      command 0x01, :pause, response: PlaybackResponse, response_id: CMD_PLAYBACK_RESPONSE, access: :operate
      command 0x02, :stop, response: PlaybackResponse, response_id: CMD_PLAYBACK_RESPONSE, access: :operate
      command 0x03, :start_over, response: PlaybackResponse, response_id: CMD_PLAYBACK_RESPONSE, access: :operate,
        present_if: :optional_command_supported?
      command 0x04, :previous, response: PlaybackResponse, response_id: CMD_PLAYBACK_RESPONSE, access: :operate,
        present_if: :optional_command_supported?
      command 0x05, :next, handler: :next_media, response: PlaybackResponse, response_id: CMD_PLAYBACK_RESPONSE, access: :operate,
        present_if: :optional_command_supported?
      command 0x06, :rewind, request: AdvanceRequest, response: PlaybackResponse,
        response_id: CMD_PLAYBACK_RESPONSE, access: :operate, requires: :variable_speed
      command 0x07, :fast_forward, request: AdvanceRequest, response: PlaybackResponse,
        response_id: CMD_PLAYBACK_RESPONSE, access: :operate, requires: :variable_speed
      command 0x08, :skip_forward, request: SkipRequest, response: PlaybackResponse,
        response_id: CMD_PLAYBACK_RESPONSE, access: :operate, present_if: :optional_command_supported?
      command 0x09, :skip_backward, request: SkipRequest, response: PlaybackResponse,
        response_id: CMD_PLAYBACK_RESPONSE, access: :operate, present_if: :optional_command_supported?
      command 0x0B, :seek, request: SeekRequest, response: PlaybackResponse,
        response_id: CMD_PLAYBACK_RESPONSE, access: :operate, requires: :advanced_seek
      command 0x0C, :activate_audio_track, request: ActivateAudioTrackRequest,
        access: :operate, requires: :audio_tracks
      command 0x0D, :activate_text_track, request: ActivateTextTrackRequest,
        access: :operate, requires: :text_tracks
      command 0x0E, :deactivate_text_track, access: :operate, requires: :text_tracks

      event 0x00, :state_changed, priority: :info, payload: StateChangedEvent

      @on_command : Proc(Command, Operation, PlaybackStatus)? = nil
      @suppress_state_events : Bool = false

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     optional_commands : Array(Command) = [] of Command)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("AudioAdvance requires VariableSpeed") if @feature_map.audio_advance? && !@feature_map.variable_speed?
        allowed = [Command::StartOver, Command::Previous, Command::Next, Command::SkipForward, Command::SkipBackward]
        raise ArgumentError.new("unsupported optional playback command") unless optional_commands.all? { |command| allowed.includes?(command) }
        raise ArgumentError.new("duplicate optional playback command") unless optional_commands.uniq.size == optional_commands.size
        @optional_commands = optional_commands.dup
      end

      def on_command(&block : Command, Operation -> PlaybackStatus) : Nil
        @on_command = block
      end

      def report_state(state : PlaybackState, *, speed : Float32? = nil,
                       position : PlaybackPosition? = nil, event_data : Bytes? = nil,
                       audio_advance_unmuted : Bool = false) : Nil
        if speed && !@feature_map.advanced_seek?
          raise ArgumentError.new("AdvancedSeek feature is required to publish playback speed")
        end
        if speed && (!speed.finite? || (!state.playing? && speed != 0_f32))
          raise ArgumentError.new("playback speed must be finite and zero while not playing")
        end
        if audio_advance_unmuted && !@feature_map.audio_advance?
          raise ArgumentError.new("AudioAdvance feature is required")
        end
        if event_data && event_data.size > MAX_EVENT_DATA_BYTES
          raise ArgumentError.new("StateChanged data exceeds 900 bytes")
        end
        batch_state_update(event_data, audio_advance_unmuted) do
          self.current_state = state
          if @feature_map.advanced_seek?
            self.playback_speed = speed || (state.playing? ? 1_f32 : 0_f32)
            self.sampled_position = position if position
          end
        end
      end

      def update_seek_range(start_position : UInt64?, end_position : UInt64?,
                            duration : UInt64? = nil, start_time : UInt64? = nil) : Nil
        raise ArgumentError.new("AdvancedSeek feature is required") unless @feature_map.advanced_seek?
        if start_position && end_position && start_position > end_position
          raise ArgumentError.new("SeekRangeStart exceeds SeekRangeEnd")
        end
        raise ArgumentError.new("Duration must be positive") if duration == 0_u64
        batch_state_update do
          self.seek_range_start = start_position
          self.seek_range_end = end_position
          self.duration = duration
          self.start_time = start_time
        end
      end

      def update_audio_tracks(tracks : Array(Track)?, active : Track? = nil) : Nil
        raise ArgumentError.new("AudioTracks feature is required") unless @feature_map.audio_tracks?
        validate_tracks!(tracks, active)
        batch_state_update do
          self.available_audio_tracks = tracks.try(&.dup)
          self.active_audio_track = active
        end
      end

      def update_text_tracks(tracks : Array(Track)?, active : Track? = nil) : Nil
        raise ArgumentError.new("TextTracks feature is required") unless @feature_map.text_tracks?
        validate_tracks!(tracks, active)
        batch_state_update do
          self.available_text_tracks = tracks.try(&.dup)
          self.active_text_track = active
        end
      end

      def play : PlaybackResponse
        execute(Command::Play) { report_state(PlaybackState::Playing) }
      end

      def pause : PlaybackResponse
        execute(Command::Pause) { report_state(PlaybackState::Paused) }
      end

      def stop : PlaybackResponse
        execute(Command::Stop) { report_state(PlaybackState::NotPlaying) }
      end

      def start_over : PlaybackResponse
        execute(Command::StartOver)
      end

      def previous : PlaybackResponse
        execute(Command::Previous)
      end

      def next_media : PlaybackResponse
        execute(Command::Next)
      end

      def rewind(request : AdvanceRequest) : PlaybackResponse
        return PlaybackResponse.new(PlaybackStatus::NotAllowed) if request.audio_advance_unmuted? && !@feature_map.audio_advance?
        execute(Command::Rewind, Operation.new(audio_advance_unmuted: request.audio_advance_unmuted?))
      end

      def fast_forward(request : AdvanceRequest) : PlaybackResponse
        return PlaybackResponse.new(PlaybackStatus::NotAllowed) if request.audio_advance_unmuted? && !@feature_map.audio_advance?
        execute(Command::FastForward, Operation.new(audio_advance_unmuted: request.audio_advance_unmuted?))
      end

      def skip_forward(request : SkipRequest) : PlaybackResponse
        execute(Command::SkipForward, Operation.new(delta_position_milliseconds: request.delta_position_milliseconds))
      end

      def skip_backward(request : SkipRequest) : PlaybackResponse
        execute(Command::SkipBackward, Operation.new(delta_position_milliseconds: request.delta_position_milliseconds))
      end

      def seek(request : SeekRequest) : PlaybackResponse
        if (start_position = @seek_range_start) && request.position < start_position ||
           (end_position = @seek_range_end) && request.position > end_position
          return PlaybackResponse.new(PlaybackStatus::SeekOutOfRange)
        end
        execute(Command::Seek, Operation.new(position: request.position))
      end

      def activate_audio_track(request : ActivateAudioTrackRequest) : InteractionModel::Status
        track = @available_audio_tracks.try(&.find { |entry| entry.id == request.track_id })
        return InteractionModel::Status.invalid_command if track.nil? || @current_state.not_playing?
        result = decision(Command::ActivateAudioTrack,
          Operation.new(track_id: request.track_id, audio_output_index: request.audio_output_index))
        return InteractionModel::Status.failure unless result.success?
        self.active_audio_track = track
        InteractionModel::Status.success
      end

      def activate_text_track(request : ActivateTextTrackRequest) : InteractionModel::Status
        track = @available_text_tracks.try(&.find { |entry| entry.id == request.track_id })
        return InteractionModel::Status.invalid_command if track.nil? || @current_state.not_playing?
        result = decision(Command::ActivateTextTrack, Operation.new(track_id: request.track_id))
        return InteractionModel::Status.failure unless result.success?
        self.active_text_track = track
        InteractionModel::Status.success
      end

      def deactivate_text_track : InteractionModel::Status
        result = decision(Command::DeactivateTextTrack, Operation.new)
        return InteractionModel::Status.failure unless result.success?
        self.active_text_track = nil
        InteractionModel::Status.success
      end

      def self.validate_track_id!(id : String) : Nil
        raise ArgumentError.new("track ID exceeds 32 bytes") if id.bytesize > MAX_TRACK_ID_BYTES
      end

      private def state_attribute_changed(_value) : Nil
        emit_current_state unless @suppress_state_events
      end

      private def batch_state_update(data : Bytes? = nil, audio_advance_unmuted : Bool = false, &block : -> Nil) : Nil
        version_before = data_version
        @suppress_state_events = true
        begin
          block.call
        ensure
          @suppress_state_events = false
          emit_current_state(data, audio_advance_unmuted) if data_version != version_before || data || audio_advance_unmuted
        end
      end

      private def emit_current_state(data : Bytes? = nil, audio_advance_unmuted : Bool = false) : Nil
        advanced_seek = @feature_map.advanced_seek?
        emit_state_changed(StateChangedEvent.new(@current_state,
          advanced_seek ? (@start_time || 0_u64) : nil,
          advanced_seek ? (@duration || 0_u64) : nil,
          advanced_seek ? (@sampled_position || PlaybackPosition.new(0_u64, nil)) : nil,
          advanced_seek ? @playback_speed : nil,
          advanced_seek ? (@seek_range_end || 0_u64) : nil,
          advanced_seek ? (@seek_range_start || 0_u64) : nil,
          data, @feature_map.audio_advance? ? audio_advance_unmuted : nil))
      end

      private def optional_command_supported?(id : UInt32) : Bool
        @optional_commands.any? { |command| command.value.to_u32 == id }
      end

      private def validate_tracks!(tracks : Array(Track)?, active : Track?) : Nil
        ids = tracks.try(&.map(&.id)) || [] of String
        raise ArgumentError.new("duplicate track ID") unless ids.uniq.size == ids.size
        if active && !ids.includes?(active.id)
          raise ArgumentError.new("active track is absent from available tracks")
        end
      end

      private def decision(command : Command, operation : Operation) : PlaybackStatus
        @on_command.try(&.call(command, operation)) || PlaybackStatus::NotAllowed
      end

      private def execute(command : Command, operation : Operation = Operation.new, &on_success : -> Nil) : PlaybackResponse
        status = decision(command, operation)
        on_success.call if status.success?
        PlaybackResponse.new(status)
      end

      private def execute(command : Command, operation : Operation = Operation.new) : PlaybackResponse
        PlaybackResponse.new(decision(command, operation))
      end
    end
  end
end
