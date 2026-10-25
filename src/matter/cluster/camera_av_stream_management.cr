require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Camera AV Stream Management revision 2, Audio feature.
    # The host admits actual media streams through on_audio_allocate and must
    # stop them through on_audio_deallocate. This class manages the Matter
    # allocation and settings state; it does not encode or transport media.
    class CameraAvStreamManagement < Base
      cluster 0x0551, revision: 2

      feature :audio, bit: 0
      feature :privacy, bit: 3

      MAX_STREAM_ID        = 65_534_u16
      MAX_REFERENCE_COUNT  =     255_u8
      MIN_CHANNEL_COUNT    =       1_u8
      MAX_CHANNEL_COUNT    =       8_u8
      MAX_VOLUME_LEVEL     =     254_u8
      SUPPORTED_BIT_DEPTHS = [8_u8, 16_u8, 24_u8, 32_u8]

      enum StreamUsage : UInt8
        Internal  = 0
        Recording = 1
        Analysis  = 2
        LiveView  = 3
      end

      enum AudioCodec : UInt8
        Opus  = 0
        AacLc = 1
      end

      struct AudioCapabilities
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter max_number_of_channels : UInt8

        @[TLV::Field(tag: 1)]
        getter supported_codecs : Array(AudioCodec)

        @[TLV::Field(tag: 2)]
        getter supported_sample_rates : Array(UInt32)

        @[TLV::Field(tag: 3)]
        getter supported_bit_depths : Array(UInt8)

        def initialize(@max_number_of_channels : UInt8,
                       supported_codecs : Array(AudioCodec),
                       supported_sample_rates : Array(UInt32),
                       supported_bit_depths : Array(UInt8))
          raise ArgumentError.new("microphone must support at least one channel") if @max_number_of_channels.zero?
          raise ArgumentError.new("microphone must support at least one codec") if supported_codecs.empty?
          unless supported_codecs.all?(&.in?(AudioCodec::Opus, AudioCodec::AacLc))
            raise ArgumentError.new("unsupported microphone codec")
          end
          raise ArgumentError.new("microphone must support at least one sample rate") if supported_sample_rates.empty?
          raise ArgumentError.new("microphone must support at least one bit depth") if supported_bit_depths.empty?
          raise ArgumentError.new("microphone sample rates must be positive") if supported_sample_rates.any?(&.zero?)
          raise ArgumentError.new("microphone bit depths must be 8, 16, 24 or 32") unless supported_bit_depths.all? { |depth| valid_bit_depth?(depth) }
          raise ArgumentError.new("duplicate microphone capability") unless supported_codecs.uniq.size == supported_codecs.size &&
                                                                            supported_sample_rates.uniq.size == supported_sample_rates.size && supported_bit_depths.uniq.size == supported_bit_depths.size
          @supported_codecs = supported_codecs.dup
          @supported_sample_rates = supported_sample_rates.dup
          @supported_bit_depths = supported_bit_depths.dup
        end

        def supported_codecs : Array(AudioCodec)
          @supported_codecs.dup
        end

        def supported_sample_rates : Array(UInt32)
          @supported_sample_rates.dup
        end

        def supported_bit_depths : Array(UInt8)
          @supported_bit_depths.dup
        end

        private def valid_bit_depth?(depth : UInt8) : Bool
          SUPPORTED_BIT_DEPTHS.includes?(depth)
        end
      end

      struct AudioStream
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter audio_stream_id : UInt16

        @[TLV::Field(tag: 1)]
        getter stream_usage : StreamUsage

        @[TLV::Field(tag: 2)]
        getter audio_codec : AudioCodec

        @[TLV::Field(tag: 3)]
        getter channel_count : UInt8

        @[TLV::Field(tag: 4)]
        getter sample_rate : UInt32

        @[TLV::Field(tag: 5)]
        getter bit_rate : UInt32

        @[TLV::Field(tag: 6)]
        getter bit_depth : UInt8

        @[TLV::Field(tag: 7)]
        getter reference_count : UInt8

        def initialize(@audio_stream_id : UInt16, @stream_usage : StreamUsage,
                       @audio_codec : AudioCodec, @channel_count : UInt8,
                       @sample_rate : UInt32, @bit_rate : UInt32,
                       @bit_depth : UInt8, @reference_count : UInt8)
        end

        def matches?(request : AudioStreamAllocateRequest) : Bool
          @stream_usage == request.stream_usage && @audio_codec == request.audio_codec &&
            @channel_count == request.channel_count && @sample_rate == request.sample_rate &&
            @bit_rate == request.bit_rate && @bit_depth == request.bit_depth
        end

        def with_reference_count(count : UInt8) : AudioStream
          AudioStream.new(@audio_stream_id, @stream_usage, @audio_codec,
            @channel_count, @sample_rate, @bit_rate, @bit_depth, count)
        end
      end

      struct AudioStreamAllocateRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter stream_usage : StreamUsage

        @[TLV::Field(tag: 1)]
        getter audio_codec : AudioCodec

        @[TLV::Field(tag: 2)]
        getter channel_count : UInt8

        @[TLV::Field(tag: 3)]
        getter sample_rate : UInt32

        @[TLV::Field(tag: 4)]
        getter bit_rate : UInt32

        @[TLV::Field(tag: 5)]
        getter bit_depth : UInt8

        def initialize(@stream_usage : StreamUsage, @audio_codec : AudioCodec,
                       @channel_count : UInt8, @sample_rate : UInt32,
                       @bit_rate : UInt32, @bit_depth : UInt8)
        end
      end

      struct AudioStreamAllocateResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter audio_stream_id : UInt16

        def initialize(@audio_stream_id : UInt16)
        end
      end

      struct AudioStreamDeallocateRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter audio_stream_id : UInt16

        def initialize(@audio_stream_id : UInt16)
        end
      end

      struct SetStreamPrioritiesRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter stream_priorities : Array(StreamUsage)

        def initialize(@stream_priorities : Array(StreamUsage))
        end
      end

      attribute 0x0006, :max_content_buffer_size, UInt32, default: 0_u32, fixed: true
      attribute 0x0007, :microphone_capabilities, AudioCapabilities, computed: true, fixed: true, requires: :audio
      attribute 0x000B, :max_network_bandwidth, UInt32, default: 0_u32, fixed: true
      attribute 0x000E, :supported_stream_usages, Array(StreamUsage), computed: true, fixed: true
      attribute 0x0010, :allocated_audio_streams, Array(AudioStream), computed: true, requires: :audio
      attribute 0x0012, :stream_usage_priorities, Array(StreamUsage), computed: true
      attribute 0x0013, :soft_recording_privacy_mode_enabled, Bool, default: false,
        writable: true, write_access: :operate, persist: true, requires: :privacy, on_change: :notify_privacy
      attribute 0x0014, :soft_livestream_privacy_mode_enabled, Bool, default: false,
        writable: true, write_access: :operate, persist: true, requires: :privacy, on_change: :notify_privacy
      attribute 0x0015, :hard_privacy_mode_on, Bool, default: false, on_change: :notify_privacy
      attribute 0x001D, :microphone_muted, Bool, default: false,
        writable: true, read_access: :manage, write_access: :manage, persist: true,
        requires: :audio, on_change: :notify_microphone
      attribute 0x001E, :microphone_volume_level, UInt8, default: 0_u8,
        writable: true, read_access: :manage, write_access: :manage, persist: true,
        requires: :audio, on_change: :notify_microphone
      attribute 0x001F, :microphone_max_level, UInt8, default: 0_u8, fixed: true, read_access: :manage, requires: :audio
      attribute 0x0020, :microphone_min_level, UInt8, default: 0_u8, fixed: true, read_access: :manage, requires: :audio

      before_write :microphone_volume_level do |level|
        InteractionModel::Status.constraint_error unless level.in?(@microphone_min_level..@microphone_max_level)
      end

      command 0x00, :audio_stream_allocate, request: AudioStreamAllocateRequest,
        response: AudioStreamAllocateResponse, response_id: 0x01, access: :manage, requires: :audio
      command 0x02, :audio_stream_deallocate, request: AudioStreamDeallocateRequest,
        access: :manage, requires: :audio
      command 0x0B, :set_stream_priorities, request: SetStreamPrioritiesRequest,
        access: :administer, handler: :apply_stream_priorities

      @audio_allocate_callback : Proc(AudioStreamAllocateRequest, UInt16, InteractionModel::Status)?
      @audio_deallocate_callback : Proc(UInt16, InteractionModel::Status)?
      @privacy_callback : Proc(Bool, Bool, Bool, Nil)?
      @microphone_callback : Proc(Bool, UInt8, Nil)?
      @delivery_observers = [] of Proc(Nil)
      @audio_release_observers = [] of Proc(UInt16, Nil)
      @next_audio_stream_id : UInt16 = 0_u16
      @microphone_capabilities : AudioCapabilities
      @supported_stream_usages : Array(StreamUsage)
      @stream_usage_priorities : Array(StreamUsage)
      @allocated_audio_streams : Array(AudioStream)

      def initialize(endpoint_id : DataType::EndpointNumber,
                     microphone_capabilities : AudioCapabilities,
                     supported_stream_usages : Array(StreamUsage),
                     @max_content_buffer_size : UInt32,
                     @max_network_bandwidth : UInt32,
                     @microphone_min_level : UInt8 = 0_u8,
                     @microphone_max_level : UInt8 = 100_u8,
                     @microphone_volume_level : UInt8 = 50_u8,
                     @feature_map : Feature = Feature::Audio)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("Audio feature is required") unless @feature_map.audio?
        unless (@feature_map.value & ~(Feature::Audio | Feature::Privacy).value) == 0
          raise ArgumentError.new("unsupported Camera AV Stream Management feature")
        end
        unless @microphone_min_level <= @microphone_volume_level &&
               @microphone_volume_level <= @microphone_max_level && @microphone_max_level <= MAX_VOLUME_LEVEL
          raise ArgumentError.new("invalid microphone volume range")
        end
        usages = supported_stream_usages.dup
        if usages.uniq.size != usages.size || usages.empty? ||
           !usages.all? { |usage| usage.in?(StreamUsage::Internal, StreamUsage::Recording, StreamUsage::Analysis, StreamUsage::LiveView) }
          raise ArgumentError.new("SupportedStreamUsages must contain unique known usages")
        end
        @microphone_capabilities = microphone_capabilities
        @supported_stream_usages = usages
        @stream_usage_priorities = usages.dup
        @allocated_audio_streams = [] of AudioStream
      end

      def microphone_capabilities : AudioCapabilities
        @microphone_capabilities
      end

      def supported_stream_usages : Array(StreamUsage)
        @supported_stream_usages.dup
      end

      def stream_usage_priorities : Array(StreamUsage)
        @stream_usage_priorities.dup
      end

      def allocated_audio_streams : Array(AudioStream)
        @allocated_audio_streams.dup
      end

      def on_audio_allocate(&block : AudioStreamAllocateRequest, UInt16 -> InteractionModel::Status) : Nil
        @audio_allocate_callback = block
      end

      def on_audio_deallocate(&block : UInt16 -> InteractionModel::Status) : Nil
        @audio_deallocate_callback = block
      end

      # The host pauses/resumes actual media delivery when privacy changes.
      def on_privacy_changed(&block : Bool, Bool, Bool -> Nil) : Nil
        @privacy_callback = block
        report_privacy_state
      end

      # Apply mute and gain to the physical microphone in the host.
      def on_microphone_settings_changed(&block : Bool, UInt8 -> Nil) : Nil
        @microphone_callback = block
        report_microphone_settings
      end

      # Independent consumers can react to delivery restrictions without
      # replacing the host's physical microphone and privacy callbacks.
      def on_delivery_changed(&block : -> Nil) : Nil
        @delivery_observers << block
        block.call
      end

      def on_audio_released(&block : UInt16 -> Nil) : Nil
        @audio_release_observers << block
      end

      def stream_delivery_allowed?(usage : StreamUsage) : Bool
        return false if @hard_privacy_mode_on || @microphone_muted
        return false if @feature_map.privacy? && usage == StreamUsage::LiveView && @soft_livestream_privacy_mode_enabled
        return false if @feature_map.privacy? && usage.in?(StreamUsage::Recording, StreamUsage::Analysis) && @soft_recording_privacy_mode_enabled
        true
      end

      def audio_stream_allocate(request : AudioStreamAllocateRequest) : InteractionModel::Status | AudioStreamAllocateResponse
        return InteractionModel::Status.constraint_error unless valid_audio_request?(request)
        existing_index = @allocated_audio_streams.index(&.matches?(request))
        if existing_index
          existing = @allocated_audio_streams[existing_index]
          return InteractionModel::Status.resource_exhausted if existing.reference_count == MAX_REFERENCE_COUNT
          @allocated_audio_streams[existing_index] = existing.with_reference_count(existing.reference_count + 1_u8)
          increment_version_and_notify(ATTR_ALLOCATED_AUDIO_STREAMS)
          return AudioStreamAllocateResponse.new(existing.audio_stream_id)
        end

        return InteractionModel::Status.resource_exhausted if used_bandwidth.to_u64 + request.bit_rate > @max_network_bandwidth
        callback = @audio_allocate_callback || return InteractionModel::Status.invalid_in_state
        id = next_available_audio_id || return InteractionModel::Status.resource_exhausted
        status = callback.call(request, id)
        return status unless status.success?

        @allocated_audio_streams << AudioStream.new(id, request.stream_usage, request.audio_codec,
          request.channel_count, request.sample_rate, request.bit_rate, request.bit_depth, 1_u8)
        @next_audio_stream_id = advance_audio_id(id)
        increment_version_and_notify(ATTR_ALLOCATED_AUDIO_STREAMS)
        AudioStreamAllocateResponse.new(id)
      end

      def audio_stream_deallocate(request : AudioStreamDeallocateRequest) : InteractionModel::Status
        index = @allocated_audio_streams.index { |stream| stream.audio_stream_id == request.audio_stream_id }
        return InteractionModel::Status.not_found unless index
        stream = @allocated_audio_streams[index]
        if stream.reference_count > 1_u8
          @allocated_audio_streams[index] = stream.with_reference_count(stream.reference_count - 1_u8)
        else
          callback = @audio_deallocate_callback || return InteractionModel::Status.invalid_in_state
          status = callback.call(stream.audio_stream_id)
          return status unless status.success?
          @allocated_audio_streams.delete_at(index)
          @audio_release_observers.each(&.call(stream.audio_stream_id))
        end
        increment_version_and_notify(ATTR_ALLOCATED_AUDIO_STREAMS)
        InteractionModel::Status.success
      end

      def apply_stream_priorities(request : SetStreamPrioritiesRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state unless @allocated_audio_streams.empty?
        priorities = request.stream_priorities
        return InteractionModel::Status.constraint_error if priorities.empty? || priorities.uniq.size != priorities.size
        return InteractionModel::Status.constraint_error unless priorities.all? { |usage| @supported_stream_usages.includes?(usage) }
        return InteractionModel::Status.success if priorities == @stream_usage_priorities
        @stream_usage_priorities = priorities.dup
        increment_version_and_notify(ATTR_STREAM_USAGE_PRIORITIES)
        InteractionModel::Status.success
      end

      private def valid_audio_request?(request : AudioStreamAllocateRequest) : Bool
        return false unless request.stream_usage.in?(StreamUsage::Recording, StreamUsage::Analysis, StreamUsage::LiveView)
        return false unless @supported_stream_usages.includes?(request.stream_usage)
        return false unless @microphone_capabilities.supported_codecs.includes?(request.audio_codec)
        return false unless request.channel_count.in?(MIN_CHANNEL_COUNT..MAX_CHANNEL_COUNT)
        return false if request.channel_count > @microphone_capabilities.max_number_of_channels
        return false unless @microphone_capabilities.supported_sample_rates.includes?(request.sample_rate)
        return false unless @microphone_capabilities.supported_bit_depths.includes?(request.bit_depth)
        return false if request.bit_rate.zero?
        true
      end

      private def used_bandwidth : UInt64
        @allocated_audio_streams.sum(0_u64, &.bit_rate.to_u64)
      end

      private def advance_audio_id(id : UInt16) : UInt16
        id == MAX_STREAM_ID ? 0_u16 : id + 1_u16
      end

      private def next_available_audio_id : UInt16?
        candidate = @next_audio_stream_id
        loop do
          return candidate unless @allocated_audio_streams.any?(&.audio_stream_id.==(candidate))
          candidate = advance_audio_id(candidate)
          return if candidate == @next_audio_stream_id
        end
      end

      private def notify_privacy(_value : Bool) : Nil
        report_privacy_state
      end

      private def report_privacy_state : Nil
        @privacy_callback.try(&.call(@hard_privacy_mode_on,
          @soft_recording_privacy_mode_enabled, @soft_livestream_privacy_mode_enabled))
        @delivery_observers.each(&.call)
      end

      private def notify_microphone(_value : Bool | UInt8) : Nil
        report_microphone_settings
      end

      private def report_microphone_settings : Nil
        @microphone_callback.try(&.call(@microphone_muted, @microphone_volume_level))
        @delivery_observers.each(&.call)
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        document["stream_usage_priorities"] = Storage::Record.encode(@stream_usage_priorities)
        document["next_audio_stream_id"] = @next_audio_stream_id.to_i64
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        if encoded = document["stream_usage_priorities"]?
          priorities = Storage::Record.decode(encoded, Array(StreamUsage), "stream_usage_priorities")
          if !priorities.empty? && priorities.uniq.size == priorities.size &&
             priorities.all? { |usage| @supported_stream_usages.includes?(usage) }
            @stream_usage_priorities = priorities
          end
        end
        if encoded_id = document["next_audio_stream_id"]?
          id = Storage::Record.decode(encoded_id, UInt16, "next_audio_stream_id")
          @next_audio_stream_id = id if id <= MAX_STREAM_ID
        end
      end

      private def after_restore_state : Nil
        @microphone_volume_level = @microphone_min_level unless @microphone_volume_level.in?(@microphone_min_level..@microphone_max_level)
        @allocated_audio_streams.clear
      end
    end
  end
end
