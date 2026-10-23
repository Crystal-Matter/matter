require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Content Launcher server (0x050A). A media application supplies
    # the actual search and playback decisions through host callbacks.
    class ContentLauncher < Base
      cluster 0x050A, revision: 2

      feature :content_search, bit: 0
      feature :url_playback, bit: 1
      feature :advanced_seek, bit: 2
      feature :text_tracks, bit: 3
      feature :audio_tracks, bit: 4

      MAX_ACCEPT_HEADERS       =      100
      MAX_ACCEPT_HEADER_BYTES  =     1024
      MAX_CONTENT_URL_BYTES    =     8192
      MAX_DISPLAY_BYTES        =      256
      MAX_PARAMETER_BYTES      =     1024
      MAX_LANGUAGE_CODE_BYTES  =       32
      SUPPORTED_PROTOCOLS_MASK = 0x03_u32
      COLOR_PATTERN            = /\A#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?\z/

      enum MetricType : UInt8
        Pixels     = 0
        Percentage = 1
      end

      enum ParameterType : UInt8
        Actor      =  0
        Channel    =  1
        Character  =  2
        Director   =  3
        Event      =  4
        Franchise  =  5
        Genre      =  6
        League     =  7
        Popularity =  8
        Provider   =  9
        Sport      = 10
        SportsTeam = 11
        Type       = 12
        Video      = 13
        Season     = 14
        Episode    = 15
        Any        = 16
      end

      enum Status : UInt8
        Success                = 0
        UrlNotAvailable        = 1
        AuthFailed             = 2
        TextTrackNotAvailable  = 3
        AudioTrackNotAvailable = 4
      end

      # Shared with the Media Playback TrackPreference schema in Matter 1.6.
      enum Characteristic : UInt8
        ForcedSubtitles              =  0
        DescribesVideo               =  1
        EasyToRead                   =  2
        FrameBased                   =  3
        MainProgram                  =  4
        OriginalContent              =  5
        VoiceOverTranslation         =  6
        Caption                      =  7
        Subtitle                     =  8
        Alternate                    =  9
        Supplementary                = 10
        Commentary                   = 11
        DubbedTranslation            = 12
        Description                  = 13
        Metadata                     = 14
        EnhancedAudioIntelligibility = 15
        Emergency                    = 16
        Karaoke                      = 17
      end

      struct AdditionalInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter name : String
        @[TLV::Field(tag: 1)]
        getter value : String

        def initialize(@name : String, @value : String)
        end
      end

      struct Dimension
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter width : Float64
        @[TLV::Field(tag: 1)]
        getter height : Float64
        @[TLV::Field(tag: 2)]
        getter metric : MetricType

        def initialize(@width : Float64, @height : Float64, @metric : MetricType)
        end
      end

      struct StyleInformation
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter image_url : String?
        @[TLV::Field(tag: 1, optional: true)]
        getter color : String?
        @[TLV::Field(tag: 2, optional: true)]
        getter size : Dimension?

        def initialize(@image_url : String? = nil, @color : String? = nil,
                       @size : Dimension? = nil)
        end
      end

      struct BrandingInformation
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter provider_name : String
        @[TLV::Field(tag: 1, optional: true)]
        getter background : StyleInformation?
        @[TLV::Field(tag: 2, optional: true)]
        getter logo : StyleInformation?
        @[TLV::Field(tag: 3, optional: true)]
        getter progress_bar : StyleInformation?
        @[TLV::Field(tag: 4, optional: true)]
        getter splash : StyleInformation?
        @[TLV::Field(tag: 5, optional: true)]
        getter water_mark : StyleInformation?

        def initialize(@provider_name : String, @background : StyleInformation? = nil,
                       @logo : StyleInformation? = nil, @progress_bar : StyleInformation? = nil,
                       @splash : StyleInformation? = nil, @water_mark : StyleInformation? = nil)
        end
      end

      struct Parameter
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter type : ParameterType
        @[TLV::Field(tag: 1)]
        getter value : String
        @[TLV::Field(tag: 2, optional: true)]
        getter external_id_list : Array(AdditionalInfo)?

        def initialize(@type : ParameterType, @value : String,
                       @external_id_list : Array(AdditionalInfo)? = nil)
        end
      end

      struct ContentSearch
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter parameter_list : Array(Parameter)

        def initialize(@parameter_list : Array(Parameter))
        end
      end

      struct TrackPreference
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter language_code : String
        @[TLV::Field(tag: 1, optional: true)]
        getter characteristics : Array(Characteristic)?
        @[TLV::Field(tag: 2, optional: true)]
        getter audio_output_index : UInt8?

        def initialize(@language_code : String,
                       @characteristics : Array(Characteristic)? = nil,
                       @audio_output_index : UInt8? = nil)
        end
      end

      struct PlaybackPreferences
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter playback_position : UInt64?
        @[TLV::Field(tag: 1, optional: true)]
        getter text_track : TrackPreference?
        @[TLV::Field(tag: 2, optional: true)]
        getter audio_tracks : Array(TrackPreference)?

        def initialize(@playback_position : UInt64? = nil,
                       @text_track : TrackPreference? = nil,
                       @audio_tracks : Array(TrackPreference)? = nil)
        end
      end

      struct LaunchContentRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter search : ContentSearch
        @[TLV::Field(tag: 1)]
        getter? auto_play : Bool
        @[TLV::Field(tag: 2, optional: true)]
        getter data : String?
        @[TLV::Field(tag: 3, optional: true)]
        getter playback_preferences : PlaybackPreferences?
        @[TLV::Field(tag: 4, optional: true)]
        getter use_current_context : Bool?

        def initialize(@search : ContentSearch, @auto_play : Bool,
                       @data : String? = nil,
                       @playback_preferences : PlaybackPreferences? = nil,
                       @use_current_context : Bool? = nil)
        end
      end

      struct LaunchUrlRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter content_url : String
        @[TLV::Field(tag: 1, optional: true)]
        getter display_string : String?
        @[TLV::Field(tag: 2, optional: true)]
        getter branding_information : BrandingInformation?
        @[TLV::Field(tag: 3, optional: true)]
        getter playback_preferences : PlaybackPreferences?

        def initialize(@content_url : String, @display_string : String? = nil,
                       @branding_information : BrandingInformation? = nil,
                       @playback_preferences : PlaybackPreferences? = nil)
        end
      end

      struct LauncherResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : Status
        @[TLV::Field(tag: 1, optional: true)]
        getter data : String?

        def initialize(@status : Status, @data : String? = nil)
        end
      end

      attribute 0x0000, :accept_header, Array(String),
        default: [] of String, persist: true, fixed: true, requires: :url_playback
      attribute 0x0001, :supported_streaming_protocols, UInt32,
        default: 0_u32, persist: true, fixed: true, requires: :url_playback

      command 0x00, :launch_content, request: LaunchContentRequest,
        response: LauncherResponse, response_id: 0x02,
        access: :operate, requires: :content_search
      command 0x01, :launch_url, request: LaunchUrlRequest,
        response: LauncherResponse, response_id: 0x02,
        access: :operate, requires: :url_playback

      @launch_content_callback : Proc(LaunchContentRequest, LauncherResponse)?
      @launch_url_callback : Proc(LaunchUrlRequest, LauncherResponse)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::ContentSearch,
                     @accept_header : Array(String) = [] of String,
                     @supported_streaming_protocols : UInt32 = 0_u32)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map.content_search? || @feature_map.url_playback?
          raise ArgumentError.new("Content Launcher requires ContentSearch or URLPlayback")
        end
        if !@feature_map.url_playback? && (!@accept_header.empty? || @supported_streaming_protocols != 0_u32)
          raise ArgumentError.new("URL attributes require URLPlayback")
        end
        if @accept_header.size > MAX_ACCEPT_HEADERS ||
           @accept_header.any? { |header| header.bytesize > MAX_ACCEPT_HEADER_BYTES } ||
           (@supported_streaming_protocols & ~SUPPORTED_PROTOCOLS_MASK) != 0_u32
          raise ArgumentError.new("URL playback configuration exceeds Matter 1.6 limits")
        end
        @accept_header = @accept_header.dup
      end

      def on_launch_content(&block : LaunchContentRequest -> LauncherResponse) : Nil
        @launch_content_callback = block
      end

      def on_launch_url(&block : LaunchUrlRequest -> LauncherResponse) : Nil
        @launch_url_callback = block
      end

      def launch_content(request : LaunchContentRequest) : LauncherResponse | InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_search?(request.search)
        return InteractionModel::Status.constraint_error unless valid_preferences?(request.playback_preferences)
        return InteractionModel::Status.invalid_in_state unless callback = @launch_content_callback
        callback.call(request)
      end

      def launch_url(request : LaunchUrlRequest) : LauncherResponse | InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.content_url.bytesize > MAX_CONTENT_URL_BYTES
        if display = request.display_string
          return InteractionModel::Status.constraint_error if display.bytesize > MAX_DISPLAY_BYTES
        end
        return InteractionModel::Status.constraint_error unless valid_branding?(request.branding_information)
        return InteractionModel::Status.constraint_error unless valid_preferences?(request.playback_preferences)
        return InteractionModel::Status.invalid_in_state unless callback = @launch_url_callback
        callback.call(request)
      end

      private def valid_search?(search : ContentSearch) : Bool
        search.parameter_list.all? do |parameter|
          parameter.value.bytesize <= MAX_PARAMETER_BYTES &&
            (parameter.external_id_list || [] of AdditionalInfo).all? do |info|
              info.name.bytesize <= MAX_DISPLAY_BYTES && info.value.bytesize <= MAX_CONTENT_URL_BYTES
            end
        end
      end

      private def valid_preferences?(preferences : PlaybackPreferences?) : Bool
        return true unless preferences
        return false if preferences.playback_position && !@feature_map.advanced_seek?
        if track = preferences.text_track
          return false unless @feature_map.text_tracks? && valid_track?(track)
        end
        if tracks = preferences.audio_tracks
          return false unless @feature_map.audio_tracks? && tracks.all? { |audio_track| valid_track?(audio_track) }
        end
        true
      end

      private def valid_track?(track : TrackPreference) : Bool
        track.language_code.bytesize <= MAX_LANGUAGE_CODE_BYTES &&
          (!track.audio_output_index || @feature_map.audio_tracks?)
      end

      private def valid_branding?(branding : BrandingInformation?) : Bool
        return true unless branding
        return false if branding.provider_name.bytesize > MAX_DISPLAY_BYTES
        [branding.background, branding.logo, branding.progress_bar, branding.splash, branding.water_mark].all? do |style|
          !style || valid_style?(style)
        end
      end

      private def valid_style?(style : StyleInformation) : Bool
        return false if style.image_url.try { |url| url.bytesize > MAX_CONTENT_URL_BYTES }
        # The XML allows #RRGGBB or #RRGGBBAA.
        return false if style.color.try { |color| !color.matches?(COLOR_PATTERN) }
        true
      end
    end
  end
end
