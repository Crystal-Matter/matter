require "openssl/pkcs5"
require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Content Control server (0x050F, provisional revision 1).
    # A media host must apply the configured policy to actual playback.
    class ContentControl < Base
      cluster 0x050F, revision: 1

      feature :screen_time, bit: 0
      feature :pin_management, bit: 1
      feature :block_unrated, bit: 2
      feature :on_demand_content_rating, bit: 3
      feature :scheduled_content_rating, bit: 4
      feature :block_channels, bit: 5
      feature :block_applications, bit: 6
      feature :block_content_time_window, bit: 7

      MAX_RATING_BYTES             =  8
      MAX_RATING_DESCRIPTION_BYTES = 64
      PIN_LENGTH                   =  6
      PIN_RANGE                    = 0...1_000_000
      PIN_SALT_BYTES               =      16
      PIN_VERIFIER_BYTES           =      32
      PIN_DERIVATION_ITERATIONS    =  65_536
      MAX_TIME_WINDOWS             =       7
      MAX_HOUR                     =   23_u8
      MAX_MINUTE                   =   59_u8
      DAY_OF_WEEK_MASK             = 0x7F_u8
      MINUTES_PER_HOUR             =      60
      PERSISTED_PIN_SALT_KEY       = "pin_salt"
      PERSISTED_PIN_VERIFIER_KEY   = "pin_verifier"
      SUPPORTED_FEATURES           = 0xFE_u32

      enum StatusCode : UInt8
        InvalidPINCode            = 0x02
        InvalidRating             = 0x03
        InvalidChannel            = 0x04
        ChannelAlreadyExist       = 0x05
        ChannelNotExist           = 0x06
        UnidentifiableApplication = 0x07
        ApplicationAlreadyExist   = 0x08
        ApplicationNotExist       = 0x09
        TimeWindowAlreadyExist    = 0x0A
        TimeWindowNotExist        = 0x0B
      end

      struct RatingName
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter rating_name : String

        @[TLV::Field(tag: 1, optional: true)]
        getter rating_name_desc : String?

        def initialize(@rating_name : String, @rating_name_desc : String? = nil)
        end
      end

      struct AppInfo
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter catalog_vendor_id : UInt16

        @[TLV::Field(tag: 1)]
        getter application_id : String

        def initialize(@catalog_vendor_id : UInt16, @application_id : String)
        end
      end

      struct BlockChannel
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: false)]
        getter block_channel_index : UInt16?

        @[TLV::Field(tag: 1)]
        getter major_number : UInt16

        @[TLV::Field(tag: 2)]
        getter minor_number : UInt16

        @[TLV::Field(tag: 3, optional: true)]
        getter identifier : String?

        def initialize(@block_channel_index : UInt16?, @major_number : UInt16,
                       @minor_number : UInt16, @identifier : String? = nil)
        end
      end

      struct TimePeriod
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter start_hour : UInt8
        @[TLV::Field(tag: 1)]
        getter start_minute : UInt8
        @[TLV::Field(tag: 2)]
        getter end_hour : UInt8
        @[TLV::Field(tag: 3)]
        getter end_minute : UInt8

        def initialize(@start_hour : UInt8, @start_minute : UInt8, @end_hour : UInt8, @end_minute : UInt8)
        end
      end

      struct TimeWindow
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: false)]
        getter time_window_index : UInt16?
        @[TLV::Field(tag: 1)]
        getter day_of_week : UInt8
        @[TLV::Field(tag: 2)]
        getter time_period : Array(TimePeriod)

        def initialize(@time_window_index : UInt16?, @day_of_week : UInt8, periods : Array(TimePeriod))
          @time_period = periods.dup
        end

        def time_period : Array(TimePeriod)
          @time_period.dup
        end
      end

      struct SetTimeWindowRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter time_window : TimeWindow

        def initialize(@time_window : TimeWindow)
        end
      end

      struct RemoveTimeWindowsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter time_window_indexes : Array(UInt16)

        def initialize(@time_window_indexes : Array(UInt16))
        end
      end

      struct EmptyEvent
        include TLV::Serializable

        def initialize
        end
      end

      struct SetRatingRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter rating : String

        def initialize(@rating : String)
        end
      end

      struct UpdatePinRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter old_pin : String

        @[TLV::Field(tag: 1)]
        getter new_pin : String

        def initialize(@old_pin : String, @new_pin : String)
        end
      end

      struct ResetPinResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter pin_code : String

        def initialize(@pin_code : String)
        end
      end

      struct ApplicationsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter applications : Array(AppInfo)

        def initialize(@applications : Array(AppInfo))
        end
      end

      struct ChannelsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter channels : Array(BlockChannel)

        def initialize(@channels : Array(BlockChannel))
        end
      end

      struct ChannelIndexesRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter channel_indexes : Array(UInt16)

        def initialize(@channel_indexes : Array(UInt16))
        end
      end

      attribute 0x0000, :enabled, Bool, default: false, persist: true,
        on_change: :policy_changed
      attribute 0x0001, :on_demand_ratings, Array(RatingName),
        default: [] of RatingName, persist: true, requires: :on_demand_content_rating,
        copy_on_assign: true, on_change: :policy_changed
      attribute 0x0002, :on_demand_rating_threshold, String,
        default: "", persist: true, requires: :on_demand_content_rating,
        on_change: :policy_changed
      attribute 0x0003, :scheduled_content_ratings, Array(RatingName),
        default: [] of RatingName, persist: true, requires: :scheduled_content_rating,
        copy_on_assign: true, on_change: :policy_changed
      attribute 0x0004, :scheduled_content_rating_threshold, String,
        default: "", persist: true, requires: :scheduled_content_rating,
        on_change: :policy_changed
      attribute 0x0007, :block_unrated, Bool, default: false, persist: true,
        requires: :block_unrated, on_change: :policy_changed
      attribute 0x0008, :block_channel_list, Array(BlockChannel),
        default: [] of BlockChannel, persist: true, requires: :block_channels,
        copy_on_assign: true, on_change: :policy_changed
      attribute 0x0009, :block_application_list, Array(AppInfo),
        default: [] of AppInfo, persist: true, requires: :block_applications,
        copy_on_assign: true, on_change: :policy_changed
      attribute 0x000A, :block_content_time_window, Array(TimeWindow),
        default: [] of TimeWindow, persist: true, requires: :block_content_time_window,
        copy_on_assign: true, on_change: :policy_changed

      command 0x00, :update_pin, request: UpdatePinRequest,
        access: :manage, timed: true, requires: :pin_management
      command 0x01, :reset_pin, response: ResetPinResponse,
        response_id: 0x02, access: :administer, timed: true,
        requires: :pin_management
      command 0x03, :enable, access: :manage, timed: true
      command 0x04, :disable, access: :manage, timed: true
      command 0x07, :block_unrated_content, access: :manage,
        requires: :block_unrated
      command 0x08, :unblock_unrated_content, access: :manage,
        requires: :block_unrated
      command 0x09, :set_on_demand_rating_threshold, request: SetRatingRequest,
        access: :manage, requires: :on_demand_content_rating
      command 0x0A, :set_scheduled_content_rating_threshold, request: SetRatingRequest,
        access: :manage, requires: :scheduled_content_rating
      command 0x0B, :add_block_channels, request: ChannelsRequest,
        access: :manage, requires: :block_channels
      command 0x0C, :remove_block_channels, request: ChannelIndexesRequest,
        access: :manage, requires: :block_channels
      command 0x0D, :add_block_applications, request: ApplicationsRequest,
        access: :manage, requires: :block_applications
      command 0x0E, :remove_block_applications, request: ApplicationsRequest,
        access: :manage, requires: :block_applications
      command 0x0F, :set_block_content_time_window, request: SetTimeWindowRequest,
        access: :manage, requires: :block_content_time_window
      command 0x10, :remove_block_content_time_window, request: RemoveTimeWindowsRequest,
        access: :manage, requires: :block_content_time_window

      event 0x01, :entering_block_content_time_window, priority: :info,
        requires: :block_content_time_window, payload: EmptyEvent

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @enabled : Bool = false,
                     @on_demand_ratings : Array(RatingName) = [] of RatingName,
                     @on_demand_rating_threshold : String = "",
                     @scheduled_content_ratings : Array(RatingName) = [] of RatingName,
                     @scheduled_content_rating_threshold : String = "",
                     @block_unrated : Bool = false,
                     @block_channel_list : Array(BlockChannel) = [] of BlockChannel,
                     @block_application_list : Array(AppInfo) = [] of AppInfo,
                     @block_content_time_window : Array(TimeWindow) = [] of TimeWindow)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("unsupported Content Control feature bits") if (@feature_map.value & ~SUPPORTED_FEATURES) != 0
        if @feature_map.on_demand_content_rating? && (@on_demand_ratings.empty? || @on_demand_rating_threshold.empty?)
          raise ArgumentError.new("OnDemandContentRating requires ratings and a threshold")
        end
        if @feature_map.scheduled_content_rating? && (@scheduled_content_ratings.empty? || @scheduled_content_rating_threshold.empty?)
          raise ArgumentError.new("ScheduledContentRating requires ratings and a threshold")
        end
        if !@feature_map.on_demand_content_rating? && (!@on_demand_ratings.empty? || !@on_demand_rating_threshold.empty?)
          raise ArgumentError.new("on-demand ratings require OnDemandContentRating")
        end
        if !@feature_map.scheduled_content_rating? && (!@scheduled_content_ratings.empty? || !@scheduled_content_rating_threshold.empty?)
          raise ArgumentError.new("scheduled ratings require ScheduledContentRating")
        end
        raise ArgumentError.new("BlockUnrated feature is required") if @block_unrated && !@feature_map.block_unrated?
        raise ArgumentError.new("BlockChannels feature is required") if !@block_channel_list.empty? && !@feature_map.block_channels?
        raise ArgumentError.new("BlockApplications feature is required") if !@block_application_list.empty? && !@feature_map.block_applications?
        raise ArgumentError.new("BlockContentTimeWindow feature is required") if !@block_content_time_window.empty? && !@feature_map.block_content_time_window?
        set_pin(generate_pin) if @feature_map.pin_management?
        validate_ratings!(@on_demand_ratings, @on_demand_rating_threshold)
        validate_ratings!(@scheduled_content_ratings, @scheduled_content_rating_threshold)
        validate_channels!(@block_channel_list)
        validate_applications!(@block_application_list)
        validate_time_windows!(@block_content_time_window)
        @on_demand_ratings = @on_demand_ratings.dup
        @scheduled_content_ratings = @scheduled_content_ratings.dup
        @block_channel_list = @block_channel_list.dup
        @block_application_list = @block_application_list.dup
        @block_content_time_window = @block_content_time_window.dup
      end

      @validate_channel : Proc(BlockChannel, Bool)?
      @identify_application : Proc(AppInfo, Bool)?
      @on_policy_changed : Proc(Nil)?
      @pin_salt : Bytes?
      @pin_verifier : Bytes?
      @local_time_provider : Proc(Time?) = -> : Time? { Time.local }
      @last_active_time_period : Tuple(Int32, Int32, Int32, UInt16, Int32)?

      def local_time_provider=(@local_time_provider : Proc(Time?)) : Nil
      end

      def on_validate_channel(&block : BlockChannel -> Bool) : Nil
        @validate_channel = block
      end

      def on_identify_application(&block : AppInfo -> Bool) : Nil
        @identify_application = block
      end

      # Called after any policy change so a media host can stop disallowed playback.
      def on_policy_changed(&block : -> Nil) : Nil
        @on_policy_changed = block
      end

      # Query before starting or continuing playback. Unknown ratings are
      # treated as unrated; the host remains responsible for stopping playback.
      def playback_allowed?(rating : String? = nil, scheduled : Bool = false,
                            channel : BlockChannel? = nil, application : AppInfo? = nil) : Bool
        return true unless enabled?
        return false if @feature_map.block_content_time_window? && time_window_blocked?(@local_time_provider.call)
        if application && @feature_map.block_applications?
          return false if @block_application_list.any? { |blocked| same_app?(blocked, application) }
        end
        if channel && @feature_map.block_channels?
          return false if @block_channel_list.any? { |blocked| same_channel?(blocked, channel) }
        end
        ratings = scheduled ? @scheduled_content_ratings : @on_demand_ratings
        threshold = scheduled ? @scheduled_content_rating_threshold : @on_demand_rating_threshold
        feature = scheduled ? @feature_map.scheduled_content_rating? : @feature_map.on_demand_content_rating?
        if feature && !threshold.empty? && rating
          rating_index = ratings.index { |item| item.rating_name == rating }
          threshold_index = ratings.index { |item| item.rating_name == threshold }
          return rating_index < threshold_index if rating_index && threshold_index
        end
        return false if @feature_map.block_unrated? && block_unrated? && (rating.nil? || (feature && !ratings.any? { |item| item.rating_name == rating }))
        true
      end

      def on_demand_ratings : Array(RatingName)
        @on_demand_ratings.dup
      end

      def on_demand_ratings=(value : Array(RatingName)) : Nil
        raise ArgumentError.new("ratings list cannot be empty") if @feature_map.on_demand_content_rating? && value.empty?
        validate_ratings!(value, @on_demand_rating_threshold)
        previous_def(value)
      end

      def on_demand_rating_threshold=(value : String) : Nil
        raise ArgumentError.new("rating threshold cannot be empty") if @feature_map.on_demand_content_rating? && value.empty?
        validate_ratings!(@on_demand_ratings, value)
        previous_def(value)
      end

      def scheduled_content_ratings : Array(RatingName)
        @scheduled_content_ratings.dup
      end

      def scheduled_content_ratings=(value : Array(RatingName)) : Nil
        raise ArgumentError.new("ratings list cannot be empty") if @feature_map.scheduled_content_rating? && value.empty?
        validate_ratings!(value, @scheduled_content_rating_threshold)
        previous_def(value)
      end

      def scheduled_content_rating_threshold=(value : String) : Nil
        raise ArgumentError.new("rating threshold cannot be empty") if @feature_map.scheduled_content_rating? && value.empty?
        validate_ratings!(@scheduled_content_ratings, value)
        previous_def(value)
      end

      def block_application_list : Array(AppInfo)
        @block_application_list.dup
      end

      def block_application_list=(value : Array(AppInfo)) : Nil
        validate_applications!(value)
        previous_def(value)
      end

      def block_channel_list : Array(BlockChannel)
        @block_channel_list.dup
      end

      def block_channel_list=(value : Array(BlockChannel)) : Nil
        validate_channels!(value)
        previous_def(value)
      end

      def block_content_time_window : Array(TimeWindow)
        @block_content_time_window.dup
      end

      def block_content_time_window=(value : Array(TimeWindow)) : Nil
        validate_time_windows!(value)
        previous_def(value)
      end

      # Call periodically while the media host is running. The host callback
      # rechecks active playback when the clock enters a configured period.
      def tick_block_content_time_window(local_time : Time? = @local_time_provider.call) : Nil
        return unless @feature_map.block_content_time_window?
        return unless local_time
        active_period = enabled? ? active_time_period(local_time) : nil
        if active_period && active_period != @last_active_time_period
          emit_entering_block_content_time_window(EmptyEvent.new)
          @on_policy_changed.try(&.call)
        end
        @last_active_time_period = active_period
      end

      def enable : InteractionModel::Status
        self.enabled = true
        InteractionModel::Status.success
      end

      def disable : InteractionModel::Status
        self.enabled = false
        InteractionModel::Status.success
      end

      def update_pin(request : UpdatePinRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_pin?(request.old_pin) && valid_pin?(request.new_pin)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidPINCode) unless pin_matches?(request.old_pin)
        set_pin(request.new_pin)
        increment_version
        InteractionModel::Status.success
      end

      def reset_pin : ResetPinResponse
        next_pin = generate_pin
        while pin_matches?(next_pin)
          next_pin = generate_pin
        end
        set_pin(next_pin)
        increment_version
        ResetPinResponse.new(next_pin)
      end

      def block_unrated_content : InteractionModel::Status
        self.block_unrated = true
        InteractionModel::Status.success
      end

      def unblock_unrated_content : InteractionModel::Status
        self.block_unrated = false
        InteractionModel::Status.success
      end

      # ameba:disable Naming/AccessorMethodName
      def set_on_demand_rating_threshold(request : SetRatingRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.rating.bytesize > MAX_RATING_BYTES
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidRating) unless @on_demand_ratings.any? { |value| value.rating_name == request.rating }
        self.on_demand_rating_threshold = request.rating
        InteractionModel::Status.success
      end

      # ameba:disable Naming/AccessorMethodName
      def set_scheduled_content_rating_threshold(request : SetRatingRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.rating.bytesize > MAX_RATING_BYTES
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidRating) unless @scheduled_content_ratings.any? { |value| value.rating_name == request.rating }
        self.scheduled_content_rating_threshold = request.rating
        InteractionModel::Status.success
      end

      def add_block_channels(request : ChannelsRequest) : InteractionModel::Status
        return InteractionModel::Status.success if request.channels.empty?
        validator = @validate_channel
        return InteractionModel::Status.invalid_in_state unless validator
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidChannel) unless request.channels.all? { |channel| validator.call(channel) }

        additions = request.channels.reject { |channel| @block_channel_list.any? { |existing| same_channel?(existing, channel) } }
        return InteractionModel::Status.cluster_failure(StatusCode::ChannelAlreadyExist) if additions.empty?
        next_list = @block_channel_list.dup
        additions.uniq { |channel| {channel.major_number, channel.minor_number, channel.identifier} }.each do |channel|
          index = next_channel_index(next_list)
          return InteractionModel::Status.resource_exhausted unless index
          next_list << BlockChannel.new(index, channel.major_number, channel.minor_number, channel.identifier)
        end
        self.block_channel_list = next_list
        InteractionModel::Status.success
      end

      def remove_block_channels(request : ChannelIndexesRequest) : InteractionModel::Status
        return InteractionModel::Status.success if request.channel_indexes.empty?
        return InteractionModel::Status.cluster_failure(StatusCode::ChannelNotExist) unless request.channel_indexes.all? { |index| @block_channel_list.any?(&.block_channel_index.==(index)) }
        self.block_channel_list = @block_channel_list.reject { |channel| request.channel_indexes.includes?(channel.block_channel_index) }
        InteractionModel::Status.success
      end

      def add_block_applications(request : ApplicationsRequest) : InteractionModel::Status
        return InteractionModel::Status.success if request.applications.empty?
        if identifier = @identify_application
          return InteractionModel::Status.cluster_failure(StatusCode::UnidentifiableApplication) unless request.applications.all? { |app| identifier.call(app) }
        end
        additions = request.applications.reject { |app| @block_application_list.any? { |existing| same_app?(existing, app) } }
        return InteractionModel::Status.cluster_failure(StatusCode::ApplicationAlreadyExist) if additions.empty?
        self.block_application_list = @block_application_list + additions.uniq { |app| {app.catalog_vendor_id, app.application_id} }
        InteractionModel::Status.success
      end

      def remove_block_applications(request : ApplicationsRequest) : InteractionModel::Status
        return InteractionModel::Status.success if request.applications.empty?
        return InteractionModel::Status.cluster_failure(StatusCode::ApplicationNotExist) unless request.applications.all? { |app| @block_application_list.any? { |existing| same_app?(existing, app) } }
        self.block_application_list = @block_application_list.reject { |existing| request.applications.any? { |app| same_app?(existing, app) } }
        InteractionModel::Status.success
      end

      # ameba:disable Naming/AccessorMethodName
      def set_block_content_time_window(request : SetTimeWindowRequest) : InteractionModel::Status
        window = request.time_window
        return InteractionModel::Status.constraint_error unless valid_time_window?(window)
        if index = window.time_window_index
          position = @block_content_time_window.index(&.time_window_index.==(index))
          return InteractionModel::Status.cluster_failure(StatusCode::TimeWindowNotExist) unless position
          next_list = @block_content_time_window.dup
          next_list[position] = window
        else
          if @block_content_time_window.any? { |existing| existing.day_of_week == window.day_of_week && existing.time_period == window.time_period }
            return InteractionModel::Status.cluster_failure(StatusCode::TimeWindowAlreadyExist)
          end
          return InteractionModel::Status.resource_exhausted if @block_content_time_window.size >= MAX_TIME_WINDOWS
          index = next_time_window_index
          return InteractionModel::Status.resource_exhausted unless index
          next_list = @block_content_time_window + [TimeWindow.new(index, window.day_of_week, window.time_period)]
        end
        return InteractionModel::Status.constraint_error unless valid_time_windows?(next_list)
        self.block_content_time_window = next_list
        InteractionModel::Status.success
      end

      def remove_block_content_time_window(request : RemoveTimeWindowsRequest) : InteractionModel::Status
        return InteractionModel::Status.success if request.time_window_indexes.empty?
        unless request.time_window_indexes.all? { |index| @block_content_time_window.any?(&.time_window_index.==(index)) }
          return InteractionModel::Status.cluster_failure(StatusCode::TimeWindowNotExist)
        end
        self.block_content_time_window = @block_content_time_window.reject { |window| request.time_window_indexes.includes?(window.time_window_index) }
        InteractionModel::Status.success
      end

      private def same_app?(first : AppInfo, second : AppInfo) : Bool
        first.catalog_vendor_id == second.catalog_vendor_id && first.application_id == second.application_id
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        if (salt = @pin_salt) && (verifier = @pin_verifier)
          document[PERSISTED_PIN_SALT_KEY] = salt.dup
          document[PERSISTED_PIN_VERIFIER_KEY] = verifier.dup
        end
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        return unless @feature_map.pin_management?
        salt_value = document[PERSISTED_PIN_SALT_KEY]?
        verifier_value = document[PERSISTED_PIN_VERIFIER_KEY]?
        # Documents written before PM existed have neither key. Keep a new,
        # unknown PIN, which an administrator can replace with ResetPIN.
        return if salt_value.nil? && verifier_value.nil?
        salt = salt_value.as?(Bytes)
        verifier = verifier_value.as?(Bytes)
        unless salt && salt.size == PIN_SALT_BYTES && verifier && verifier.size == PIN_VERIFIER_BYTES
          raise StorageError.new("Invalid persisted Content Control PIN verifier")
        end
        @pin_salt = salt.dup
        @pin_verifier = verifier.dup
      end

      private def valid_pin?(pin : String) : Bool
        pin.bytesize.in?(1..PIN_LENGTH) && pin.each_char.all?(&.ascii_number?)
      end

      private def generate_pin : String
        Random::Secure.rand(PIN_RANGE).to_s.rjust(PIN_LENGTH, '0')
      end

      private def set_pin(pin : String) : Nil
        salt = Random::Secure.random_bytes(PIN_SALT_BYTES)
        verifier = derive_pin(pin, salt)
        @pin_salt = salt
        @pin_verifier = verifier
      end

      private def pin_matches?(pin : String) : Bool
        salt = @pin_salt
        verifier = @pin_verifier
        return false unless salt && verifier
        candidate = derive_pin(pin, salt)
        difference = 0_u8
        verifier.each_with_index { |byte, index| difference |= byte ^ candidate[index] }
        difference.zero?
      end

      private def derive_pin(pin : String, salt : Bytes) : Bytes
        OpenSSL::PKCS5.pbkdf2_hmac(pin.to_slice, salt, PIN_DERIVATION_ITERATIONS,
          OpenSSL::Algorithm::SHA256, PIN_VERIFIER_BYTES)
      end

      private def policy_changed(_value) : Nil
        @on_policy_changed.try(&.call)
      end

      private def same_channel?(first : BlockChannel, second : BlockChannel) : Bool
        first.major_number == second.major_number && first.minor_number == second.minor_number && first.identifier == second.identifier
      end

      private def next_channel_index(channels : Array(BlockChannel)) : UInt16?
        (0..UInt16::MAX).each do |number|
          candidate = number.to_u16
          return candidate unless channels.any?(&.block_channel_index.==(candidate))
        end
        nil
      end

      private def next_time_window_index : UInt16?
        (0..UInt16::MAX).each do |number|
          candidate = number.to_u16
          return candidate unless @block_content_time_window.any?(&.time_window_index.==(candidate))
        end
        nil
      end

      private def valid_time_window?(window : TimeWindow) : Bool
        return false if window.day_of_week.zero? || (window.day_of_week & ~DAY_OF_WEEK_MASK) != 0
        periods = window.time_period
        return false if periods.empty?
        periods.each do |period|
          return false if period.start_hour > MAX_HOUR || period.end_hour > MAX_HOUR || period.start_minute > MAX_MINUTE || period.end_minute > MAX_MINUTE
          return false if period.end_hour < period.start_hour || (period.end_hour == period.start_hour && period.end_minute <= period.start_minute)
        end
        last_end = -1
        periods.sort_by { |period| period.start_hour.to_i * MINUTES_PER_HOUR + period.start_minute }.each do |period|
          start_minute = period.start_hour.to_i * MINUTES_PER_HOUR + period.start_minute
          return false if start_minute <= last_end
          last_end = period.end_hour.to_i * MINUTES_PER_HOUR + period.end_minute
        end
        true
      end

      private def valid_time_windows?(windows : Array(TimeWindow)) : Bool
        return false if windows.size > MAX_TIME_WINDOWS
        days = 0_u8
        indexes = Set(UInt16).new
        windows.each do |window|
          index = window.time_window_index
          return false unless index && indexes.add?(index) && valid_time_window?(window)
          return false unless (days & window.day_of_week).zero?
          days |= window.day_of_week
        end
        true
      end

      private def validate_time_windows!(windows : Array(TimeWindow)) : Nil
        raise ArgumentError.new("invalid Content Control time window") unless valid_time_windows?(windows)
      end

      private def time_window_blocked?(local_time : Time?) : Bool
        return false if @block_content_time_window.empty?
        return true unless local_time
        !active_time_period(local_time).nil?
      end

      private def active_time_period(local_time : Time) : Tuple(Int32, Int32, Int32, UInt16, Int32)?
        day_bit = (1 << (local_time.day_of_week.value % 7)).to_u8
        minute = local_time.hour * MINUTES_PER_HOUR + local_time.minute
        @block_content_time_window.each do |window|
          next if (window.day_of_week & day_bit).zero?
          window_index = window.time_window_index
          next unless window_index
          window.time_period.each_with_index do |period, index|
            if minute >= period.start_hour.to_i * MINUTES_PER_HOUR + period.start_minute &&
               minute <= period.end_hour.to_i * MINUTES_PER_HOUR + period.end_minute
              return {local_time.year, local_time.month, local_time.day, window_index, index}
            end
          end
        end
        nil
      end

      private def validate_ratings!(ratings : Array(RatingName), threshold : String) : Nil
        raise ArgumentError.new("rating threshold must name a configured rating") unless threshold.empty? || ratings.any? { |rating| rating.rating_name == threshold }
        raise ArgumentError.new("rating threshold exceeds 8 bytes") if threshold.bytesize > MAX_RATING_BYTES
        seen = Set(String).new
        ratings.each do |rating|
          raise ArgumentError.new("rating name must be 1-8 bytes and unique") if rating.rating_name.empty? || rating.rating_name.bytesize > MAX_RATING_BYTES || !seen.add?(rating.rating_name)
          if description = rating.rating_name_desc
            raise ArgumentError.new("rating description exceeds 64 bytes") if description.bytesize > MAX_RATING_DESCRIPTION_BYTES
          end
        end
      end

      private def validate_channels!(channels : Array(BlockChannel)) : Nil
        indexes = Set(UInt16).new
        identities = Set(Tuple(UInt16, UInt16, String?)).new
        channels.each do |channel|
          index = channel.block_channel_index
          raise ArgumentError.new("blocked channel index must be assigned and unique") unless index && indexes.add?(index)
          identity = {channel.major_number, channel.minor_number, channel.identifier}
          raise ArgumentError.new("blocked channel identity must be unique") unless identities.add?(identity)
        end
      end

      private def validate_applications!(applications : Array(AppInfo)) : Nil
        identities = Set(Tuple(UInt16, String)).new
        applications.each do |application|
          identity = {application.catalog_vendor_id, application.application_id}
          raise ArgumentError.new("blocked application identity must be unique") unless identities.add?(identity)
        end
      end
    end
  end
end
