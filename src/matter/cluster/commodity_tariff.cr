require "../datatype/commodity"
require "./cluster"
require "digest/sha256"

module Matter
  module Cluster
    # Matter 1.6 Commodity Tariff (0x0700), revision 1. The provider publishes
    # a validated calendar; this cluster serves lookup and active projections.
    class CommodityTariff < Base
      cluster 0x0700, revision: 1

      feature :pricing, bit: 0
      feature :friendly_credit, bit: 1
      feature :auxiliary_load, bit: 2
      feature :peak_period, bit: 3
      feature :power_threshold, bit: 4
      feature :randomization, bit: 5

      alias TariffUnit = DataType::TariffUnit
      alias TariffPriceType = DataType::TariffPriceType

      MAX_LABEL_BYTES        =             128
      MAX_DAY_ENTRIES        =             672
      MAX_DAY_PATTERNS       =              28
      MAX_CALENDAR_PERIODS   =               4
      MAX_INDIVIDUAL_DAYS    =              50
      MAX_COMPONENTS         =             672
      MAX_TARIFF_PERIODS     =             672
      MAX_DAY_IDS            =              96
      MAX_PERIOD_IDS         =              20
      MAX_DAYS_PER_PERIOD    =               7
      MAX_DAY_START_MINUTES  =       1_499_u16
      MAX_DAY_MINUTES        =       1_500_u16
      SECONDS_PER_DAY        =      86_400_u32
      SECONDS_PER_MINUTE     =          60_u32
      MATTER_EPOCH_UNIX      = 946_684_800_i64
      ALL_WEEKDAYS           =         0x7F_u8
      ROTATION_START_KEY     = "immediate_rotation_start_date"
      RANDOMIZATION_SEED_KEY = "randomization_seed"

      enum BlockMode : UInt8
        NoBlock    = 0
        Combined   = 1
        Individual = 2
      end

      enum DayType : UInt8
        Standard = 0
        Holiday  = 1
        Dynamic  = 2
        Event    = 3
      end

      enum PeakPeriodSeverity : UInt8
        Unused = 0
        Low    = 1
        Medium = 2
        High   = 3
      end

      enum AuxiliaryLoadSetting : UInt8
        Off  = 0
        On   = 1
        None = 2
      end

      enum PowerThresholdSource : UInt8
        Contract  = 0
        Regulator = 1
        Equipment = 2
      end

      enum DayEntryRandomizationType : UInt8
        None           = 0
        Fixed          = 1
        Random         = 2
        RandomPositive = 3
        RandomNegative = 4
      end

      struct Currency
        # The shared DataType::Currency has the same wire fields, but tariff
        # information is persisted through Storage::Record as a nested value.
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter currency : UInt16

        @[TLV::Field(tag: 1)]
        getter decimal_points : UInt8

        def initialize(@currency : UInt16, @decimal_points : UInt8)
        end
      end

      struct TariffInformation
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: false)]
        getter tariff_label : String?

        @[TLV::Field(tag: 1, optional: false)]
        getter provider_name : String?

        @[TLV::Field(tag: 2, optional: true)]
        getter currency : Currency?

        @[TLV::Field(tag: 3, optional: false)]
        getter block_mode : BlockMode?

        def initialize(@tariff_label : String?, @provider_name : String?,
                       @currency : Currency?, @block_mode : BlockMode?)
        end
      end

      struct DayEntry
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter day_entry_id : UInt32

        @[TLV::Field(tag: 1)]
        getter start_time : UInt16

        @[TLV::Field(tag: 2, optional: true)]
        getter duration : UInt16?

        @[TLV::Field(tag: 3, optional: true)]
        getter randomization_offset : Int16?

        @[TLV::Field(tag: 4, optional: true)]
        getter randomization_type : DayEntryRandomizationType?

        def initialize(@day_entry_id : UInt32, @start_time : UInt16, @duration : UInt16? = nil,
                       @randomization_offset : Int16? = nil,
                       @randomization_type : DayEntryRandomizationType? = nil)
        end
      end

      struct DayPattern
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter day_pattern_id : UInt32

        @[TLV::Field(tag: 1)]
        getter days_of_week : UInt8

        @[TLV::Field(tag: 2)]
        @day_entry_ids : Array(UInt32)

        def initialize(@day_pattern_id : UInt32, @days_of_week : UInt8,
                       day_entry_ids : Array(UInt32))
          @day_entry_ids = day_entry_ids.dup
        end

        def day_entry_ids : Array(UInt32)
          @day_entry_ids.dup
        end
      end

      struct CalendarPeriod
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: false)]
        getter start_date : UInt32?

        @[TLV::Field(tag: 1)]
        @day_pattern_ids : Array(UInt32)

        def initialize(@start_date : UInt32?, day_pattern_ids : Array(UInt32))
          @day_pattern_ids = day_pattern_ids.dup
        end

        def day_pattern_ids : Array(UInt32)
          @day_pattern_ids.dup
        end
      end

      struct Day
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter date : UInt32

        @[TLV::Field(tag: 1)]
        getter day_type : DayType

        @[TLV::Field(tag: 2)]
        @day_entry_ids : Array(UInt32)

        def initialize(@date : UInt32, @day_type : DayType, day_entry_ids : Array(UInt32))
          @day_entry_ids = day_entry_ids.dup
        end

        def day_entry_ids : Array(UInt32)
          @day_entry_ids.dup
        end
      end

      struct TariffPrice
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter price_type : TariffPriceType

        @[TLV::Field(tag: 1, optional: true)]
        getter price : Int64?

        @[TLV::Field(tag: 2, optional: true)]
        getter price_level : Int16?

        def initialize(@price_type : TariffPriceType,
                       @price : Int64? = nil, @price_level : Int16? = nil)
        end
      end

      struct PeakPeriod
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter severity : PeakPeriodSeverity

        @[TLV::Field(tag: 1)]
        getter period : UInt16

        def initialize(@severity : PeakPeriodSeverity, @period : UInt16)
        end
      end

      struct AuxiliaryLoadSwitchSettings
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter number : UInt8

        @[TLV::Field(tag: 1)]
        getter required_state : AuxiliaryLoadSetting

        def initialize(@number : UInt8, @required_state : AuxiliaryLoadSetting)
        end
      end

      struct PowerThreshold
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: true)]
        getter power_threshold : Int64?

        @[TLV::Field(tag: 1, optional: true)]
        getter apparent_power_threshold : Int64?

        @[TLV::Field(tag: 2, optional: false)]
        getter power_threshold_source : PowerThresholdSource?

        def initialize(@power_threshold : Int64? = nil,
                       @apparent_power_threshold : Int64? = nil,
                       @power_threshold_source : PowerThresholdSource? = nil)
        end
      end

      struct TariffComponent
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter tariff_component_id : UInt32

        @[TLV::Field(tag: 1, optional: true)]
        getter price : TariffPrice?

        @[TLV::Field(tag: 2, optional: true)]
        getter friendly_credit : Bool?

        @[TLV::Field(tag: 3, optional: true)]
        getter auxiliary_load : AuxiliaryLoadSwitchSettings?

        @[TLV::Field(tag: 4, optional: true)]
        getter peak_period : PeakPeriod?

        @[TLV::Field(tag: 5, optional: true)]
        getter power_threshold : PowerThreshold?

        @[TLV::Field(tag: 6, optional: false)]
        getter threshold : Int64?

        @[TLV::Field(tag: 7, optional: true)]
        getter label : String?

        @[TLV::Field(tag: 8, optional: true)]
        getter predicted : Bool?

        def initialize(@tariff_component_id : UInt32, @price : TariffPrice?,
                       @threshold : Int64?, @label : String? = nil,
                       @predicted : Bool? = nil, @friendly_credit : Bool? = nil,
                       @peak_period : PeakPeriod? = nil,
                       @auxiliary_load : AuxiliaryLoadSwitchSettings? = nil,
                       @power_threshold : PowerThreshold? = nil)
        end
      end

      struct TariffPeriod
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: false)]
        getter label : String?

        @[TLV::Field(tag: 1)]
        @day_entry_ids : Array(UInt32)

        @[TLV::Field(tag: 2)]
        @tariff_component_ids : Array(UInt32)

        def initialize(@label : String?, day_entry_ids : Array(UInt32),
                       tariff_component_ids : Array(UInt32))
          @day_entry_ids = day_entry_ids.dup
          @tariff_component_ids = tariff_component_ids.dup
        end

        def day_entry_ids : Array(UInt32)
          @day_entry_ids.dup
        end

        def tariff_component_ids : Array(UInt32)
          @tariff_component_ids.dup
        end
      end

      struct GetTariffComponentRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter tariff_component_id : UInt32

        def initialize(@tariff_component_id : UInt32)
        end
      end

      struct GetTariffComponentResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter label : String?

        @[TLV::Field(tag: 1)]
        @day_entry_ids : Array(UInt32)

        @[TLV::Field(tag: 2)]
        getter tariff_component : TariffComponent

        def initialize(@label : String?, day_entry_ids : Array(UInt32),
                       @tariff_component : TariffComponent)
          @day_entry_ids = day_entry_ids.dup
        end

        def day_entry_ids : Array(UInt32)
          @day_entry_ids.dup
        end
      end

      struct GetDayEntryRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter day_entry_id : UInt32

        def initialize(@day_entry_id : UInt32)
        end
      end

      struct GetDayEntryResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter day_entry : DayEntry

        def initialize(@day_entry : DayEntry)
        end
      end

      # A host supplies an entire publication so references can be validated
      # before any visible attribute changes.
      struct Publication
        getter info : TariffInformation
        getter unit : TariffUnit?
        getter start_date : UInt32?
        getter day_entries : Array(DayEntry)
        getter day_patterns : Array(DayPattern)
        getter calendar_periods : Array(CalendarPeriod)
        getter individual_days : Array(Day)
        getter components : Array(TariffComponent)
        getter tariff_periods : Array(TariffPeriod)
        getter default_randomization_offset : Int16?
        getter default_randomization_type : DayEntryRandomizationType?

        def initialize(@info : TariffInformation, @unit : TariffUnit?,
                       @start_date : UInt32?, @day_entries : Array(DayEntry),
                       @day_patterns : Array(DayPattern),
                       @calendar_periods : Array(CalendarPeriod),
                       @individual_days : Array(Day),
                       @components : Array(TariffComponent),
                       @tariff_periods : Array(TariffPeriod),
                       @default_randomization_offset : Int16? = nil,
                       @default_randomization_type : DayEntryRandomizationType? = nil)
        end
      end

      attribute 0x0000, :tariff_info, TariffInformation, nullable: true, persist: true
      attribute 0x0001, :tariff_unit, TariffUnit, nullable: true, persist: true
      attribute 0x0002, :start_date, UInt32, nullable: true, persist: true
      attribute 0x0003, :day_entries, Array(DayEntry), nullable: true, persist: true,
        copy_on_assign: true, copy_on_read: true
      attribute 0x0004, :day_patterns, Array(DayPattern), nullable: true, persist: true,
        copy_on_assign: true, copy_on_read: true
      attribute 0x0005, :calendar_periods, Array(CalendarPeriod), nullable: true, persist: true,
        copy_on_assign: true, copy_on_read: true
      attribute 0x0006, :individual_days, Array(Day), nullable: true, persist: true,
        copy_on_assign: true, copy_on_read: true
      attribute 0x0007, :current_day, Day, nullable: true
      attribute 0x0008, :next_day, Day, nullable: true
      attribute 0x0009, :current_day_entry, DayEntry, nullable: true
      attribute 0x000A, :current_day_entry_date, UInt32, nullable: true
      attribute 0x000B, :next_day_entry, DayEntry, nullable: true
      attribute 0x000C, :next_day_entry_date, UInt32, nullable: true
      attribute 0x000D, :tariff_components, Array(TariffComponent), default: [] of TariffComponent,
        nullable: true, persist: true, copy_on_assign: true, copy_on_read: true
      attribute 0x000E, :tariff_periods, Array(TariffPeriod), default: [] of TariffPeriod,
        nullable: true, persist: true, copy_on_assign: true, copy_on_read: true
      attribute 0x000F, :current_tariff_components, Array(TariffComponent), default: [] of TariffComponent,
        nullable: true, copy_on_assign: true, copy_on_read: true
      attribute 0x0010, :next_tariff_components, Array(TariffComponent), nullable: true,
        copy_on_assign: true, copy_on_read: true
      attribute 0x0011, :default_randomization_offset, Int16, nullable: true,
        persist: true, persist_default: nil.as(Int16?), requires: :randomization
      attribute 0x0012, :default_randomization_type, DayEntryRandomizationType, nullable: true,
        persist: true, persist_default: nil.as(DayEntryRandomizationType?), requires: :randomization

      @immediate_rotation_start_date : UInt32? = nil
      @randomization_seed : UInt32? = nil

      command 0x00, :get_tariff_component, request: GetTariffComponentRequest,
        response: GetTariffComponentResponse, response_id: 0x00, access: :operate
      command 0x01, :get_day_entry, request: GetDayEntryRequest,
        response: GetDayEntryResponse, response_id: 0x01, access: :operate

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::Pricing,
                     @tariff_info : TariffInformation? = nil,
                     @tariff_unit : TariffUnit? = nil,
                     @start_date : UInt32? = nil,
                     @day_entries : Array(DayEntry)? = nil,
                     @day_patterns : Array(DayPattern)? = nil,
                     @calendar_periods : Array(CalendarPeriod)? = nil,
                     @individual_days : Array(Day)? = nil,
                     @tariff_components : Array(TariffComponent) = [] of TariffComponent,
                     @tariff_periods : Array(TariffPeriod) = [] of TariffPeriod)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map == Feature::Pricing ||
               @feature_map == Feature::FriendlyCredit ||
               @feature_map == Feature::AuxiliaryLoad ||
               @feature_map == (Feature::Pricing | Feature::FriendlyCredit) ||
               @feature_map == (Feature::Pricing | Feature::PeakPeriod) ||
               @feature_map == (Feature::Pricing | Feature::FriendlyCredit | Feature::PeakPeriod) ||
               @feature_map == (Feature::Pricing | Feature::AuxiliaryLoad) ||
               @feature_map == (Feature::Pricing | Feature::PowerThreshold) ||
               @feature_map == (Feature::Pricing | Feature::Randomization)
          raise ArgumentError.new("unsupported Commodity Tariff feature profile")
        end
      end

      protected def validate_feature_map_change(value : Feature) : Nil
        raise ArgumentError.new("Commodity Tariff feature profile is fixed after construction") unless value == @feature_map
      end

      def publish(publication : Publication, at : UInt32 = matter_now) : Nil
        validate_publication!(publication)
        @immediate_rotation_start_date = publication.start_date.nil? ? at - at % SECONDS_PER_DAY : nil
        @randomization_seed = Random::Secure.rand(UInt32) if @feature_map.randomization?
        self.tariff_info = publication.info
        self.tariff_unit = publication.unit
        self.default_randomization_offset = publication.default_randomization_offset
        self.default_randomization_type = publication.default_randomization_type
        self.start_date = publication.start_date
        self.day_entries = publication.day_entries
        self.day_patterns = publication.day_patterns
        self.calendar_periods = publication.calendar_periods
        self.individual_days = publication.individual_days
        self.tariff_components = publication.components
        self.tariff_periods = publication.tariff_periods
        refresh_at(at)
      end

      def clear_tariff : Nil
        @immediate_rotation_start_date = nil
        @randomization_seed = nil
        self.tariff_info = nil
        self.tariff_unit = nil
        self.default_randomization_offset = nil
        self.default_randomization_type = nil
        self.start_date = nil
        self.day_entries = nil
        self.day_patterns = nil
        self.calendar_periods = nil
        self.individual_days = nil
        self.tariff_components = [] of TariffComponent
        self.tariff_periods = [] of TariffPeriod
        clear_projections
      end

      # Matter epoch seconds in UTC. Hosts call this at publication and clock
      # boundaries; the example fixture refreshes it periodically.
      def refresh_at(at : UInt32) : Nil
        entries = @day_entries
        start = @start_date
        unless @tariff_info && entries && @day_patterns && @calendar_periods &&
               (start.nil? || at >= start)
          clear_projections
          return
        end
        if @feature_map.randomization?
          refresh_randomized_at(at)
          return
        end
        current_date = at - at % SECONDS_PER_DAY
        today = day_for(current_date, at)
        tomorrow_date = current_date + SECONDS_PER_DAY
        tomorrow = day_for(tomorrow_date, tomorrow_date)
        self.current_day = today
        self.next_day = tomorrow
        minute = (at - current_date) // SECONDS_PER_MINUTE
        current_entry = today.try do |day|
          ordered = day.day_entry_ids.compact_map { |id| entries.find { |entry| entry.day_entry_id == id } }
          ordered.reverse_each.find do |entry|
            entry.start_time <= minute &&
              (entry.duration.nil? || minute < entry.start_time + entry.duration.as(UInt16))
          end
        end
        next_entry = if today
                       today.day_entry_ids.compact_map { |id| entries.find { |entry| entry.day_entry_id == id } }
                         .find { |entry| entry.start_time > minute }
                     end
        next_date = current_date
        unless next_entry
          next_entry = tomorrow.try { |day| entries.find { |entry| entry.day_entry_id == day.day_entry_ids.first } }
          next_date = tomorrow_date
        end
        self.current_day_entry = current_entry
        self.current_day_entry_date = current_entry ? current_date + current_entry.start_time.to_u32 * SECONDS_PER_MINUTE : nil
        self.next_day_entry = next_entry
        self.next_day_entry_date = next_entry ? next_date + next_entry.start_time.to_u32 * SECONDS_PER_MINUTE : nil
        self.current_tariff_components = current_entry ? components_for(current_entry.day_entry_id) : [] of TariffComponent
        self.next_tariff_components = next_entry ? components_for(next_entry.day_entry_id) : nil
      end

      def get_tariff_component(request : GetTariffComponentRequest) : GetTariffComponentResponse | InteractionModel::Status
        component = @tariff_components.try(&.find { |item| item.tariff_component_id == request.tariff_component_id })
        return InteractionModel::Status.not_found unless component
        period = @tariff_periods.try(&.find { |item| item.tariff_component_ids.includes?(request.tariff_component_id) })
        return InteractionModel::Status.not_found unless period
        GetTariffComponentResponse.new(period.label, period.day_entry_ids, component)
      end

      def get_day_entry(request : GetDayEntryRequest) : GetDayEntryResponse | InteractionModel::Status
        entry = @day_entries.try(&.find { |item| item.day_entry_id == request.day_entry_id })
        return InteractionModel::Status.not_found unless entry
        GetDayEntryResponse.new(entry)
      end

      private struct ScheduledEntry
        getter start : Int64
        getter entry : DayEntry

        def initialize(@start : Int64, @entry : DayEntry)
        end
      end

      private def refresh_randomized_at(at : UInt32) : Nil
        current_date = at - at % SECONDS_PER_DAY
        schedule = [] of ScheduledEntry
        (-1..2).each do |day_shift|
          date = current_date.to_i64 + day_shift.to_i64 * SECONDS_PER_DAY.to_i64
          next unless (0_i64..UInt32::MAX.to_i64).includes?(date)
          day_date = date.to_u32
          day = day_for(day_date, day_date)
          next unless day
          day.day_entry_ids.each do |id|
            entry = @day_entries.as(Array(DayEntry)).find { |item| item.day_entry_id == id }
            next unless entry
            start = date + entry.start_time.to_i64 * SECONDS_PER_MINUTE.to_i64 + randomized_offset(entry, day_date)
            next unless (0_i64..UInt32::MAX.to_i64).includes?(start)
            schedule << ScheduledEntry.new(start, entry)
          end
        end
        schedule.sort_by!(&.start)
        previous = schedule.select { |item| item.start <= at.to_i64 }.last?
        following = schedule.find { |item| item.start > at.to_i64 }
        if previous && (duration = previous.entry.duration)
          previous = nil if previous.start + duration.to_i64 * SECONDS_PER_MINUTE.to_i64 <= at.to_i64
        end
        self.current_day = day_for(current_date, at)
        tomorrow_date = current_date.to_i64 + SECONDS_PER_DAY.to_i64
        self.next_day = tomorrow_date <= UInt32::MAX ? day_for(tomorrow_date.to_u32, tomorrow_date.to_u32) : nil
        self.current_day_entry = previous.try(&.entry)
        self.current_day_entry_date = previous.try(&.start.to_u32)
        self.next_day_entry = following.try(&.entry)
        self.next_day_entry_date = following.try(&.start.to_u32)
        self.current_tariff_components = previous ? components_for(previous.entry.day_entry_id) : [] of TariffComponent
        self.next_tariff_components = following ? components_for(following.entry.day_entry_id) : nil
      end

      private def randomized_offset(entry : DayEntry, date : UInt32) : Int32
        kind = entry.randomization_type || @default_randomization_type || DayEntryRandomizationType::None
        offset = entry.randomization_offset || @default_randomization_offset || 0_i16
        minimum, maximum = randomization_bounds(kind, offset)
        return minimum if minimum == maximum
        seed = @randomization_seed || raise StorageError.new("missing tariff randomization seed")
        digest = Digest::SHA256.hexdigest("#{seed}:#{date}:#{entry.day_entry_id}")
        sample = digest[0, 8].to_u32(16)
        minimum + (sample % (maximum - minimum + 1).to_u32).to_i32
      end

      private def randomization_bounds(kind : DayEntryRandomizationType, offset : Int16) : Tuple(Int32, Int32)
        value = offset.to_i32
        case kind
        when DayEntryRandomizationType::None
          {0, 0}
        when DayEntryRandomizationType::Fixed
          {value, value}
        when DayEntryRandomizationType::Random
          {-value, value}
        when DayEntryRandomizationType::RandomPositive
          {0, value}
        when DayEntryRandomizationType::RandomNegative
          {value, 0}
        else
          raise ArgumentError.new("invalid DayEntry randomization type")
        end
      end

      private def clear_projections : Nil
        self.current_day = nil
        self.next_day = nil
        self.current_day_entry = nil
        self.current_day_entry_date = nil
        self.next_day_entry = nil
        self.next_day_entry_date = nil
        self.current_tariff_components = [] of TariffComponent
        self.next_tariff_components = nil
      end

      private def components_for(day_entry_id : UInt32) : Array(TariffComponent)
        ids = (@tariff_periods || [] of TariffPeriod).select(&.day_entry_ids.includes?(day_entry_id))
          .flat_map(&.tariff_component_ids).uniq!
        (@tariff_components || [] of TariffComponent).select { |component| ids.includes?(component.tariff_component_id) }
      end

      private def day_for(date : UInt32, at : UInt32) : Day?
        return unless @calendar_periods.try(&.present?)
        period = @calendar_periods.as(Array(CalendarPeriod)).reverse.find do |item|
          item.start_date.nil? || item.start_date.as(UInt32) <= at
        end
        return unless period
        if overlay = @individual_days.try(&.find { |day| day.date == date })
          return overlay
        end
        weekday = Time.unix(MATTER_EPOCH_UNIX + date.to_i64).day_of_week.value % 7
        patterns = @day_patterns.as(Array(DayPattern))
        first_pattern = patterns.find { |item| item.day_pattern_id == period.day_pattern_ids.first }
        return unless first_pattern
        pattern = if first_pattern.days_of_week.zero?
                    anchor = period.start_date || @immediate_rotation_start_date
                    return unless anchor
                    anchor_date = anchor - anchor % SECONDS_PER_DAY
                    return if date < anchor_date
                    day_number = (date.to_u64 - anchor_date.to_u64) // SECONDS_PER_DAY
                    id = period.day_pattern_ids[(day_number % period.day_pattern_ids.size).to_i]
                    patterns.find { |item| item.day_pattern_id == id }
                  else
                    patterns.find do |item|
                      period.day_pattern_ids.includes?(item.day_pattern_id) &&
                        (item.days_of_week & (1_u8 << weekday)) != 0
                    end
                  end
        pattern.try { |item| Day.new(date, DayType::Standard, item.day_entry_ids) }
      end

      private def validate_publication!(publication : Publication) : Nil
        info = publication.info
        if @feature_map.randomization?
          validate_randomization!(publication.default_randomization_type || DayEntryRandomizationType::None,
            publication.default_randomization_offset || 0_i16)
        elsif publication.default_randomization_offset || publication.default_randomization_type
          raise ArgumentError.new("randomization defaults require Randomization feature")
        end
        [info.tariff_label, info.provider_name].each do |label|
          raise ArgumentError.new("tariff label exceeds 128 bytes") if label && label.bytesize > MAX_LABEL_BYTES
        end
        if @feature_map.pricing?
          currency = info.currency || raise ArgumentError.new("Pricing requires Currency")
          raise ArgumentError.new("currency code exceeds 999") if currency.currency > DataType::Currency::MAX_CODE
        elsif info.currency
          raise ArgumentError.new("Currency requires Pricing")
        end
        raise ArgumentError.new("calendar is empty") if publication.day_entries.empty? || publication.day_patterns.empty?
        check_size!("day entries", publication.day_entries.size, 1, MAX_DAY_ENTRIES)
        check_size!("day patterns", publication.day_patterns.size, 1, MAX_DAY_PATTERNS)
        check_size!("calendar periods", publication.calendar_periods.size, 1, MAX_CALENDAR_PERIODS)
        check_size!("individual days", publication.individual_days.size, 0, MAX_INDIVIDUAL_DAYS)
        check_size!("tariff components", publication.components.size, 1, MAX_COMPONENTS)
        check_size!("tariff periods", publication.tariff_periods.size, 1, MAX_TARIFF_PERIODS)
        entry_ids = publication.day_entries.map(&.day_entry_id)
        pattern_ids = publication.day_patterns.map(&.day_pattern_id)
        component_ids = publication.components.map(&.tariff_component_id)
        [entry_ids, pattern_ids, component_ids].each do |ids|
          raise ArgumentError.new("duplicate tariff identifier") if ids.uniq.size != ids.size
        end
        publication.day_entries.each do |entry|
          raise ArgumentError.new("day entry starts after day end") if entry.start_time > MAX_DAY_START_MINUTES
          if duration = entry.duration
            raise ArgumentError.new("day entry duration exceeds day end") if duration > MAX_DAY_MINUTES - entry.start_time
          end
          if @feature_map.randomization?
            validate_randomization!(entry.randomization_type || publication.default_randomization_type || DayEntryRandomizationType::None,
              entry.randomization_offset || publication.default_randomization_offset || 0_i16)
          elsif entry.randomization_offset || entry.randomization_type
            raise ArgumentError.new("day entry randomization requires Randomization feature")
          end
        end
        publication.day_patterns.each do |pattern|
          raise ArgumentError.new("invalid days of week") if pattern.days_of_week & ~ALL_WEEKDAYS != 0
          validate_entry_ids!(pattern.day_entry_ids, entry_ids, publication.day_entries,
            default_randomization_offset: publication.default_randomization_offset,
            default_randomization_type: publication.default_randomization_type)
        end
        dates = publication.calendar_periods.map(&.start_date)
        if dates.first.nil? != publication.start_date.nil?
          raise ArgumentError.new("first period null date must match StartDate")
        end
        dates.each_cons_pair do |previous, current|
          raise ArgumentError.new("calendar periods must increase") if current.nil? || (!previous.nil? && current <= previous)
        end
        publication.calendar_periods.each do |period|
          check_size!("period patterns", period.day_pattern_ids.size, 1, MAX_DAYS_PER_PERIOD)
          raise ArgumentError.new("missing day pattern") unless period.day_pattern_ids.all? { |id| pattern_ids.includes?(id) }
          patterns = publication.day_patterns.select { |item| period.day_pattern_ids.includes?(item.day_pattern_id) }
          if patterns.any?(&.days_of_week.zero?)
            raise ArgumentError.new("rotating and weekday patterns cannot mix") unless patterns.all?(&.days_of_week.zero?)
            next
          end
          mask = 0_u8
          patterns.each do |pattern|
            raise ArgumentError.new("overlapping weekdays") if mask & pattern.days_of_week != 0
            mask |= pattern.days_of_week
          end
          raise ArgumentError.new("calendar does not cover every weekday") unless mask == ALL_WEEKDAYS
        end
        publication.individual_days.each do |day|
          raise ArgumentError.new("individual day date is not midnight") unless day.date % SECONDS_PER_DAY == 0
          validate_entry_ids!(day.day_entry_ids, entry_ids, publication.day_entries, day.day_type,
            publication.default_randomization_offset, publication.default_randomization_type)
        end
        days = publication.individual_days.map(&.date)
        raise ArgumentError.new("individual days must be sorted and unique") unless days == days.sort.uniq!
        publication.components.each do |component|
          if !@feature_map.pricing? && component.price
            raise ArgumentError.new("Price requires Pricing")
          end
          if price = component.price
            if price.price.nil? && price.price_level.nil?
              raise ArgumentError.new("price or price level is required")
            end
          elsif component.friendly_credit.nil? && component.peak_period.nil? &&
                component.auxiliary_load.nil? && component.power_threshold.nil?
            raise ArgumentError.new("price or price level is required")
          end
          if !@feature_map.friendly_credit? && !component.friendly_credit.nil?
            raise ArgumentError.new("FriendlyCredit field requires the FriendlyCredit feature")
          end
          if peak = component.peak_period
            raise ArgumentError.new("PeakPeriod field requires the PeakPeriod feature") unless @feature_map.peak_period?
            raise ArgumentError.new("PeakPeriod number must be at least one") if peak.period.zero?
          end
          if !@feature_map.auxiliary_load? && !component.auxiliary_load.nil?
            raise ArgumentError.new("AuxiliaryLoad field requires the AuxiliaryLoad feature")
          end
          if !@feature_map.power_threshold? && !component.power_threshold.nil?
            raise ArgumentError.new("PowerThreshold field requires the PowerThreshold feature")
          end
          if label = component.label
            raise ArgumentError.new("component label exceeds 128 bytes") if label.bytesize > MAX_LABEL_BYTES
          end
        end
        owned_entry_ids = [] of UInt32
        publication.tariff_periods.each do |period|
          raise ArgumentError.new("period label exceeds 128 bytes") if period.label.try(&.bytesize).try(&.>(MAX_LABEL_BYTES))
          check_size!("period day entries", period.day_entry_ids.size, 1, MAX_PERIOD_IDS)
          check_size!("period components", period.tariff_component_ids.size, 1, MAX_PERIOD_IDS)
          raise ArgumentError.new("unknown day entry") unless period.day_entry_ids.all? { |id| entry_ids.includes?(id) }
          raise ArgumentError.new("unknown component") unless period.tariff_component_ids.all? { |id| component_ids.includes?(id) }
          period.day_entry_ids.each do |id|
            raise ArgumentError.new("day entry belongs to multiple tariff periods") if owned_entry_ids.includes?(id)
            owned_entry_ids << id
          end
        end
        entry_ids.each do |entry_id|
          active_ids = publication.tariff_periods.select(&.day_entry_ids.includes?(entry_id))
            .flat_map(&.tariff_component_ids).uniq!
          check_size!("active tariff components", active_ids.size, 0, MAX_PERIOD_IDS)
        end
        raise ArgumentError.new("unreferenced component") unless component_ids.all? do |id|
                                                                   publication.tariff_periods.any?(&.tariff_component_ids.includes?(id))
                                                                 end
      end

      private def validate_entry_ids!(ids : Array(UInt32), all_ids : Array(UInt32),
                                      entries : Array(DayEntry), day_type : DayType = DayType::Standard,
                                      default_randomization_offset : Int16? = nil,
                                      default_randomization_type : DayEntryRandomizationType? = nil) : Nil
        check_size!("day entry IDs", ids.size, 1, MAX_DAY_IDS)
        raise ArgumentError.new("unknown day entry") unless ids.all? { |id| all_ids.includes?(id) }
        selected = ids.map { |id| entries.find { |entry| entry.day_entry_id == id }.as(DayEntry) }
        starts = selected.map(&.start_time)
        raise ArgumentError.new("day entries must increase by start time") unless starts == starts.sort.uniq!
        if @feature_map.randomization?
          selected.each_cons_pair do |previous, following|
            prior_type = previous.randomization_type || default_randomization_type || DayEntryRandomizationType::None
            prior_offset = previous.randomization_offset || default_randomization_offset || 0_i16
            next_type = following.randomization_type || default_randomization_type || DayEntryRandomizationType::None
            next_offset = following.randomization_offset || default_randomization_offset || 0_i16
            _, prior_latest = randomization_bounds(prior_type, prior_offset)
            next_earliest, _ = randomization_bounds(next_type, next_offset)
            prior_end = previous.start_time.to_i32 * SECONDS_PER_MINUTE.to_i32 + prior_latest
            next_start = following.start_time.to_i32 * SECONDS_PER_MINUTE.to_i32 + next_earliest
            raise ArgumentError.new("randomized day entries can overtake") if prior_end >= next_start
            if day_type.event? && (duration = previous.duration)
              raise ArgumentError.new("randomized event day entries overlap") if prior_end + duration.to_i32 * SECONDS_PER_MINUTE.to_i32 > next_start
            end
          end
        end
        if day_type.event?
          selected.each_cons_pair do |previous, following|
            if duration = previous.duration
              raise ArgumentError.new("event day entries overlap") if previous.start_time + duration > following.start_time
            end
          end
        else
          raise ArgumentError.new("first entry must start at midnight") unless starts.first == 0
          raise ArgumentError.new("non-event day has duration") if selected.any?(&.duration)
        end
      end

      private def validate_randomization!(kind : DayEntryRandomizationType, offset : Int16) : Nil
        if kind.random_negative?
          raise ArgumentError.new("RandomNegative offset must be nonpositive") if offset > 0
        elsif !kind.fixed?
          raise ArgumentError.new("randomization offset must be nonnegative") if offset < 0
        end
        randomization_bounds(kind, offset)
        nil
      end

      private def check_size!(name : String, size : Int32, minimum : Int32, maximum : Int32) : Nil
        raise ArgumentError.new("#{name} count out of bounds") unless (minimum..maximum).includes?(size)
      end

      private def matter_now : UInt32
        seconds = Time.utc.to_unix - MATTER_EPOCH_UNIX
        seconds.clamp(0_i64, UInt32::MAX.to_i64).to_u32
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        if anchor = @immediate_rotation_start_date
          document[ROTATION_START_KEY] = anchor.to_i64
        end
        if seed = @randomization_seed
          document[RANDOMIZATION_SEED_KEY] = seed.to_i64
        end
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        @immediate_rotation_start_date = nil
        @randomization_seed = nil
        if value = document[ROTATION_START_KEY]?
          anchor = value.as?(Int64)
          raise StorageError.new("invalid tariff rotation start date") unless anchor && (0_i64..UInt32::MAX.to_i64).includes?(anchor)
          @immediate_rotation_start_date = anchor.to_u32
        end
        if value = document[RANDOMIZATION_SEED_KEY]?
          seed = value.as?(Int64)
          raise StorageError.new("invalid tariff randomization seed") unless seed && (0_i64..UInt32::MAX.to_i64).includes?(seed)
          @randomization_seed = seed.to_u32
        end
        if @feature_map.randomization? && document["tariff_info"]? && !@randomization_seed
          raise StorageError.new("missing tariff randomization seed")
        end
      end

      private def after_restore_state : Nil
        refresh_at(matter_now)
      end
    end
  end
end
