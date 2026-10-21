require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Matter 1.6 Time Synchronization (0x0038). This base server accepts an
    # administrator's UTC time and advances it using a monotonic clock. It
    # starts unsynchronized on every boot; optional TZ/NTP/TSC features are
    # deliberately absent until a platform supplies their services.
    class TimeSynchronization < Base
      cluster 0x0038, revision: 2

      TIME_NOT_ACCEPTED         = 0x02_u8
      TIME_FAILURE_MIN_INTERVAL = 1.hour

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

      struct TimeFailureEvent
        include TLV::Serializable

        def initialize
        end
      end

      attribute 0x0000, :utc_time, UInt64, computed: true, nullable: true, omit_changes: true
      attribute 0x0001, :granularity, Granularity, default: Granularity::NoTime
      attribute 0x0002, :time_source, TimeSource, default: TimeSource::None

      event 0x0003, :time_failure, priority: :info
      command 0x0000, :set_utc_time, request: SetUtcTimeRequest, access: :administer, handler: :apply_utc_time

      @base_utc_time : UInt64?
      @base_instant : Time::Instant?
      @last_time_failure : Time::Instant?

      def initialize(endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16))
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @base_utc_time = nil
        @base_instant = nil
        @last_time_failure = nil
      end

      def utc_time : UInt64?
        base = @base_utc_time
        started = @base_instant
        return unless base && started
        elapsed = (Time.instant - started).total_microseconds.to_u64
        return if elapsed > UInt64::MAX - base
        base + elapsed
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
        InteractionModel::Status.success
      end

      def report_time_failure : Bytes?
        @base_utc_time = nil
        @base_instant = nil
        self.granularity = Granularity::NoTime
        self.time_source = TimeSource::None
        increment_version_and_notify(ATTR_UTC_TIME)
        if last = @last_time_failure
          return if Time.instant - last < TIME_FAILURE_MIN_INTERVAL
        end
        @last_time_failure = Time.instant
        payload = TimeFailureEvent.new
        emit_event(EVENT_TIME_FAILURE, payload)
        payload.to_slice
      end
    end
  end
end
