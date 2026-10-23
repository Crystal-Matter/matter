require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Channel server (0x0504, revision 2).
    class Channel < Base
      cluster 0x0504, revision: 2

      feature :channel_list, bit: 0
      feature :lineup_info, bit: 1
      feature :electronic_guide, bit: 2
      feature :record_program, bit: 3

      MAX_PAGE_TOKEN_BYTES = 8192

      enum ChannelType : UInt8
        Satellite   = 0
        Cable       = 1
        Terrestrial = 2
        OTT         = 3
      end

      enum LineupInfoType : UInt8
        MSO = 0
      end

      enum Status : UInt8
        Success         = 0
        MultipleMatches = 1
        NoMatches       = 2
      end

      @[Flags]
      enum RecordingFlag : UInt8
        Scheduled    = 1 << 0
        RecordSeries = 1 << 1
        Recorded     = 1 << 2
      end

      struct ChannelInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property major_number : UInt16

        @[TLV::Field(tag: 1)]
        property minor_number : UInt16

        @[TLV::Field(tag: 2, optional: true)]
        property name : String?

        @[TLV::Field(tag: 3, optional: true)]
        property call_sign : String?

        @[TLV::Field(tag: 4, optional: true)]
        property affiliate_call_sign : String?

        @[TLV::Field(tag: 5, optional: true)]
        property identifier : String?

        @[TLV::Field(tag: 6, optional: true)]
        property type : ChannelType?

        def initialize(@major_number : UInt16, @minor_number : UInt16, @name : String? = nil, @call_sign : String? = nil, @affiliate_call_sign : String? = nil, @identifier : String? = nil, @type : ChannelType? = nil)
        end
      end

      struct LineupInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property operator_name : String

        @[TLV::Field(tag: 1, optional: true)]
        property lineup_name : String?

        @[TLV::Field(tag: 2, optional: true)]
        property postal_code : String?

        @[TLV::Field(tag: 3)]
        property lineup_info_type : LineupInfoType

        def initialize(@operator_name : String, @lineup_info_type : LineupInfoType,
                       @lineup_name : String? = nil, @postal_code : String? = nil)
        end
      end

      struct PageToken
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property limit : UInt16?

        @[TLV::Field(tag: 1, optional: true)]
        property after : String?

        @[TLV::Field(tag: 2, optional: true)]
        property before : String?

        def initialize(@limit : UInt16? = nil, @after : String? = nil, @before : String? = nil)
        end
      end

      struct ChannelPaging
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property previous_token : PageToken?

        @[TLV::Field(tag: 1, optional: true)]
        property next_token : PageToken?

        def initialize(@previous_token : PageToken? = nil, @next_token : PageToken? = nil)
        end
      end

      struct AdditionalInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property name : String

        @[TLV::Field(tag: 1)]
        property value : String

        def initialize(@name : String, @value : String)
        end
      end

      struct ProgramCast
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property name : String

        @[TLV::Field(tag: 1)]
        property role : String

        def initialize(@name : String, @role : String)
        end
      end

      struct ProgramCategory
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property category : String

        @[TLV::Field(tag: 1, optional: true)]
        property sub_category : String?

        def initialize(@category : String, @sub_category : String? = nil)
        end
      end

      struct SeriesInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property season : String

        @[TLV::Field(tag: 1)]
        property episode : String

        def initialize(@season : String, @episode : String)
        end
      end

      struct Program
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property identifier : String

        @[TLV::Field(tag: 1)]
        property channel : ChannelInfo

        @[TLV::Field(tag: 2)]
        property start_time : UInt32

        @[TLV::Field(tag: 3)]
        property end_time : UInt32

        @[TLV::Field(tag: 4)]
        property title : String

        @[TLV::Field(tag: 5, optional: true)]
        property subtitle : String?

        @[TLV::Field(tag: 6, optional: true)]
        property description : String?

        @[TLV::Field(tag: 7, optional: true)]
        property audio_languages : Array(String)?

        @[TLV::Field(tag: 8, optional: true)]
        property ratings : Array(String)?

        @[TLV::Field(tag: 9, optional: true)]
        property thumbnail_url : String?

        @[TLV::Field(tag: 10, optional: true)]
        property poster_art_url : String?

        @[TLV::Field(tag: 11, optional: true)]
        property dvbi_url : String?

        @[TLV::Field(tag: 12, optional: true)]
        property release_date : String?

        @[TLV::Field(tag: 13, optional: true)]
        property parental_guidance_text : String?

        @[TLV::Field(tag: 14, optional: true)]
        property recording_flag : RecordingFlag?

        @[TLV::Field(tag: 15, optional: true)]
        property series_info : SeriesInfo?

        @[TLV::Field(tag: 16, optional: true)]
        property category_list : Array(ProgramCategory)?

        @[TLV::Field(tag: 17, optional: true)]
        property cast_list : Array(ProgramCast)?

        @[TLV::Field(tag: 18, optional: true)]
        property external_id_list : Array(AdditionalInfo)?

        def initialize(@identifier : String, @channel : ChannelInfo, @start_time : UInt32, @end_time : UInt32, @title : String, @subtitle : String? = nil, @description : String? = nil, @audio_languages : Array(String)? = nil, @ratings : Array(String)? = nil, @thumbnail_url : String? = nil, @poster_art_url : String? = nil, @dvbi_url : String? = nil, @release_date : String? = nil, @parental_guidance_text : String? = nil, @recording_flag : RecordingFlag? = nil, @series_info : SeriesInfo? = nil, @category_list : Array(ProgramCategory)? = nil, @cast_list : Array(ProgramCast)? = nil, @external_id_list : Array(AdditionalInfo)? = nil)
        end
      end

      struct ChangeChannelRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property match : String

        def initialize(@match : String)
        end
      end

      struct ChangeChannelResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property status : Status

        @[TLV::Field(tag: 1, optional: true)]
        property data : String?

        def initialize(@status : Status, @data : String? = nil)
        end
      end

      struct ChangeChannelByNumberRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property major_number : UInt16

        @[TLV::Field(tag: 1)]
        property minor_number : UInt16

        def initialize(@major_number : UInt16, @minor_number : UInt16)
        end
      end

      struct SkipChannelRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property count : Int16

        def initialize(@count : Int16)
        end
      end

      struct GetProgramGuideRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property start_time : UInt32

        @[TLV::Field(tag: 1)]
        property end_time : UInt32

        @[TLV::Field(tag: 2, optional: true)]
        property channel_list : Array(ChannelInfo)?

        @[TLV::Field(tag: 3, optional: true)]
        property page_token : PageToken?

        @[TLV::Field(tag: 5, optional: true)]
        property recording_flag : RecordingFlag?

        @[TLV::Field(tag: 6, optional: true)]
        property external_id_list : Array(AdditionalInfo)?

        @[TLV::Field(tag: 7, optional: true)]
        property data : Bytes?

        def initialize(@start_time : UInt32, @end_time : UInt32, @channel_list : Array(ChannelInfo)? = nil, @page_token : PageToken? = nil, @recording_flag : RecordingFlag? = nil, @external_id_list : Array(AdditionalInfo)? = nil, @data : Bytes? = nil)
        end
      end

      struct ProgramGuideResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property paging : ChannelPaging

        @[TLV::Field(tag: 1)]
        property program_list : Array(Program)

        def initialize(@paging : ChannelPaging, @program_list : Array(Program))
        end
      end

      struct RecordProgramRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property program_identifier : String

        @[TLV::Field(tag: 1)]
        property? should_record_series : Bool

        @[TLV::Field(tag: 2, optional: true)]
        property external_id_list : Array(AdditionalInfo)?

        @[TLV::Field(tag: 3, optional: true)]
        property data : Bytes?

        def initialize(@program_identifier : String, @should_record_series : Bool, @external_id_list : Array(AdditionalInfo)? = nil, @data : Bytes? = nil)
        end
      end

      # CL and LI are independent. Numeric tuning and skip are mandatory even
      # for devices that obtain their channels from an external lineup source.
      attribute 0x0000, :channel_list, Array(ChannelInfo), default: [] of ChannelInfo,
        requires: :channel_list, copy_on_assign: true
      attribute 0x0001, :lineup, LineupInfo, nullable: true, requires: :lineup_info
      attribute 0x0002, :current_channel, ChannelInfo, nullable: true, optional: true

      command 0x00, :change_channel, request: ChangeChannelRequest,
        response: ChangeChannelResponse, response_id: 0x01,
        requires: [:channel_list, :lineup_info], access: :operate
      command 0x02, :change_channel_by_number, request: ChangeChannelByNumberRequest,
        access: :operate
      command 0x03, :skip_channel, request: SkipChannelRequest, access: :operate
      command 0x04, :get_program_guide, request: GetProgramGuideRequest,
        response: ProgramGuideResponse, response_id: 0x05,
        requires: :electronic_guide, access: :operate
      command 0x06, :record_program, request: RecordProgramRequest,
        requires: {record_program: true, electronic_guide: true}, access: :operate
      command 0x07, :cancel_record_program, request: RecordProgramRequest,
        requires: {record_program: true, electronic_guide: true}, access: :operate

      @on_select : Proc(ChannelInfo, Bool)?
      @on_program_guide : Proc(GetProgramGuideRequest, ProgramGuideResponse)?
      @on_record : Proc(RecordProgramRequest, Bool, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     channels : Array(ChannelInfo) = [] of ChannelInfo,
                     lineup : LineupInfo? = nil)
        if lineup && !@feature_map.lineup_info?
          raise ArgumentError.new("Lineup requires LineupInfo feature")
        end
        @channels = [] of ChannelInfo
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        update_channels(channels)
        self.lineup = lineup if @feature_map.lineup_info?
      end

      # The host can replace an external lineup without exposing ChannelList.
      # The tuning catalog and advertised attribute must stay in sync.
      def update_channels(channels : Array(ChannelInfo)) : Nil
        if @feature_map.channel_list?
          self.channel_list = channels
        else
          current = @current_channel
          install_channels!(channels)
          reconcile_current_channel!(current)
        end
      end

      def channel_list=(channels : Array(ChannelInfo)) : Nil
        current = @current_channel
        install_channels!(channels)
        previous_def(@channels.dup)
        reconcile_current_channel!(current)
      end

      private def install_channels!(channels : Array(ChannelInfo)) : Nil
        numbers = channels.map { |channel| {channel.major_number, channel.minor_number} }
        raise ArgumentError.new("duplicate channel numbers") unless numbers.uniq.size == numbers.size
        @channels = channels.dup
      end

      private def reconcile_current_channel!(current : ChannelInfo?) : Nil
        if current
          self.current_channel = @channels.find do |channel|
            channel.major_number == current.major_number && channel.minor_number == current.minor_number
          end
        end
      end

      def channel_list : Array(ChannelInfo)
        @channel_list.dup
      end

      def on_select(&block : ChannelInfo -> Bool) : Nil
        @on_select = block
      end

      def on_program_guide(&block : GetProgramGuideRequest -> ProgramGuideResponse) : Nil
        @on_program_guide = block
      end

      def on_record(&block : RecordProgramRequest, Bool -> InteractionModel::Status) : Nil
        @on_record = block
      end

      def change_channel(request : ChangeChannelRequest) : ChangeChannelResponse
        match = request.match.downcase
        # The spec gives these fields a strict match priority. A unique
        # Identifier wins even when a different channel has the same Name.
        matching = [] of ChannelInfo
        (0..4).each do |priority|
          matching = @channels.select do |channel|
            value = case priority
                    when 0 then channel.identifier
                    when 1 then channel.affiliate_call_sign
                    when 2 then channel.call_sign
                    when 3 then channel.name
                    else        "#{channel.major_number}.#{channel.minor_number}"
                    end
            value && value.downcase == match
          end
          break unless matching.empty?
        end
        case matching.size
        when 0 then ChangeChannelResponse.new(Status::NoMatches)
        when 1
          return ChangeChannelResponse.new(Status::NoMatches) unless select_channel(matching.first)
          ChangeChannelResponse.new(Status::Success)
        else
          ChangeChannelResponse.new(Status::MultipleMatches)
        end
      end

      def change_channel_by_number(request : ChangeChannelByNumberRequest) : InteractionModel::Status
        channel = @channels.find do |candidate|
          candidate.major_number == request.major_number && candidate.minor_number == request.minor_number
        end
        return InteractionModel::Status.not_found unless channel
        select_channel(channel) ? InteractionModel::Status.success : InteractionModel::Status.invalid_in_state
      end

      def skip_channel(request : SkipChannelRequest) : InteractionModel::Status
        return InteractionModel::Status.not_found if @channels.empty?
        current = @channels.index(@current_channel) || 0
        index = (current + request.count) % @channels.size
        select_channel(@channels[index]) ? InteractionModel::Status.success : InteractionModel::Status.invalid_in_state
      end

      def get_program_guide(request : GetProgramGuideRequest) : ProgramGuideResponse | InteractionModel::Status
        return InteractionModel::Status.invalid_action if request.end_time <= request.start_time
        return InteractionModel::Status.constraint_error unless request_limits_valid?(request)
        handler = @on_program_guide
        return InteractionModel::Status.invalid_in_state unless handler
        response = handler.call(request)
        return InteractionModel::Status.failure unless valid_page_token?(response.paging.previous_token) &&
                                                       valid_page_token?(response.paging.next_token)
        return InteractionModel::Status.failure unless response.program_list.all? { |program| valid_program?(program) }
        response
      end

      def record_program(request : RecordProgramRequest) : InteractionModel::Status
        record(request, false)
      end

      def cancel_record_program(request : RecordProgramRequest) : InteractionModel::Status
        record(request, true)
      end

      private def record(request : RecordProgramRequest, cancel : Bool) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless record_request_valid?(request)
        handler = @on_record
        return InteractionModel::Status.invalid_in_state unless handler
        handler.call(request, cancel)
      end

      private def select_channel(channel : ChannelInfo) : Bool
        handler = @on_select
        return false unless handler && handler.call(channel)
        self.current_channel = channel
        true
      end

      private def record_request_valid?(request : RecordProgramRequest) : Bool
        return false if request.program_identifier.bytesize > 255
        return false unless valid_external_ids?(request.external_id_list)
        return false if (data = request.data) && data.size > 8092
        true
      end

      private def request_limits_valid?(request : GetProgramGuideRequest) : Bool
        return false if (channels = request.channel_list) && channels.size > 255
        return false unless valid_external_ids?(request.external_id_list)
        return false if (data = request.data) && data.size > 8092
        return false unless valid_page_token?(request.page_token)
        true
      end

      private def valid_page_token?(token : PageToken?) : Bool
        return true unless token
        return false if (after = token.after) && after.bytesize > MAX_PAGE_TOKEN_BYTES
        return false if (before = token.before) && before.bytesize > MAX_PAGE_TOKEN_BYTES
        true
      end

      private def valid_external_ids?(ids : Array(AdditionalInfo)?) : Bool
        !ids || (ids.size <= 255 && ids.all? { |id| id.name.bytesize <= 256 && id.value.bytesize <= 8192 })
      end

      private def valid_program?(program : Program) : Bool
        return false if program.identifier.bytesize > 255 || program.title.bytesize > 255
        return false if program.start_time >= program.end_time
        return false if @feature_map.record_program? && !program.recording_flag
        return false unless {program.subtitle, program.parental_guidance_text}.all? { |value| !value || value.bytesize <= 255 }
        return false unless {program.description, program.thumbnail_url, program.poster_art_url,
                             program.dvbi_url}.all? { |value| !value || value.bytesize <= 8192 }
        return false if (date = program.release_date) && date.bytesize > 30
        if languages = program.audio_languages
          return false if languages.size > 10 || languages.any? { |language| language.bytesize > 50 }
        end
        return false if (ratings = program.ratings) && ratings.size > 255
        if categories = program.category_list
          return false if categories.size > 255 || categories.any? do |item|
                            item.category.bytesize > 256 || ((sub = item.sub_category) && sub.bytesize > 256)
                          end
        end
        if cast = program.cast_list
          return false if cast.size > 255 || cast.any? { |item| item.name.bytesize > 256 || item.role.bytesize > 256 }
        end
        return false unless valid_external_ids?(program.external_id_list)
        if series = program.series_info
          return false if series.season.bytesize > 256 || series.episode.bytesize > 256
        end
        true
      end
    end
  end
end
