require "../datatype/commodity"
require "./cluster"

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

      MAX_LABEL_BYTES       =             128
      MAX_DAY_ENTRIES       =             672
      MAX_DAY_PATTERNS      =              28
      MAX_CALENDAR_PERIODS  =               4
      MAX_INDIVIDUAL_DAYS   =              50
      MAX_COMPONENTS        =             672
      MAX_TARIFF_PERIODS    =             672
      MAX_DAY_IDS           =              96
      MAX_PERIOD_IDS        =              20
      MAX_DAYS_PER_PERIOD   =               7
      MAX_DAY_START_MINUTES =       1_499_u16
      MAX_DAY_MINUTES       =       1_500_u16
      SECONDS_PER_DAY       =      86_400_u32
      SECONDS_PER_MINUTE    =          60_u32
      MATTER_EPOCH_UNIX     = 946_684_800_i64
      ALL_WEEKDAYS          =         0x7F_u8

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

        @[TLV::Field(tag: 2, optional: false)]
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

        def initialize(@day_entry_id : UInt32, @start_time : UInt16, @duration : UInt16? = nil)
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

      struct TariffComponent
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter tariff_component_id : UInt32

        @[TLV::Field(tag: 1, optional: false)]
        getter price : TariffPrice?

        @[TLV::Field(tag: 6, optional: false)]
        getter threshold : Int64?

        @[TLV::Field(tag: 7, optional: true)]
        getter label : String?

        @[TLV::Field(tag: 8, optional: true)]
        getter predicted : Bool?

        def initialize(@tariff_component_id : UInt32, @price : TariffPrice?,
                       @threshold : Int64?, @label : String? = nil,
                       @predicted : Bool? = nil)
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
        getter unit : TariffUnit
        getter start_date : UInt32?
        getter day_entries : Array(DayEntry)
        getter day_patterns : Array(DayPattern)
        getter calendar_periods : Array(CalendarPeriod)
        getter individual_days : Array(Day)
        getter components : Array(TariffComponent)
        getter tariff_periods : Array(TariffPeriod)

        def initialize(@info : TariffInformation, @unit : TariffUnit,
                       @start_date : UInt32?, @day_entries : Array(DayEntry),
                       @day_patterns : Array(DayPattern),
                       @calendar_periods : Array(CalendarPeriod),
                       @individual_days : Array(Day),
                       @components : Array(TariffComponent),
                       @tariff_periods : Array(TariffPeriod))
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
        raise ArgumentError.new("only the Pricing feature is supported") unless @feature_map == Feature::Pricing
      end

      def publish(publication : Publication, at : UInt32 = matter_now) : Nil
        validate_publication!(publication)
        self.tariff_info = publication.info
        self.tariff_unit = publication.unit
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
        self.tariff_info = nil
        self.tariff_unit = nil
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
        pattern = @day_patterns.as(Array(DayPattern)).find do |item|
          period.day_pattern_ids.includes?(item.day_pattern_id) &&
            (item.days_of_week & (1_u8 << weekday)) != 0
        end
        pattern.try { |item| Day.new(date, DayType::Standard, item.day_entry_ids) }
      end

      private def validate_publication!(publication : Publication) : Nil
        info = publication.info
        [info.tariff_label, info.provider_name].each do |label|
          raise ArgumentError.new("tariff label exceeds 128 bytes") if label && label.bytesize > MAX_LABEL_BYTES
        end
        currency = info.currency
        raise ArgumentError.new("pricing requires currency") unless currency
        raise ArgumentError.new("currency code exceeds 999") if currency.currency > DataType::Currency::MAX_CODE
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
        end
        publication.day_patterns.each do |pattern|
          raise ArgumentError.new("rotating day patterns are not supported") if pattern.days_of_week == 0
          raise ArgumentError.new("invalid days of week") if pattern.days_of_week & ~ALL_WEEKDAYS != 0
          validate_entry_ids!(pattern.day_entry_ids, entry_ids, publication.day_entries)
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
          mask = 0_u8
          patterns.each do |pattern|
            raise ArgumentError.new("overlapping weekdays") if mask & pattern.days_of_week != 0
            mask |= pattern.days_of_week
          end
          raise ArgumentError.new("calendar does not cover every weekday") unless mask == ALL_WEEKDAYS
        end
        publication.individual_days.each do |day|
          raise ArgumentError.new("individual day date is not midnight") unless day.date % SECONDS_PER_DAY == 0
          validate_entry_ids!(day.day_entry_ids, entry_ids, publication.day_entries, day.day_type)
        end
        days = publication.individual_days.map(&.date)
        raise ArgumentError.new("individual days must be sorted and unique") unless days == days.sort.uniq!
        publication.components.each do |component|
          raise ArgumentError.new("price or price level is required") unless price = component.price
          if price.price.nil? && price.price_level.nil?
            raise ArgumentError.new("price or price level is required")
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
                                      entries : Array(DayEntry), day_type : DayType = DayType::Standard) : Nil
        check_size!("day entry IDs", ids.size, 1, MAX_DAY_IDS)
        raise ArgumentError.new("unknown day entry") unless ids.all? { |id| all_ids.includes?(id) }
        selected = ids.map { |id| entries.find { |entry| entry.day_entry_id == id }.as(DayEntry) }
        starts = selected.map(&.start_time)
        raise ArgumentError.new("day entries must increase by start time") unless starts == starts.sort.uniq!
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

      private def check_size!(name : String, size : Int32, minimum : Int32, maximum : Int32) : Nil
        raise ArgumentError.new("#{name} count out of bounds") unless (minimum..maximum).includes?(size)
      end

      private def matter_now : UInt32
        seconds = Time.utc.to_unix - MATTER_EPOCH_UNIX
        seconds.clamp(0_i64, UInt32::MAX.to_i64).to_u32
      end

      private def after_restore_state : Nil
        refresh_at(matter_now)
      end
    end
  end
end
