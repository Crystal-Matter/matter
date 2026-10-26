require "./cluster"

module Matter
  module Cluster
    # Time Format Localization Cluster (0x002C)
    #
    # Provides attributes for determining and configuring time and date formatting
    # information that a node uses when conveying values to a user. This cluster
    # supports both hour format (12hr/24hr) and calendar format preferences.
    #
    # Features:
    # - CalendarFormat (CALFMT): Calendar format support
    #
    # Specification: Matter 1.4 § 11.4
    class TimeFormatLocalization < Base
      cluster 0x002C, revision: 1

      feature :calendar_format, bit: 0 # CALFMT - Calendar format support

      # Hour format values
      enum HourFormat : UInt8
        Hr12            =   0 # 12-hour clock
        Hr24            =   1 # 24-hour clock
        UseActiveLocale = 255 # Use active locale clock
      end

      # Calendar type values
      enum CalendarType : UInt8
        Buddhist        =   0
        Chinese         =   1
        Coptic          =   2
        Ethiopian       =   3
        Gregorian       =   4
        Hebrew          =   5
        Indian          =   6
        Islamic         =   7
        Japanese        =   8
        Korean          =   9
        Persian         =  10
        Taiwanese       =  11
        UseActiveLocale = 255
      end

      attribute 0x0000, :hour_format, HourFormat, default: HourFormat::Hr24, writable: true, write_access: :manage
      attribute 0x0001, :active_calendar_type, CalendarType, nullable: true, writable: true, write_access: :manage, requires: :calendar_format
      attribute 0x0002, :supported_calendar_types, Array(CalendarType), nullable: true, fixed: true, requires: :calendar_format

      # ActiveCalendarType is not nullable and must be a supported calendar
      before_write :active_calendar_type do |calendar|
        if calendar.nil?
          InteractionModel::Status.invalid_data_type
        elsif !supported_calendar?(calendar)
          InteractionModel::Status.constraint_error
        end
      end

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @hour_format : HourFormat = HourFormat::Hr24,
                     @active_calendar_type : CalendarType? = nil,
                     @supported_calendar_types : Array(CalendarType)? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        return unless @feature_map.calendar_format?

        if (active = @active_calendar_type) && !supported_calendar?(active)
          raise ArgumentError.new("active_calendar_type must be in supported_calendar_types")
        end

        if (supported = @supported_calendar_types) && supported.size != supported.uniq.size
          raise ArgumentError.new("supported_calendar_types must not contain duplicates")
        end
      end

      def calendar_format_enabled? : Bool
        @feature_map.calendar_format?
      end

      # Called with the previous and the new value whenever ActiveCalendarType changes
      def on_calendar_changed(&block : CalendarType?, CalendarType? -> Nil) : Nil
        on_active_calendar_type_changed(&block)
      end

      # Any calendar is acceptable until the supported list is configured
      private def supported_calendar?(calendar : CalendarType) : Bool
        (supported = @supported_calendar_types) ? supported.includes?(calendar) : true
      end
    end
  end
end
