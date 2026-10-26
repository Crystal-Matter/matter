require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Camera AV Stream Management revision 2, Audio, Video,
    # Snapshot, and opt-in Snapshot Watermark and OSD features.
    # The host admits and releases actual media; this class manages only the
    # Matter allocation and settings state, not encoding or transport.
    class CameraAvStreamManagement < Base
      cluster 0x0551, revision: 2

      feature :audio, bit: 0
      feature :video, bit: 1
      feature :snapshot, bit: 2
      feature :privacy, bit: 3
      feature :watermark, bit: 6
      feature :osd, bit: 7

      MAX_STREAM_ID          = 65_534_u16
      MAX_REFERENCE_COUNT    =     255_u8
      MIN_CHANNEL_COUNT      =       1_u8
      MAX_CHANNEL_COUNT      =       8_u8
      MAX_VOLUME_LEVEL       =     254_u8
      MAX_KEY_FRAME_INTERVAL = 65_500_u16
      MAX_SNAPSHOT_QUALITY   =     100_u8
      MAX_SNAPSHOT_DATA_SIZE =     65_000
      SUPPORTED_BIT_DEPTHS   = [8_u8, 16_u8, 24_u8, 32_u8]

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

      enum ImageCodec : UInt8
        Jpeg = 0
        Heic = 1
      end

      enum VideoCodec : UInt8
        H264 = 0
        Hevc = 1
        Vvc  = 2
        Av1  = 3
      end

      struct VideoResolution
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter width : UInt16

        @[TLV::Field(tag: 1)]
        getter height : UInt16

        def initialize(@width : UInt16, @height : UInt16)
          raise ArgumentError.new("video resolution must be positive") if @width.zero? || @height.zero?
        end
      end

      struct VideoSensorParams
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter sensor_width : UInt16

        @[TLV::Field(tag: 1)]
        getter sensor_height : UInt16

        @[TLV::Field(tag: 2)]
        getter max_fps : UInt16

        def initialize(@sensor_width : UInt16, @sensor_height : UInt16, @max_fps : UInt16)
          raise ArgumentError.new("video sensor must be at least 64 by 64") if @sensor_width < 64 || @sensor_height < 64
          raise ArgumentError.new("video sensor frame rate must be positive") if @max_fps.zero?
        end
      end

      struct Viewport
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter x1 : UInt16

        @[TLV::Field(tag: 1)]
        getter y1 : UInt16

        @[TLV::Field(tag: 2)]
        getter x2 : UInt16

        @[TLV::Field(tag: 3)]
        getter y2 : UInt16

        def initialize(@x1 : UInt16, @y1 : UInt16, @x2 : UInt16, @y2 : UInt16)
        end
      end

      struct RateDistortionPoint
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter codec : VideoCodec

        @[TLV::Field(tag: 1)]
        getter resolution : VideoResolution

        @[TLV::Field(tag: 2)]
        getter min_bit_rate : UInt32

        def initialize(@codec : VideoCodec, @resolution : VideoResolution, @min_bit_rate : UInt32)
          raise ArgumentError.new("video minimum bit rate must be positive") if @min_bit_rate.zero?
          unless @codec.in?(VideoCodec::H264, VideoCodec::Hevc, VideoCodec::Vvc, VideoCodec::Av1)
            raise ArgumentError.new("unsupported video codec")
          end
        end
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

      struct VideoStream
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter video_stream_id : UInt16

        @[TLV::Field(tag: 1)]
        getter stream_usage : StreamUsage

        @[TLV::Field(tag: 2)]
        getter video_codec : VideoCodec

        @[TLV::Field(tag: 3)]
        getter min_frame_rate : UInt16

        @[TLV::Field(tag: 4)]
        getter max_frame_rate : UInt16

        @[TLV::Field(tag: 5)]
        getter min_resolution : VideoResolution

        @[TLV::Field(tag: 6)]
        getter max_resolution : VideoResolution

        @[TLV::Field(tag: 7)]
        getter min_bit_rate : UInt32

        @[TLV::Field(tag: 8)]
        getter max_bit_rate : UInt32

        @[TLV::Field(tag: 9)]
        getter key_frame_interval : UInt16

        @[TLV::Field(tag: 12)]
        getter reference_count : UInt8

        def initialize(@video_stream_id : UInt16, request : VideoStreamAllocateRequest, @reference_count : UInt8)
          @stream_usage = request.stream_usage
          @video_codec = request.video_codec
          @min_frame_rate = request.min_frame_rate
          @max_frame_rate = request.max_frame_rate
          @min_resolution = request.min_resolution
          @max_resolution = request.max_resolution
          @min_bit_rate = request.min_bit_rate
          @max_bit_rate = request.max_bit_rate
          @key_frame_interval = request.key_frame_interval
        end

        def matches?(request : VideoStreamAllocateRequest) : Bool
          @stream_usage == request.stream_usage && @video_codec == request.video_codec &&
            @min_frame_rate == request.min_frame_rate && @max_frame_rate == request.max_frame_rate &&
            @min_resolution == request.min_resolution && @max_resolution == request.max_resolution &&
            @min_bit_rate == request.min_bit_rate && @max_bit_rate == request.max_bit_rate &&
            @key_frame_interval == request.key_frame_interval
        end

        def with_reference_count(count : UInt8) : VideoStream
          VideoStream.new(@video_stream_id,
            VideoStreamAllocateRequest.new(@stream_usage, @video_codec, @min_frame_rate, @max_frame_rate,
              @min_resolution, @max_resolution, @min_bit_rate, @max_bit_rate, @key_frame_interval), count)
        end
      end

      struct VideoStreamAllocateRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter stream_usage : StreamUsage

        @[TLV::Field(tag: 1)]
        getter video_codec : VideoCodec

        @[TLV::Field(tag: 2)]
        getter min_frame_rate : UInt16

        @[TLV::Field(tag: 3)]
        getter max_frame_rate : UInt16

        @[TLV::Field(tag: 4)]
        getter min_resolution : VideoResolution

        @[TLV::Field(tag: 5)]
        getter max_resolution : VideoResolution

        @[TLV::Field(tag: 6)]
        getter min_bit_rate : UInt32

        @[TLV::Field(tag: 7)]
        getter max_bit_rate : UInt32

        @[TLV::Field(tag: 8)]
        getter key_frame_interval : UInt16

        def initialize(@stream_usage : StreamUsage, @video_codec : VideoCodec,
                       @min_frame_rate : UInt16, @max_frame_rate : UInt16,
                       @min_resolution : VideoResolution, @max_resolution : VideoResolution,
                       @min_bit_rate : UInt32, @max_bit_rate : UInt32,
                       @key_frame_interval : UInt16)
        end
      end

      struct VideoStreamAllocateResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter video_stream_id : UInt16

        def initialize(@video_stream_id : UInt16)
        end
      end

      struct VideoStreamDeallocateRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter video_stream_id : UInt16

        def initialize(@video_stream_id : UInt16)
        end
      end

      struct SnapshotCapability
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter resolution : VideoResolution

        @[TLV::Field(tag: 1)]
        getter max_frame_rate : UInt16

        @[TLV::Field(tag: 2)]
        getter image_codec : ImageCodec

        @[TLV::Field(tag: 3)]
        getter? requires_encoded_pixels : Bool

        @[TLV::Field(tag: 4)]
        getter requires_hardware_encoder : Bool?

        def initialize(@resolution : VideoResolution, @max_frame_rate : UInt16,
                       @image_codec : ImageCodec, @requires_encoded_pixels : Bool,
                       @requires_hardware_encoder : Bool? = nil)
          raise ArgumentError.new("snapshot frame rate must be positive") if @max_frame_rate.zero?
          raise ArgumentError.new("unsupported snapshot codec") unless @image_codec.in?(ImageCodec::Jpeg, ImageCodec::Heic)
          if @requires_encoded_pixels && @requires_hardware_encoder.nil?
            raise ArgumentError.new("encoded snapshot capability requires hardware encoder declaration")
          end
          if !@requires_encoded_pixels && !@requires_hardware_encoder.nil?
            raise ArgumentError.new("unencoded snapshot capability must omit hardware encoder declaration")
          end
        end
      end

      struct SnapshotStreamAllocateRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter image_codec : ImageCodec

        @[TLV::Field(tag: 1)]
        getter max_frame_rate : UInt16

        @[TLV::Field(tag: 2)]
        getter min_resolution : VideoResolution

        @[TLV::Field(tag: 3)]
        getter max_resolution : VideoResolution

        @[TLV::Field(tag: 4)]
        getter quality : UInt8

        @[TLV::Field(tag: 5)]
        getter watermark_enabled : Bool?

        @[TLV::Field(tag: 6)]
        getter osd_enabled : Bool?

        def initialize(@image_codec : ImageCodec, @max_frame_rate : UInt16,
                       @min_resolution : VideoResolution, @max_resolution : VideoResolution,
                       @quality : UInt8, @watermark_enabled : Bool? = nil, @osd_enabled : Bool? = nil)
        end
      end

      struct SnapshotStream
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter snapshot_stream_id : UInt16

        @[TLV::Field(tag: 1)]
        getter image_codec : ImageCodec

        @[TLV::Field(tag: 2)]
        getter frame_rate : UInt16

        @[TLV::Field(tag: 3)]
        getter min_resolution : VideoResolution

        @[TLV::Field(tag: 4)]
        getter max_resolution : VideoResolution

        @[TLV::Field(tag: 5)]
        getter quality : UInt8

        @[TLV::Field(tag: 6)]
        getter reference_count : UInt8

        @[TLV::Field(tag: 7)]
        getter? encoded_pixels : Bool

        @[TLV::Field(tag: 8)]
        getter? hardware_encoder : Bool

        @[TLV::Field(tag: 9, optional: true)]
        getter watermark_enabled : Bool?

        @[TLV::Field(tag: 10, optional: true)]
        getter osd_enabled : Bool?

        def initialize(@snapshot_stream_id : UInt16, @image_codec : ImageCodec,
                       @frame_rate : UInt16, @min_resolution : VideoResolution,
                       @max_resolution : VideoResolution, @quality : UInt8,
                       @reference_count : UInt8, @encoded_pixels : Bool,
                       @hardware_encoder : Bool, @watermark_enabled : Bool? = nil,
                       @osd_enabled : Bool? = nil)
        end

        def matches?(request : SnapshotStreamAllocateRequest) : Bool
          @image_codec == request.image_codec && @frame_rate == request.max_frame_rate &&
            @min_resolution == request.min_resolution && @max_resolution == request.max_resolution &&
            @quality == request.quality && @watermark_enabled == request.watermark_enabled &&
            @osd_enabled == request.osd_enabled
        end

        def with_reference_count(count : UInt8) : SnapshotStream
          SnapshotStream.new(@snapshot_stream_id, @image_codec, @frame_rate, @min_resolution,
            @max_resolution, @quality, count, @encoded_pixels, @hardware_encoder,
            @watermark_enabled, @osd_enabled)
        end

        def with_overlays(watermark_enabled : Bool?, osd_enabled : Bool?) : SnapshotStream
          SnapshotStream.new(@snapshot_stream_id, @image_codec, @frame_rate, @min_resolution,
            @max_resolution, @quality, @reference_count, @encoded_pixels, @hardware_encoder,
            watermark_enabled, osd_enabled)
        end
      end

      struct SnapshotStreamAllocateResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter snapshot_stream_id : UInt16

        def initialize(@snapshot_stream_id : UInt16)
        end
      end

      struct SnapshotStreamDeallocateRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter snapshot_stream_id : UInt16

        def initialize(@snapshot_stream_id : UInt16)
        end
      end

      struct SnapshotStreamModifyRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter snapshot_stream_id : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        getter watermark_enabled : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        getter osd_enabled : Bool?

        def initialize(@snapshot_stream_id : UInt16,
                       @watermark_enabled : Bool? = nil, @osd_enabled : Bool? = nil)
        end
      end

      struct CaptureSnapshotRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter snapshot_stream_id : TLV::FieldState(UInt16)

        @[TLV::Field(tag: 1)]
        getter requested_resolution : VideoResolution

        def initialize(@snapshot_stream_id : TLV::FieldState(UInt16),
                       @requested_resolution : VideoResolution)
        end

        def initialize(snapshot_stream_id : UInt16, @requested_resolution : VideoResolution)
          @snapshot_stream_id = TLV::FieldState(UInt16).value(snapshot_stream_id)
        end
      end

      struct SnapshotImage
        getter data : Bytes
        getter image_codec : ImageCodec
        getter resolution : VideoResolution

        def initialize(data : Bytes, @image_codec : ImageCodec, @resolution : VideoResolution)
          @data = data.dup
        end
      end

      struct CaptureSnapshotResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter data : Bytes

        @[TLV::Field(tag: 1)]
        getter image_codec : ImageCodec

        @[TLV::Field(tag: 2)]
        getter resolution : VideoResolution

        def initialize(data : Bytes, @image_codec : ImageCodec, @resolution : VideoResolution)
          @data = data.dup
        end
      end

      struct SetStreamPrioritiesRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter stream_priorities : Array(StreamUsage)

        def initialize(@stream_priorities : Array(StreamUsage))
        end
      end

      attribute 0x0000, :max_concurrent_encoders, UInt8, default: 0_u8, fixed: true, present_if: :video_or_snapshot?
      attribute 0x0001, :max_encoded_pixel_rate, UInt32, default: 0_u32, fixed: true, present_if: :video_or_snapshot?
      attribute 0x0002, :video_sensor_params, VideoSensorParams, computed: true, fixed: true, requires: :video
      attribute 0x0004, :min_viewport_resolution, VideoResolution, computed: true, fixed: true, requires: :video
      attribute 0x0005, :rate_distortion_trade_off_points, Array(RateDistortionPoint), computed: true, fixed: true, requires: :video
      attribute 0x0006, :max_content_buffer_size, UInt32, default: 0_u32, fixed: true
      attribute 0x0007, :microphone_capabilities, AudioCapabilities, computed: true, fixed: true, requires: :audio
      attribute 0x000A, :snapshot_capabilities, Array(SnapshotCapability), computed: true, fixed: true, requires: :snapshot
      attribute 0x000B, :max_network_bandwidth, UInt32, default: 0_u32, fixed: true
      attribute 0x000C, :current_frame_rate, UInt16, default: 0_u16, requires: :video
      attribute 0x000E, :supported_stream_usages, Array(StreamUsage), computed: true, fixed: true
      attribute 0x000F, :allocated_video_streams, Array(VideoStream), computed: true, requires: :video
      attribute 0x0010, :allocated_audio_streams, Array(AudioStream), computed: true, requires: :audio
      attribute 0x0011, :allocated_snapshot_streams, Array(SnapshotStream), computed: true, requires: :snapshot
      attribute 0x0012, :stream_usage_priorities, Array(StreamUsage), computed: true
      attribute 0x0013, :soft_recording_privacy_mode_enabled, Bool, default: false,
        writable: true, write_access: :operate, persist: true, requires: :privacy, on_change: :notify_privacy
      attribute 0x0014, :soft_livestream_privacy_mode_enabled, Bool, default: false,
        writable: true, write_access: :operate, persist: true, requires: :privacy, on_change: :notify_privacy
      attribute 0x0015, :hard_privacy_mode_on, Bool, default: false, on_change: :notify_privacy
      attribute 0x0018, :viewport, Viewport, computed: true, writable: true,
        read_access: :manage, write_access: :manage, requires: :video
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

      before_write :viewport do |value|
        InteractionModel::Status.constraint_error unless valid_viewport?(value)
      end

      command 0x00, :audio_stream_allocate, request: AudioStreamAllocateRequest,
        response: AudioStreamAllocateResponse, response_id: 0x01, access: :manage, requires: :audio
      command 0x02, :audio_stream_deallocate, request: AudioStreamDeallocateRequest,
        access: :manage, requires: :audio
      command 0x03, :video_stream_allocate, request: VideoStreamAllocateRequest,
        response: VideoStreamAllocateResponse, response_id: 0x04, access: :manage, requires: :video
      command 0x06, :video_stream_deallocate, request: VideoStreamDeallocateRequest,
        access: :manage, requires: :video
      command 0x07, :snapshot_stream_allocate, request: SnapshotStreamAllocateRequest,
        response: SnapshotStreamAllocateResponse, response_id: 0x08, access: :manage, requires: :snapshot
      command 0x09, :snapshot_stream_modify, request: SnapshotStreamModifyRequest,
        access: :manage, requires: [{snapshot: true, watermark: true}, {snapshot: true, osd: true}]
      command 0x0A, :snapshot_stream_deallocate, request: SnapshotStreamDeallocateRequest,
        access: :manage, requires: :snapshot
      command 0x0C, :capture_snapshot, request: CaptureSnapshotRequest,
        response: CaptureSnapshotResponse, response_id: 0x0D, access: :operate, requires: :snapshot
      command 0x0B, :set_stream_priorities, request: SetStreamPrioritiesRequest,
        access: :administer, handler: :apply_stream_priorities

      @audio_allocate_callback : Proc(AudioStreamAllocateRequest, UInt16, InteractionModel::Status)?
      @audio_deallocate_callback : Proc(UInt16, InteractionModel::Status)?
      @video_allocate_callback : Proc(VideoStreamAllocateRequest, UInt16, InteractionModel::Status)?
      @video_deallocate_callback : Proc(UInt16, InteractionModel::Status)?
      @snapshot_allocate_callback : Proc(SnapshotStreamAllocateRequest, UInt16, InteractionModel::Status)?
      @snapshot_modify_callback : Proc(UInt16, Bool?, Bool?, InteractionModel::Status)?
      @snapshot_deallocate_callback : Proc(UInt16, InteractionModel::Status)?
      @snapshot_capture_callback : Proc(SnapshotStream, VideoResolution, SnapshotImage | InteractionModel::Status)?
      @next_snapshot_stream_id : UInt16 = 0_u16
      @snapshot_capabilities : Array(SnapshotCapability)
      @allocated_snapshot_streams : Array(SnapshotStream)
      @privacy_callback : Proc(Bool, Bool, Bool, Nil)?
      @microphone_callback : Proc(Bool, UInt8, Nil)?
      @delivery_observers = [] of Proc(Nil)
      @audio_release_observers = [] of Proc(UInt16, Nil)
      @video_release_observers = [] of Proc(UInt16, Nil)
      @next_audio_stream_id : UInt16 = 0_u16
      @next_video_stream_id : UInt16 = 0_u16
      @microphone_capabilities : AudioCapabilities?
      @video_sensor_params : VideoSensorParams?
      @min_viewport_resolution : VideoResolution?
      @rate_distortion_trade_off_points : Array(RateDistortionPoint)
      @viewport : Viewport
      @supported_stream_usages : Array(StreamUsage)
      @stream_usage_priorities : Array(StreamUsage)
      @allocated_audio_streams : Array(AudioStream)
      @allocated_video_streams : Array(VideoStream)

      def initialize(endpoint_id : DataType::EndpointNumber,
                     supported_stream_usages : Array(StreamUsage),
                     @max_content_buffer_size : UInt32,
                     @max_network_bandwidth : UInt32,
                     @microphone_capabilities : AudioCapabilities? = nil,
                     @video_sensor_params : VideoSensorParams? = nil,
                     @min_viewport_resolution : VideoResolution? = nil,
                     rate_distortion_trade_off_points : Array(RateDistortionPoint) = [] of RateDistortionPoint,
                     snapshot_capabilities : Array(SnapshotCapability) = [] of SnapshotCapability,
                     @max_concurrent_encoders : UInt8 = 0_u8,
                     @max_encoded_pixel_rate : UInt32 = 0_u32,
                     @microphone_min_level : UInt8 = 0_u8,
                     @microphone_max_level : UInt8 = 100_u8,
                     @microphone_volume_level : UInt8 = 50_u8,
                     @feature_map : Feature = Feature::Audio)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("Audio, Video or Snapshot feature is required") unless @feature_map.audio? || @feature_map.video? || @feature_map.snapshot?
        unless (@feature_map.value & ~(Feature::Audio | Feature::Video | Feature::Snapshot | Feature::Privacy | Feature::Watermark | Feature::Osd).value) == 0
          raise ArgumentError.new("unsupported Camera AV Stream Management feature")
        end
        if (@feature_map.watermark? || @feature_map.osd?) && (!@feature_map.snapshot? || @feature_map.video?)
          raise ArgumentError.new("Watermark and OSD currently require Snapshot without Video")
        end
        raise ArgumentError.new("Audio feature requires microphone capabilities") if @feature_map.audio? && !@microphone_capabilities
        if @feature_map.snapshot?
          raise ArgumentError.new("Snapshot feature requires capabilities") if snapshot_capabilities.empty?
          raise ArgumentError.new("duplicate snapshot capability") unless snapshot_capabilities.uniq.size == snapshot_capabilities.size
          raise ArgumentError.new("Snapshot feature requires encoders and pixel rate") if @max_concurrent_encoders.zero? || @max_encoded_pixel_rate.zero?
        end
        @snapshot_capabilities = snapshot_capabilities.dup
        if @feature_map.video?
          sensor = @video_sensor_params || raise ArgumentError.new("Video feature requires sensor parameters")
          viewport = @min_viewport_resolution || raise ArgumentError.new("Video feature requires viewport resolution")
          raise ArgumentError.new("Video feature requires encoders and pixel rate") if @max_concurrent_encoders.zero? || @max_encoded_pixel_rate.zero?
          raise ArgumentError.new("viewport exceeds sensor") if viewport.width > sensor.sensor_width || viewport.height > sensor.sensor_height
          raise ArgumentError.new("Video feature requires rate distortion points") if rate_distortion_trade_off_points.empty?
          unless rate_distortion_trade_off_points.any?(&.codec.==(VideoCodec::H264))
            raise ArgumentError.new("Video feature requires H.264 capability")
          end
          unless rate_distortion_trade_off_points.all? do |point|
                   point.resolution.width <= sensor.sensor_width && point.resolution.height <= sensor.sensor_height
                 end
            raise ArgumentError.new("rate distortion point exceeds sensor")
          end
        end
        @rate_distortion_trade_off_points = rate_distortion_trade_off_points.dup
        @viewport = if sensor = @video_sensor_params
                      Viewport.new(0_u16, 0_u16, sensor.sensor_width, sensor.sensor_height)
                    else
                      Viewport.new(0_u16, 0_u16, 0_u16, 0_u16)
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
        @supported_stream_usages = usages
        @stream_usage_priorities = usages.dup
        @allocated_audio_streams = [] of AudioStream
        @allocated_video_streams = [] of VideoStream
        @allocated_snapshot_streams = [] of SnapshotStream
      end

      def microphone_capabilities : AudioCapabilities
        @microphone_capabilities || raise ArgumentError.new("Audio feature is disabled")
      end

      def video_sensor_params : VideoSensorParams
        @video_sensor_params || raise ArgumentError.new("Video feature is disabled")
      end

      def min_viewport_resolution : VideoResolution
        @min_viewport_resolution || raise ArgumentError.new("Video feature is disabled")
      end

      def rate_distortion_trade_off_points : Array(RateDistortionPoint)
        @rate_distortion_trade_off_points.dup
      end

      def video_or_snapshot? : Bool
        @feature_map.video? || @feature_map.snapshot?
      end

      def snapshot_capabilities : Array(SnapshotCapability)
        @snapshot_capabilities.dup
      end

      def allocated_snapshot_streams : Array(SnapshotStream)
        @allocated_snapshot_streams.dup
      end

      def on_snapshot_allocate(&block : SnapshotStreamAllocateRequest, UInt16 -> InteractionModel::Status) : Nil
        @snapshot_allocate_callback = block
      end

      def on_snapshot_modify(&block : UInt16, Bool -> InteractionModel::Status) : Nil
        @snapshot_modify_callback = ->(id : UInt16, watermark : Bool?, osd : Bool?) {
          if osd.nil? && !watermark.nil?
            block.call(id, watermark.as(Bool))
          else
            InteractionModel::Status.invalid_command
          end
        }
      end

      def on_snapshot_modify_overlays(&block : UInt16, Bool?, Bool? -> InteractionModel::Status) : Nil
        @snapshot_modify_callback = block
      end

      def on_snapshot_deallocate(&block : UInt16 -> InteractionModel::Status) : Nil
        @snapshot_deallocate_callback = block
      end

      def on_snapshot_capture(&block : SnapshotStream, VideoResolution -> SnapshotImage | InteractionModel::Status) : Nil
        @snapshot_capture_callback = block
      end

      def allocated_video_streams : Array(VideoStream)
        @allocated_video_streams.dup
      end

      def viewport : Viewport
        @viewport
      end

      def viewport=(value : Viewport) : Nil
        unless valid_viewport?(value)
          raise ClusterError.new("Viewport exceeds sensor or falls below minimum resolution",
            InteractionModel::StatusCode::ConstraintError)
        end
        return if @viewport == value
        @viewport = value
        increment_version_and_notify(ATTR_VIEWPORT)
      end

      def on_video_allocate(&block : VideoStreamAllocateRequest, UInt16 -> InteractionModel::Status) : Nil
        @video_allocate_callback = block
      end

      def on_video_deallocate(&block : UInt16 -> InteractionModel::Status) : Nil
        @video_deallocate_callback = block
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

      def on_video_released(&block : UInt16 -> Nil) : Nil
        @video_release_observers << block
      end

      def stream_delivery_allowed?(usage : StreamUsage) : Bool
        return false if @hard_privacy_mode_on || @microphone_muted
        privacy_allows?(usage)
      end

      def video_delivery_allowed?(usage : StreamUsage) : Bool
        return false if @hard_privacy_mode_on
        privacy_allows?(usage)
      end

      private def privacy_allows?(usage : StreamUsage) : Bool
        return false if @feature_map.privacy? && usage == StreamUsage::LiveView && @soft_livestream_privacy_mode_enabled
        return false if @feature_map.privacy? && usage.in?(StreamUsage::Recording, StreamUsage::Analysis) && @soft_recording_privacy_mode_enabled
        true
      end

      def video_stream_allocate(request : VideoStreamAllocateRequest) : InteractionModel::Status | VideoStreamAllocateResponse
        return InteractionModel::Status.constraint_error unless valid_video_request?(request)
        existing_index = @allocated_video_streams.index(&.matches?(request))
        if existing_index
          existing = @allocated_video_streams[existing_index]
          return InteractionModel::Status.resource_exhausted if existing.reference_count == MAX_REFERENCE_COUNT
          @allocated_video_streams[existing_index] = existing.with_reference_count(existing.reference_count + 1_u8)
          increment_version_and_notify(ATTR_ALLOCATED_VIDEO_STREAMS)
          return VideoStreamAllocateResponse.new(existing.video_stream_id)
        end

        pixel_rate = request.max_resolution.width.to_u64 * request.max_resolution.height * request.max_frame_rate
        return InteractionModel::Status.resource_exhausted if used_encoders >= @max_concurrent_encoders
        return InteractionModel::Status.resource_exhausted if used_pixel_rate + pixel_rate > @max_encoded_pixel_rate
        return InteractionModel::Status.resource_exhausted if used_bandwidth + request.max_bit_rate.to_u64 > @max_network_bandwidth
        callback = @video_allocate_callback || return InteractionModel::Status.invalid_in_state
        id = next_available_video_id || return InteractionModel::Status.resource_exhausted
        status = callback.call(request, id)
        return status unless status.success?

        @allocated_video_streams << VideoStream.new(id, request, 1_u8)
        @next_video_stream_id = advance_audio_id(id)
        increment_version_and_notify(ATTR_ALLOCATED_VIDEO_STREAMS)
        VideoStreamAllocateResponse.new(id)
      end

      def video_stream_deallocate(request : VideoStreamDeallocateRequest) : InteractionModel::Status
        index = @allocated_video_streams.index { |stream| stream.video_stream_id == request.video_stream_id }
        return InteractionModel::Status.not_found unless index
        stream = @allocated_video_streams[index]
        if stream.reference_count > 1_u8
          @allocated_video_streams[index] = stream.with_reference_count(stream.reference_count - 1_u8)
        else
          callback = @video_deallocate_callback || return InteractionModel::Status.invalid_in_state
          status = callback.call(stream.video_stream_id)
          return status unless status.success?
          @allocated_video_streams.delete_at(index)
          @video_release_observers.each(&.call(stream.video_stream_id))
        end
        increment_version_and_notify(ATTR_ALLOCATED_VIDEO_STREAMS)
        InteractionModel::Status.success
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

      def snapshot_stream_allocate(request : SnapshotStreamAllocateRequest) : InteractionModel::Status | SnapshotStreamAllocateResponse
        if @feature_map.watermark?
          return InteractionModel::Status.invalid_command if request.watermark_enabled.nil?
        else
          return InteractionModel::Status.invalid_command unless request.watermark_enabled.nil?
        end
        if @feature_map.osd?
          return InteractionModel::Status.invalid_command if request.osd_enabled.nil?
        else
          return InteractionModel::Status.invalid_command unless request.osd_enabled.nil?
        end
        capability = matching_snapshot_capability(request) || return InteractionModel::Status.constraint_error
        if index = @allocated_snapshot_streams.index(&.matches?(request))
          stream = @allocated_snapshot_streams[index]
          return InteractionModel::Status.resource_exhausted if stream.reference_count == MAX_REFERENCE_COUNT
          @allocated_snapshot_streams[index] = stream.with_reference_count(stream.reference_count + 1_u8)
          increment_version_and_notify(ATTR_ALLOCATED_SNAPSHOT_STREAMS)
          return SnapshotStreamAllocateResponse.new(stream.snapshot_stream_id)
        end
        encoded_pixels = capability.requires_encoded_pixels?
        hardware_encoder = capability.requires_hardware_encoder || false
        pixel_rate = request.max_resolution.width.to_u64 * request.max_resolution.height * request.max_frame_rate
        return InteractionModel::Status.resource_exhausted if hardware_encoder && used_encoders >= @max_concurrent_encoders
        return InteractionModel::Status.resource_exhausted if encoded_pixels && used_pixel_rate + pixel_rate > @max_encoded_pixel_rate
        callback = @snapshot_allocate_callback || return InteractionModel::Status.invalid_in_state
        id = next_available_snapshot_id || return InteractionModel::Status.resource_exhausted
        status = callback.call(request, id)
        return status unless status.success?
        @allocated_snapshot_streams << SnapshotStream.new(id, request.image_codec, request.max_frame_rate,
          request.min_resolution, request.max_resolution, request.quality, 1_u8, encoded_pixels,
          hardware_encoder, request.watermark_enabled, request.osd_enabled)
        @next_snapshot_stream_id = advance_audio_id(id)
        increment_version_and_notify(ATTR_ALLOCATED_SNAPSHOT_STREAMS)
        SnapshotStreamAllocateResponse.new(id)
      end

      def snapshot_stream_modify(request : SnapshotStreamModifyRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command if request.watermark_enabled.nil? && request.osd_enabled.nil?
        return InteractionModel::Status.invalid_command if !request.watermark_enabled.nil? && !@feature_map.watermark?
        return InteractionModel::Status.invalid_command if !request.osd_enabled.nil? && !@feature_map.osd?
        index = @allocated_snapshot_streams.index { |stream| stream.snapshot_stream_id == request.snapshot_stream_id }
        return InteractionModel::Status.not_found unless index
        current = @allocated_snapshot_streams[index]
        watermark = request.watermark_enabled.nil? ? current.watermark_enabled : request.watermark_enabled
        osd = request.osd_enabled.nil? ? current.osd_enabled : request.osd_enabled
        return InteractionModel::Status.success if current.watermark_enabled == watermark && current.osd_enabled == osd
        callback = @snapshot_modify_callback || return InteractionModel::Status.invalid_in_state
        status = callback.call(request.snapshot_stream_id, request.watermark_enabled, request.osd_enabled)
        return status unless status.success?
        @allocated_snapshot_streams[index] = current.with_overlays(watermark, osd)
        increment_version_and_notify(ATTR_ALLOCATED_SNAPSHOT_STREAMS)
        InteractionModel::Status.success
      end

      def snapshot_stream_deallocate(request : SnapshotStreamDeallocateRequest) : InteractionModel::Status
        index = @allocated_snapshot_streams.index { |stream| stream.snapshot_stream_id == request.snapshot_stream_id }
        return InteractionModel::Status.not_found unless index
        stream = @allocated_snapshot_streams[index]
        if stream.reference_count > 1_u8
          @allocated_snapshot_streams[index] = stream.with_reference_count(stream.reference_count - 1_u8)
        else
          callback = @snapshot_deallocate_callback || return InteractionModel::Status.invalid_in_state
          status = callback.call(stream.snapshot_stream_id)
          return status unless status.success?
          @allocated_snapshot_streams.delete_at(index)
        end
        increment_version_and_notify(ATTR_ALLOCATED_SNAPSHOT_STREAMS)
        InteractionModel::Status.success
      end

      def capture_snapshot(request : CaptureSnapshotRequest) : InteractionModel::Status | CaptureSnapshotResponse
        field = request.snapshot_stream_id
        return InteractionModel::Status.invalid_command if field.absent?
        resolution = request.requested_resolution
        return InteractionModel::Status.constraint_error if resolution.width.zero? || resolution.height.zero?
        stream = if field.null?
                   # JPEG is mandatory for SNP, so prefer it for automatic
                   # selection when more than one allocated stream fits.
                   @allocated_snapshot_streams.select { |candidate| resolution_in_snapshot_stream?(candidate, resolution) }
                     .min_by? { |candidate| {candidate.image_codec == ImageCodec::Jpeg ? 0 : 1, candidate.snapshot_stream_id} }
                 else
                   @allocated_snapshot_streams.find(&.snapshot_stream_id.==(field.value!))
                 end
        return InteractionModel::Status.not_found unless stream
        return InteractionModel::Status.constraint_error unless resolution_in_snapshot_stream?(stream, resolution)
        return InteractionModel::Status.invalid_in_state unless video_delivery_allowed?(StreamUsage::LiveView)
        callback = @snapshot_capture_callback || return InteractionModel::Status.invalid_in_state
        image = callback.call(stream, resolution)
        return image if image.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error unless image.image_codec == stream.image_codec &&
                                                                image.resolution == resolution
        return InteractionModel::Status.resource_exhausted if image.data.size > MAX_SNAPSHOT_DATA_SIZE ||
                                                              image.data.size > @max_content_buffer_size
        CaptureSnapshotResponse.new(image.data, image.image_codec, image.resolution)
      end

      def apply_stream_priorities(request : SetStreamPrioritiesRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state unless @allocated_audio_streams.empty? && @allocated_video_streams.empty? && @allocated_snapshot_streams.empty?
        priorities = request.stream_priorities
        return InteractionModel::Status.constraint_error if priorities.empty? || priorities.uniq.size != priorities.size
        return InteractionModel::Status.constraint_error unless priorities.all? { |usage| @supported_stream_usages.includes?(usage) }
        return InteractionModel::Status.success if priorities == @stream_usage_priorities
        @stream_usage_priorities = priorities.dup
        increment_version_and_notify(ATTR_STREAM_USAGE_PRIORITIES)
        InteractionModel::Status.success
      end

      private def resolution_in_snapshot_stream?(stream : SnapshotStream, resolution : VideoResolution) : Bool
        resolution.width >= stream.min_resolution.width && resolution.height >= stream.min_resolution.height &&
          resolution.width <= stream.max_resolution.width && resolution.height <= stream.max_resolution.height
      end

      private def matching_snapshot_capability(request : SnapshotStreamAllocateRequest) : SnapshotCapability?
        return if request.max_frame_rate.zero? || request.quality.zero? || request.quality > MAX_SNAPSHOT_QUALITY
        return if request.min_resolution.width.zero? || request.min_resolution.height.zero? ||
                  request.max_resolution.width.zero? || request.max_resolution.height.zero?
        return if request.min_resolution.width > request.max_resolution.width ||
                  request.min_resolution.height > request.max_resolution.height
        @snapshot_capabilities.find do |capability|
          capability.image_codec == request.image_codec && capability.max_frame_rate >= request.max_frame_rate &&
            capability.resolution.width >= request.min_resolution.width &&
            capability.resolution.height >= request.min_resolution.height &&
            capability.resolution.width <= request.max_resolution.width &&
            capability.resolution.height <= request.max_resolution.height
        end
      end

      private def valid_audio_request?(request : AudioStreamAllocateRequest) : Bool
        capabilities = @microphone_capabilities || return false
        return false unless request.stream_usage.in?(StreamUsage::Recording, StreamUsage::Analysis, StreamUsage::LiveView)
        return false unless @supported_stream_usages.includes?(request.stream_usage)
        return false unless capabilities.supported_codecs.includes?(request.audio_codec)
        return false unless request.channel_count.in?(MIN_CHANNEL_COUNT..MAX_CHANNEL_COUNT)
        return false if request.channel_count > capabilities.max_number_of_channels
        return false unless capabilities.supported_sample_rates.includes?(request.sample_rate)
        return false unless capabilities.supported_bit_depths.includes?(request.bit_depth)
        return false if request.bit_rate.zero?
        true
      end

      private def valid_video_request?(request : VideoStreamAllocateRequest) : Bool
        sensor = @video_sensor_params || return false
        viewport = @min_viewport_resolution || return false
        return false unless request.stream_usage.in?(StreamUsage::Recording, StreamUsage::Analysis, StreamUsage::LiveView)
        return false unless @supported_stream_usages.includes?(request.stream_usage)
        return false unless @rate_distortion_trade_off_points.any?(&.codec.==(request.video_codec))
        return false if request.min_frame_rate.zero? || request.min_frame_rate > request.max_frame_rate
        return false if request.max_frame_rate > sensor.max_fps
        return false if request.min_resolution.width < viewport.width || request.min_resolution.height < viewport.height
        return false if request.min_resolution.width > request.max_resolution.width || request.min_resolution.height > request.max_resolution.height
        return false if request.max_resolution.width > sensor.sensor_width || request.max_resolution.height > sensor.sensor_height
        return false if request.min_bit_rate.zero? || request.min_bit_rate > request.max_bit_rate
        return false if request.key_frame_interval > MAX_KEY_FRAME_INTERVAL
        true
      end

      private def valid_viewport?(value : Viewport) : Bool
        sensor = @video_sensor_params || return false
        minimum = @min_viewport_resolution || return false
        return false if value.x2 <= value.x1 || value.y2 <= value.y1
        return false if value.x2 > sensor.sensor_width || value.y2 > sensor.sensor_height
        return false if (value.x2 - value.x1) < minimum.width || (value.y2 - value.y1) < minimum.height
        true
      end

      private def used_bandwidth : UInt64
        @allocated_audio_streams.sum(0_u64, &.bit_rate.to_u64) +
          @allocated_video_streams.sum(0_u64, &.max_bit_rate.to_u64)
      end

      private def used_pixel_rate : UInt64
        @allocated_video_streams.sum(0_u64) do |stream|
          stream.max_resolution.width.to_u64 * stream.max_resolution.height * stream.max_frame_rate
        end + @allocated_snapshot_streams.sum(0_u64) do |stream|
          stream.encoded_pixels? ? stream.max_resolution.width.to_u64 * stream.max_resolution.height * stream.frame_rate : 0_u64
        end
      end

      private def used_encoders : Int32
        @allocated_video_streams.size + @allocated_snapshot_streams.count(&.hardware_encoder?)
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

      private def next_available_video_id : UInt16?
        candidate = @next_video_stream_id
        loop do
          return candidate unless @allocated_video_streams.any?(&.video_stream_id.==(candidate))
          candidate = advance_audio_id(candidate)
          return if candidate == @next_video_stream_id
        end
      end

      private def next_available_snapshot_id : UInt16?
        candidate = @next_snapshot_stream_id
        loop do
          return candidate unless @allocated_snapshot_streams.any?(&.snapshot_stream_id.==(candidate))
          candidate = advance_audio_id(candidate)
          return if candidate == @next_snapshot_stream_id
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
        document["next_video_stream_id"] = @next_video_stream_id.to_i64
        document["next_snapshot_stream_id"] = @next_snapshot_stream_id.to_i64
        document["allocated_snapshot_streams"] = Storage::Record.encode(@allocated_snapshot_streams) if @feature_map.snapshot?
        document["viewport"] = Storage::Record.encode(@viewport) if @feature_map.video?
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
        if encoded_id = document["next_video_stream_id"]?
          id = Storage::Record.decode(encoded_id, UInt16, "next_video_stream_id")
          @next_video_stream_id = id if id <= MAX_STREAM_ID
        end
        if @feature_map.snapshot?
          if encoded_id = document["next_snapshot_stream_id"]?
            id = Storage::Record.decode(encoded_id, UInt16, "next_snapshot_stream_id")
            @next_snapshot_stream_id = id if id <= MAX_STREAM_ID
          end
          if encoded_streams = document["allocated_snapshot_streams"]?
            streams = Storage::Record.decode(encoded_streams, Array(SnapshotStream), "allocated_snapshot_streams")
            @allocated_snapshot_streams = streams if streams.all? { |stream| valid_restored_snapshot?(stream) } &&
                                                     streams.map(&.snapshot_stream_id).to_set.size == streams.size
          end
        end
        if @feature_map.video? && (encoded_viewport = document["viewport"]?)
          value = Storage::Record.decode(encoded_viewport, Viewport, "viewport")
          @viewport = value if valid_viewport?(value)
        end
      end

      private def valid_restored_snapshot?(stream : SnapshotStream) : Bool
        return false if stream.snapshot_stream_id > MAX_STREAM_ID || stream.reference_count.zero?
        return false if @feature_map.watermark? == stream.watermark_enabled.nil?
        return false if @feature_map.osd? == stream.osd_enabled.nil?
        request = SnapshotStreamAllocateRequest.new(stream.image_codec, stream.frame_rate,
          stream.min_resolution, stream.max_resolution, stream.quality, stream.watermark_enabled, stream.osd_enabled)
        capability = matching_snapshot_capability(request) || return false
        stream.encoded_pixels? == capability.requires_encoded_pixels? &&
          stream.hardware_encoder? == (capability.requires_hardware_encoder || false)
      end

      private def after_restore_state : Nil
        @microphone_volume_level = @microphone_min_level unless @microphone_volume_level.in?(@microphone_min_level..@microphone_max_level)
        @allocated_audio_streams.clear
        @allocated_video_streams.clear
      end

      protected def validate_feature_map_change(value : Feature) : Nil
        raise ArgumentError.new("Camera AV feature profile is fixed after construction") unless value == @feature_map
      end
    end
  end
end
