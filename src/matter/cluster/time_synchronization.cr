require "./cluster"
require "log"
require "tlv"

module Matter
  module Cluster
    # Matter 1.6 Time Synchronization (0x0038). This base server accepts an
    # administrator's UTC time and advances it using a monotonic clock. It
    # starts unsynchronized on every boot. Hosts may opt into the TimeZone
    # feature without a time-zone database. The NTP client is opt-in; TSC
    # remains unavailable until peer synchronization is implemented.
    class TimeSynchronization < Base
      Log = ::Log.for("matter.cluster.time_synchronization")

      cluster 0x0038, revision: 2, persist_state: false

      feature :time_zone, bit: 0
      feature :ntp_client, bit: 1

      TIME_NOT_ACCEPTED            = 0x02_u8
      TIME_FAILURE_MIN_INTERVAL    = 1.hour
      DST_TABLE_EMPTY_MIN_INTERVAL = 1.hour
      TIME_ZONE_OFFSET_MIN         = -43_200
      TIME_ZONE_OFFSET_MAX         =  50_400
      TIME_ZONE_NAME_MAX_BYTES     =      64
      TIME_ZONE_LIST_MAX_SIZE      =    2_u8
      DST_OFFSET_LIST_MAX_SIZE     =    4_u8
      DEFAULT_NTP_MAX_BYTES        =     128
      NTP_REFRESH_INTERVAL         = 1.hour
      MICROSECONDS_PER_SECOND      = 1_000_000_i128

      enum TimeZoneDatabase : UInt8
        Full    = 0
        Partial = 1
        None    = 2
      end

      enum Granularity : UInt8
        NoTime       = 0
        Minutes      = 1
        Seconds      = 2
        Milliseconds = 3
        Microseconds = 4
      end

      enum TimeSource : UInt8
        None             = 0x00
        Unknown          = 0x01
        Admin            = 0x02
        NodeTimeCluster  = 0x03
        NonMatterSntp    = 0x04
        NonMatterNtp     = 0x05
        MatterSntp       = 0x06
        MatterNtp        = 0x07
        MixedNtp         = 0x08
        NonMatterSntpnts = 0x09
        NonMatterNtpnts  = 0x0A
        MatterSntpnts    = 0x0B
        MatterNtpnts     = 0x0C
        MixedNtpnts      = 0x0D
        CloudSource      = 0x0E
        Ptp              = 0x0F
        Gnss             = 0x10
      end

      struct SetUtcTimeRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property utc_time : UInt64

        @[TLV::Field(tag: 1)]
        property granularity : Granularity

        @[TLV::Field(tag: 2, optional: true)]
        property time_source : TimeSource?

        def initialize(@utc_time : UInt64, @granularity : Granularity,
                       @time_source : TimeSource? = nil)
        end
      end

      struct SetDefaultNtpRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter default_ntp : String?

        def initialize(@default_ntp : String?)
        end
      end

      struct TimeFailureEvent
        include TLV::Serializable

        def initialize
        end
      end

      struct TimeZoneStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter offset : Int32
        @[TLV::Field(tag: 1)]
        getter valid_at : UInt64
        @[TLV::Field(tag: 2, optional: true)]
        getter name : String?

        def initialize(@offset : Int32, @valid_at : UInt64, @name : String? = nil)
        end
      end

      struct DstOffsetStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter offset : Int32
        @[TLV::Field(tag: 1)]
        getter valid_starting : UInt64
        @[TLV::Field(tag: 2)]
        getter valid_until : UInt64?

        def initialize(@offset : Int32, @valid_starting : UInt64, @valid_until : UInt64?)
        end
      end

      struct SetTimeZoneRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter time_zone : Array(TimeZoneStruct)

        def initialize(@time_zone : Array(TimeZoneStruct))
        end
      end

      struct SetTimeZoneResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter? dst_offset_required : Bool

        def initialize(@dst_offset_required : Bool)
        end
      end

      struct SetDstOffsetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter dst_offset : Array(DstOffsetStruct)

        def initialize(@dst_offset : Array(DstOffsetStruct))
        end
      end

      struct DstTableEmptyEvent
        include TLV::Serializable

        def initialize
        end
      end

      struct DstStatusEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter? dst_offset_active : Bool

        def initialize(@dst_offset_active : Bool)
        end
      end

      struct TimeZoneStatusEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter offset : Int32
        @[TLV::Field(tag: 1, optional: true)]
        getter name : String?

        def initialize(@offset : Int32, @name : String? = nil)
        end
      end

      private struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter features : UInt32
        getter time_zone : Array(TimeZoneStruct)
        getter dst_offset : Array(DstOffsetStruct)
        getter default_ntp : String?

        def initialize(@data_version, @features, @time_zone, @dst_offset, @default_ntp)
        end
      end

      attribute 0x0000, :utc_time, UInt64, computed: true, nullable: true, omit_changes: true
      attribute 0x0001, :granularity, Granularity, default: Granularity::NoTime
      attribute 0x0002, :time_source, TimeSource, default: TimeSource::None
      attribute 0x0004, :default_ntp, String, computed: true, nullable: true, requires: :ntp_client
      attribute 0x0005, :time_zone, Array(TimeZoneStruct), computed: true, requires: :time_zone
      attribute 0x0006, :dst_offset, Array(DstOffsetStruct), computed: true, requires: :time_zone
      attribute 0x0007, :local_time, UInt64, computed: true, nullable: true,
        omit_changes: true, requires: :time_zone
      attribute 0x0008, :time_zone_database, TimeZoneDatabase, computed: true,
        fixed: true, requires: :time_zone
      attribute 0x000A, :time_zone_list_max_size, UInt8, computed: true,
        fixed: true, requires: :time_zone
      attribute 0x000B, :dst_offset_list_max_size, UInt8, computed: true,
        fixed: true, requires: :time_zone
      attribute 0x000C, :supports_dns_resolve, Bool, computed: true,
        fixed: true, requires: :ntp_client

      event 0x0000, :dst_table_empty, priority: :info, requires: :time_zone
      event 0x0001, :dst_status, priority: :info, requires: :time_zone
      event 0x0002, :time_zone_status, priority: :info, requires: :time_zone
      event 0x0003, :time_failure, priority: :info
      command 0x0000, :set_utc_time, request: SetUtcTimeRequest, access: :administer, handler: :apply_utc_time
      command 0x0002, :set_time_zone, request: SetTimeZoneRequest,
        response: SetTimeZoneResponse, response_id: 0x0003, access: :manage,
        requires: :time_zone, handler: :apply_time_zone
      command 0x0004, :set_dst_offset, request: SetDstOffsetRequest,
        access: :manage, requires: :time_zone, handler: :apply_dst_offset
      command 0x0005, :set_default_ntp, request: SetDefaultNtpRequest,
        access: :administer, requires: :ntp_client, handler: :apply_default_ntp

      @base_utc_time : UInt64?
      @base_instant : Time::Instant?
      @last_time_failure : Time::Instant?
      @time_zone : Array(TimeZoneStruct)
      @dst_offset : Array(DstOffsetStruct)
      @last_dst_empty : Time::Instant?
      @last_zone_status : TimeZoneStruct?
      @last_dst_active : Bool
      @last_dst_entry_present : Bool
      @default_ntp : String?
      @last_ntp_attempt : Time::Instant?
      property on_ntp_query : Proc(String, UInt64?)?

      def initialize(endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
                     @feature_map : Feature = Feature::None)
        raise ConfigurationError.new("Time Synchronization belongs on endpoint 0") unless endpoint_id.number == 0_u16
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @base_utc_time = nil
        @base_instant = nil
        @last_time_failure = nil
        @time_zone = [TimeZoneStruct.new(0, 0_u64)]
        @dst_offset = [] of DstOffsetStruct
        @last_dst_empty = nil
        @last_zone_status = @time_zone.first
        @last_dst_active = false
        @last_dst_entry_present = false
        @default_ntp = nil
        @last_ntp_attempt = nil
        @on_ntp_query = nil
      end

      def utc_time : UInt64?
        utc_time_at(Time.instant)
      end

      private def utc_time_at(now : Time::Instant) : UInt64?
        base = @base_utc_time
        started = @base_instant
        return unless base && started
        elapsed = (now - started).total_microseconds.to_u64
        return if elapsed > UInt64::MAX - base
        base + elapsed
      end

      def time_zone : Array(TimeZoneStruct)
        @time_zone.dup
      end

      def dst_offset : Array(DstOffsetStruct)
        @dst_offset.dup
      end

      def default_ntp : String?
        @default_ntp
      end

      def supports_dns_resolve? : Bool
        false
      end

      def apply_default_ntp(request : SetDefaultNtpRequest) : InteractionModel::Status
        address = request.default_ntp
        if address
          return InteractionModel::Status.constraint_error if address.bytesize > DEFAULT_NTP_MAX_BYTES
          return InteractionModel::Status.invalid_command unless valid_default_ntp?(address)
        end
        @default_ntp = address
        @last_ntp_attempt = nil
        increment_version_and_notify(ATTR_DEFAULT_NTP)
        InteractionModel::Status.success
      end

      # Called from the device clock poll. A failed query leaves any accepted
      # time in place; the next attempt is bounded by NTP_REFRESH_INTERVAL.
      def refresh_from_default_ntp(now : Time::Instant = Time.instant) : Bool
        return false unless @feature_map.ntp_client?
        address = @default_ntp
        return false if address.nil? || address.empty?
        if last = @last_ntp_attempt
          return false if now - last < NTP_REFRESH_INTERVAL
        end
        @last_ntp_attempt = now
        ntp_time = if query = @on_ntp_query
                     query.call(address)
                   else
                     SntpClient.query(address)
                   end
        return false unless @default_ntp == address
        unless ntp_time
          report_time_failure if utc_time.nil?
          return false
        end
        status = apply_utc_time(SetUtcTimeRequest.new(ntp_time, Granularity::Seconds))
        return false unless status.status == InteractionModel::StatusCode::Success
        self.time_source = TimeSource::NonMatterSntp
        true
      end

      def time_zone_database : TimeZoneDatabase
        TimeZoneDatabase::None
      end

      def time_zone_list_max_size : UInt8
        TIME_ZONE_LIST_MAX_SIZE
      end

      def dst_offset_list_max_size : UInt8
        DST_OFFSET_LIST_MAX_SIZE
      end

      def local_time : UInt64?
        return unless utc = utc_time
        refresh_time_state(utc)
        return if @dst_offset.empty?
        zone = current_zone(utc)
        dst = current_dst(utc)
        offset = zone.offset.to_i128 + (dst ? dst.offset.to_i128 : 0_i128)
        local = utc.to_i128 + offset * MICROSECONDS_PER_SECOND
        return if local < 0_i128 || local > UInt64::MAX.to_i128
        local.to_u64
      end

      # Device runtime calls this once a second while started. Hosts with a
      # separate clock scheduler may call it too; comparisons suppress
      # duplicate status events when a read and a tick observe the same state.
      def advance_time_state(now : Time::Instant = Time.instant) : Nil
        refresh_from_default_ntp(now) if @feature_map.ntp_client?
        return unless @feature_map.time_zone?
        if utc = utc_time_at(now)
          refresh_time_state(utc)
        end
      end

      def apply_time_zone(request : SetTimeZoneRequest) : SetTimeZoneResponse | InteractionModel::Status
        zones = request.time_zone
        return InteractionModel::Status.resource_exhausted if zones.size > TIME_ZONE_LIST_MAX_SIZE
        return InteractionModel::Status.constraint_error unless valid_time_zones?(zones)

        was_dst_active = @last_dst_active
        @time_zone = zones.dup
        @dst_offset.clear
        current = current_zone(utc_time)
        @last_zone_status = current
        @last_dst_active = false
        @last_dst_entry_present = false
        increment_version_and_notify(ATTR_TIME_ZONE)
        increment_version_and_notify(ATTR_DST_OFFSET)
        notify_changed(ATTR_LOCAL_TIME)
        emit_event(EVENT_TIME_ZONE_STATUS, TimeZoneStatusEvent.new(current.offset, current.name))
        emit_event(EVENT_DST_STATUS, DstStatusEvent.new(false)) if was_dst_active
        report_dst_table_empty(force: true)
        SetTimeZoneResponse.new(true)
      end

      def apply_dst_offset(request : SetDstOffsetRequest) : InteractionModel::Status
        offsets = request.dst_offset
        return InteractionModel::Status.resource_exhausted if offsets.size > DST_OFFSET_LIST_MAX_SIZE
        return InteractionModel::Status.constraint_error unless valid_dst_offsets?(offsets)

        was_dst_active = @last_dst_active
        @dst_offset = offsets.dup
        if offsets.empty?
          @last_dst_active = false
          @last_dst_entry_present = false
        end
        increment_version_and_notify(ATTR_DST_OFFSET)
        notify_changed(ATTR_LOCAL_TIME)
        if offsets.empty?
          emit_event(EVENT_DST_STATUS, DstStatusEvent.new(false)) if was_dst_active
          report_dst_table_empty(force: true)
        elsif utc = utc_time
          refresh_time_state(utc)
        end
        InteractionModel::Status.success
      end

      def save_state : Storage::Document?
        return unless @feature_map.time_zone? || @feature_map.ntp_client?
        PersistedState.new(@data_version, @feature_map.value, @time_zone, @dst_offset, @default_ntp).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        return unless @feature_map.time_zone? || @feature_map.ntp_client?
        state = PersistedState.from_document(document)
        return if state.features != @feature_map.value
        if address = state.default_ntp
          raise StorageError.new("Invalid persisted DefaultNTP") if address.bytesize > DEFAULT_NTP_MAX_BYTES || !valid_default_ntp?(address)
        end
        raise StorageError.new("Invalid persisted TimeZone") unless valid_time_zones?(state.time_zone)
        raise StorageError.new("Invalid persisted DSTOffset") unless valid_dst_offsets?(state.dst_offset)
        @time_zone = state.time_zone.dup
        @dst_offset = state.dst_offset.dup
        @default_ntp = state.default_ntp
        @data_version = state.data_version
        @last_zone_status = @time_zone.first
        @last_dst_active = false
        @last_dst_entry_present = false
      rescue ex
        Log.warn(exception: ex) { "Time Synchronization restore failed; starting fresh" }
      end

      def apply_utc_time(request : SetUtcTimeRequest) : InteractionModel::Status
        # The Matter 1.6 SetUTCTime command requires an offered UTC source;
        # NoTime never establishes one. A synchronized node also rejects an
        # update with lower precision than its current source.
        if request.granularity == Granularity::NoTime ||
           (@granularity != Granularity::NoTime && request.granularity.value < @granularity.value)
          return InteractionModel::Status.cluster_failure(TIME_NOT_ACCEPTED)
        end

        @base_utc_time = request.utc_time
        @base_instant = Time.instant
        self.granularity = request.granularity
        self.time_source = TimeSource::Admin
        increment_version_and_notify(ATTR_UTC_TIME)
        if @feature_map.time_zone?
          notify_changed(ATTR_LOCAL_TIME)
          refresh_time_state(request.utc_time)
        end
        InteractionModel::Status.success
      end

      def report_time_failure : Bytes?
        @base_utc_time = nil
        @base_instant = nil
        self.granularity = Granularity::NoTime
        self.time_source = TimeSource::None
        increment_version_and_notify(ATTR_UTC_TIME)
        if @feature_map.time_zone?
          notify_changed(ATTR_LOCAL_TIME)
          @last_dst_entry_present = false
          if @last_dst_active
            @last_dst_active = false
            emit_event(EVENT_DST_STATUS, DstStatusEvent.new(false))
          end
        end
        if last = @last_time_failure
          return if Time.instant - last < TIME_FAILURE_MIN_INTERVAL
        end
        @last_time_failure = Time.instant
        payload = TimeFailureEvent.new
        emit_event(EVENT_TIME_FAILURE, payload)
        payload.to_slice
      end

      private def valid_time_zones?(zones : Array(TimeZoneStruct)) : Bool
        return false if zones.empty? || zones.size > TIME_ZONE_LIST_MAX_SIZE
        return false unless zones.first.valid_at == 0_u64
        zones.each_with_index do |entry, index|
          return false unless TIME_ZONE_OFFSET_MIN <= entry.offset <= TIME_ZONE_OFFSET_MAX
          return false if entry.name.try(&.bytesize).try { |size| size > TIME_ZONE_NAME_MAX_BYTES }
          return false if index > 0 && entry.valid_at == 0_u64
        end
        true
      end

      private def valid_default_ntp?(address : String) : Bool
        return true if address.empty?
        parsed = Socket::IPAddress.new(address, SntpClient::NTP_PORT)
        parsed.family == Socket::Family::INET6 && parsed.address == address
      rescue Socket::Error
        false
      end

      private def valid_dst_offsets?(offsets : Array(DstOffsetStruct)) : Bool
        return false if offsets.size > DST_OFFSET_LIST_MAX_SIZE
        previous_until = nil.as(UInt64?)
        offsets.each_with_index do |entry, index|
          return false if entry.valid_until && entry.valid_until.as(UInt64) <= entry.valid_starting
          return false if index > 0 && (previous_until.nil? || entry.valid_starting < previous_until.as(UInt64))
          previous_until = entry.valid_until
        end
        true
      end

      private def current_zone(utc : UInt64?) : TimeZoneStruct
        return @time_zone.first unless utc
        @time_zone.reverse_each do |entry|
          return entry if entry.valid_at <= utc
        end
        @time_zone.first
      end

      private def current_dst(utc : UInt64) : DstOffsetStruct?
        @dst_offset.find do |entry|
          entry.valid_starting <= utc && (entry.valid_until.nil? || utc < entry.valid_until.as(UInt64))
        end
      end

      private def refresh_time_state(utc : UInt64) : Nil
        zone = current_zone(utc)
        previous_zone = @last_zone_status
        if previous_zone.nil? || previous_zone.offset != zone.offset || previous_zone.name != zone.name
          @last_zone_status = zone
          notify_changed(ATTR_LOCAL_TIME)
          emit_event(EVENT_TIME_ZONE_STATUS, TimeZoneStatusEvent.new(zone.offset, zone.name))
        end
        entry = current_dst(utc)
        previous_entry_present = @last_dst_entry_present
        @last_dst_entry_present = !entry.nil?
        active = entry ? entry.offset != 0 : false
        dst_changed = active != @last_dst_active
        if dst_changed
          @last_dst_active = active
          emit_event(EVENT_DST_STATUS, DstStatusEvent.new(active))
          notify_changed(ATTR_LOCAL_TIME)
        end
        if @dst_offset.empty? || @dst_offset.none? { |future_entry| future_entry.valid_starting > utc || future_entry.valid_until.nil? || future_entry.valid_until.as(UInt64) > utc }
          report_dst_table_empty(force: previous_entry_present && entry.nil?)
        end
      end

      private def report_dst_table_empty(force : Bool = false) : Nil
        if !force && (last = @last_dst_empty) && Time.instant - last < DST_TABLE_EMPTY_MIN_INTERVAL
          return
        end
        @last_dst_empty = Time.instant
        emit_event(EVENT_DST_TABLE_EMPTY, DstTableEmptyEvent.new)
      end
    end
  end
end

require "./time_synchronization/sntp_client"
