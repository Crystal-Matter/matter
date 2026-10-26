require "./cluster"
require "log"
require "tlv"

module Matter
  module Cluster
    # Matter 1.6 Time Synchronization (0x0038). This base server accepts an
    # administrator's UTC time and advances it using a monotonic clock. It
    # starts unsynchronized on every boot. Hosts may opt into the TimeZone
    # feature without a time-zone database. The NTP and Trusted Time clients
    # are opt-in; trusted peer access is supplied by the device host. The
    # opt-in NTP server role needs a host-started SNTP UDP responder.
    class TimeSynchronization < Base
      Log = ::Log.for("matter.cluster.time_synchronization")

      cluster 0x0038, revision: 2, persist_state: false

      feature :time_zone, bit: 0
      feature :ntp_client, bit: 1
      feature :ntp_server, bit: 2
      feature :trusted_time_client, bit: 3

      TIME_NOT_ACCEPTED                 = 0x02_u8
      TIME_FAILURE_MIN_INTERVAL         = 1.hour
      DST_TABLE_EMPTY_MIN_INTERVAL      = 1.hour
      TIME_ZONE_OFFSET_MIN              = -43_200
      TIME_ZONE_OFFSET_MAX              =  50_400
      TIME_ZONE_NAME_MAX_BYTES          =      64
      TIME_ZONE_LIST_MAX_SIZE           =    2_u8
      DST_OFFSET_LIST_MAX_SIZE          =    4_u8
      DEFAULT_NTP_MAX_BYTES             =     128
      NTP_REFRESH_INTERVAL              = 1.hour
      TRUSTED_TIME_REFRESH_INTERVAL     = 1.hour
      MISSING_TRUSTED_TIME_MIN_INTERVAL = 1.hour
      MICROSECONDS_PER_SECOND           = 1_000_000_i128

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

      struct FabricScopedTrustedTimeSourceStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter node_id : UInt64
        @[TLV::Field(tag: 1)]
        getter endpoint : UInt16

        def initialize(@node_id : UInt64, @endpoint : UInt16)
        end
      end

      struct TrustedTimeSourceStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter fabric_index : UInt8
        @[TLV::Field(tag: 1)]
        getter node_id : UInt64
        @[TLV::Field(tag: 2)]
        getter endpoint : UInt16

        def initialize(@fabric_index : UInt8, @node_id : UInt64, @endpoint : UInt16)
        end
      end

      struct SetTrustedTimeSourceRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter trusted_time_source : FabricScopedTrustedTimeSourceStruct?

        def initialize(@trusted_time_source : FabricScopedTrustedTimeSourceStruct?)
        end
      end

      struct MissingTrustedTimeSourceEvent
        include TLV::Serializable

        def initialize
        end
      end

      record TrustedTimeSample, utc_time : UInt64, granularity : Granularity

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
        getter trusted_time_source : TrustedTimeSourceStruct?

        def initialize(@data_version, @features, @time_zone, @dst_offset, @default_ntp,
                       @trusted_time_source)
        end
      end

      attribute 0x0000, :utc_time, UInt64, computed: true, nullable: true, omit_changes: true
      attribute 0x0001, :granularity, Granularity, default: Granularity::NoTime
      attribute 0x0002, :time_source, TimeSource, default: TimeSource::None
      attribute 0x0003, :trusted_time_source, TrustedTimeSourceStruct,
        computed: true, nullable: true, requires: :trusted_time_client
      attribute 0x0004, :default_ntp, String, computed: true, nullable: true, requires: :ntp_client
      attribute 0x0005, :time_zone, Array(TimeZoneStruct), computed: true, requires: :time_zone
      attribute 0x0006, :dst_offset, Array(DstOffsetStruct), computed: true, requires: :time_zone
      attribute 0x0007, :local_time, UInt64, computed: true, nullable: true,
        omit_changes: true, requires: :time_zone
      attribute 0x0008, :time_zone_database, TimeZoneDatabase, computed: true,
        fixed: true, requires: :time_zone
      attribute 0x0009, :ntp_server_available, Bool, computed: true,
        requires: :ntp_server
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
      event 0x0004, :missing_trusted_time_source, priority: :info,
        requires: :trusted_time_client
      command 0x0000, :set_utc_time, request: SetUtcTimeRequest, access: :administer, handler: :apply_utc_time
      command 0x0001, :set_trusted_time_source, request: SetTrustedTimeSourceRequest,
        access: :administer, requires: :trusted_time_client, handler: :apply_trusted_time_source
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
      @trusted_time_source : TrustedTimeSourceStruct?
      @last_trusted_time_attempt : Time::Instant?
      @last_missing_trusted_time_source : Time::Instant?
      @ntp_server_bound : Bool
      property on_ntp_query : Proc(String, UInt64?)?
      property on_trusted_time_query : Proc(UInt8, UInt64, UInt16, TrustedTimeSample?)?

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
        @trusted_time_source = nil
        @last_trusted_time_attempt = nil
        @last_missing_trusted_time_source = nil
        @on_trusted_time_query = nil
        @ntp_server_bound = false
      end

      def utc_time : UInt64?
        utc_time_at(Time.instant)
      end

      # Matter epoch seconds for clusters whose timestamps use epoch-s.
      # An unset clock or a UTC value outside the epoch-s wire range is not usable.
      def matter_epoch_seconds : UInt32?
        utc = utc_time || return
        seconds = utc // MICROSECONDS_PER_SECOND
        return if seconds > UInt32::MAX
        seconds.to_u32
      end

      private def utc_time_at(now : Time::Instant) : UInt64?
        base = @base_utc_time
        started = @base_instant
        return unless base && started
        # A poll may refresh UTC after capturing `now`; that sample predates
        # the new monotonic baseline and has not elapsed any time against it.
        return base if now <= started
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

      def trusted_time_source : TrustedTimeSourceStruct?
        @trusted_time_source
      end

      def ntp_server_available? : Bool
        @ntp_server_bound && @granularity.value >= Granularity::Seconds.value &&
          SntpServer.representable_utc?(utc_time)
      end

      # A host NTP listener calls this after binding and before closing. The
      # attribute remains false while UTC is unavailable, even if bound.
      def report_ntp_server_bound(bound : Bool) : Nil
        previous = ntp_server_available?
        @ntp_server_bound = bound
        increment_version_and_notify(ATTR_NTP_SERVER_AVAILABLE) if previous != ntp_server_available?
      end

      def apply_trusted_time_source(request : SetTrustedTimeSourceRequest) : InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session? && (fabric_index = request_fabric_index)
        return InteractionModel::Status.unsupported_access unless (Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX).includes?(fabric_index)
        candidate = request.trusted_time_source
        if candidate && !(DataType::NodeId::OPERATIONAL_MINIMUM..DataType::NodeId::OPERATIONAL_MAXIMUM).includes?(candidate.node_id)
          return InteractionModel::Status.constraint_error
        end
        @trusted_time_source = candidate.try do |source|
          TrustedTimeSourceStruct.new(fabric_index, source.node_id, source.endpoint)
        end
        @last_trusted_time_attempt = nil
        increment_version_and_notify(ATTR_TRUSTED_TIME_SOURCE)
        emit_missing_trusted_time_source(force: true) unless candidate
        InteractionModel::Status.success
      end

      def remove_fabric(fabric_index : UInt8) : Nil
        return unless @trusted_time_source.try(&.fabric_index) == fabric_index
        @trusted_time_source = nil
        @last_trusted_time_attempt = nil
        increment_version_and_notify(ATTR_TRUSTED_TIME_SOURCE)
        emit_missing_trusted_time_source(force: true)
      end

      # Repairs an interrupted fabric removal before the device accepts CASE.
      def retain_fabrics(indices : Array(UInt8)) : Bool
        source = @trusted_time_source
        return false unless source
        return false if indices.includes?(source.fabric_index)
        remove_fabric(source.fabric_index)
        true
      end

      def refresh_from_trusted_time_source(now : Time::Instant = Time.instant) : Bool
        return false unless @feature_map.trusted_time_client?
        if last = @last_trusted_time_attempt
          return false if now - last < TRUSTED_TIME_REFRESH_INTERVAL
        end
        @last_trusted_time_attempt = now
        source = @trusted_time_source
        sample = begin
          if source && (query = @on_trusted_time_query)
            query.call(source.fabric_index, source.node_id, source.endpoint)
          end
        rescue error
          Log.warn(exception: error) { "Trusted time peer query failed" }
          nil
        end
        return false unless @trusted_time_source == source
        unless sample && sample.granularity != Granularity::NoTime
          emit_missing_trusted_time_source(now: now)
          report_time_failure if utc_time.nil? && (!@feature_map.ntp_client? || @default_ntp.nil? || @default_ntp.try(&.empty?))
          return false
        end
        status = apply_utc_time(SetUtcTimeRequest.new(sample.utc_time, sample.granularity))
        return false unless status.status == InteractionModel::StatusCode::Success
        self.time_source = TimeSource::NodeTimeCluster
        true
      end

      private def emit_missing_trusted_time_source(now : Time::Instant = Time.instant, force : Bool = false) : Nil
        if !force && (last = @last_missing_trusted_time_source)
          return if now - last < MISSING_TRUSTED_TIME_MIN_INTERVAL
        end
        @last_missing_trusted_time_source = now
        emit_event(EVENT_MISSING_TRUSTED_TIME_SOURCE, MissingTrustedTimeSourceEvent.new)
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
        trusted = refresh_from_trusted_time_source(now) if @feature_map.trusted_time_client?
        refresh_from_default_ntp(now) if @feature_map.ntp_client? && !trusted
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
        return unless @feature_map.time_zone? || @feature_map.ntp_client? || @feature_map.trusted_time_client?
        PersistedState.new(@data_version, @feature_map.value, @time_zone, @dst_offset,
          @default_ntp, @trusted_time_source).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        return unless @feature_map.time_zone? || @feature_map.ntp_client? || @feature_map.trusted_time_client?
        state = PersistedState.from_document(document)
        return if state.features != @feature_map.value
        if address = state.default_ntp
          raise StorageError.new("Invalid persisted DefaultNTP") if address.bytesize > DEFAULT_NTP_MAX_BYTES || !valid_default_ntp?(address)
        end
        raise StorageError.new("Invalid persisted TimeZone") unless valid_time_zones?(state.time_zone)
        raise StorageError.new("Invalid persisted DSTOffset") unless valid_dst_offsets?(state.dst_offset)
        if source = state.trusted_time_source
          unless (Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX).includes?(source.fabric_index) &&
                 (DataType::NodeId::OPERATIONAL_MINIMUM..DataType::NodeId::OPERATIONAL_MAXIMUM).includes?(source.node_id)
            raise StorageError.new("Invalid persisted TrustedTimeSource")
          end
        end
        @time_zone = state.time_zone.dup
        @dst_offset = state.dst_offset.dup
        @default_ntp = state.default_ntp
        @trusted_time_source = state.trusted_time_source
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

        was_ntp_available = ntp_server_available? if @feature_map.ntp_server?
        @base_utc_time = request.utc_time
        @base_instant = Time.instant
        self.granularity = request.granularity
        self.time_source = TimeSource::Admin
        increment_version_and_notify(ATTR_UTC_TIME)
        notify_ntp_server_availability(was_ntp_available) if @feature_map.ntp_server?
        if @feature_map.time_zone?
          notify_changed(ATTR_LOCAL_TIME)
          refresh_time_state(request.utc_time)
        end
        InteractionModel::Status.success
      end

      def report_time_failure : Bytes?
        was_ntp_available = ntp_server_available? if @feature_map.ntp_server?
        @base_utc_time = nil
        @base_instant = nil
        self.granularity = Granularity::NoTime
        self.time_source = TimeSource::None
        increment_version_and_notify(ATTR_UTC_TIME)
        notify_ntp_server_availability(was_ntp_available) if @feature_map.ntp_server?
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

      private def notify_ntp_server_availability(previous : Bool?) : Nil
        increment_version_and_notify(ATTR_NTP_SERVER_AVAILABLE) if previous != ntp_server_available?
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
require "./time_synchronization/sntp_server"
