require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Meter Identification (0x0B06). All values are supplied by
    # the metering application and exposed as read-only attributes.
    class MeterIdentification < Base
      cluster 0x0B06, revision: 1

      feature :power_threshold, bit: 0

      MAX_IDENTIFIER_LENGTH = 64

      enum MeterType : UInt8
        Utility = 0
        Private = 1
        Generic = 2
      end

      enum PowerThresholdSource : UInt8
        Contract  = 0
        Regulator = 1
        Equipment = 2
      end

      struct PowerThreshold
        include TLV::Serializable

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

      attribute 0x0000, :meter_type, MeterType, nullable: true, fixed: true
      attribute 0x0001, :point_of_delivery, String, nullable: true, fixed: true,
        max_length: MAX_IDENTIFIER_LENGTH, validate: :validate_identifier!
      attribute 0x0002, :meter_serial_number, String, nullable: true, fixed: true,
        max_length: MAX_IDENTIFIER_LENGTH, validate: :validate_identifier!
      attribute 0x0003, :protocol_version, String, nullable: true, fixed: true,
        optional: true, present_if: :protocol_version_supported?,
        max_length: MAX_IDENTIFIER_LENGTH, validate: :validate_identifier!
      attribute 0x0004, :power_threshold, PowerThreshold, nullable: true, fixed: true,
        requires: :power_threshold

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @meter_type : MeterType? = nil,
                     @point_of_delivery : String? = nil,
                     @meter_serial_number : String? = nil,
                     @protocol_version : String? = nil,
                     @power_threshold : PowerThreshold? = nil,
                     @protocol_version_supported : Bool = false)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_identifier!(@point_of_delivery)
        validate_identifier!(@meter_serial_number)
        validate_identifier!(@protocol_version)
        @protocol_version_supported ||= !@protocol_version.nil?
        if @power_threshold && !@feature_map.power_threshold?
          raise ArgumentError.new("PowerThreshold value requires PowerThreshold feature")
        end
      end

      def protocol_version_supported? : Bool
        @protocol_version_supported
      end

      private def validate_identifier!(value : String?) : Nil
        if value && value.bytesize > MAX_IDENTIFIER_LENGTH
          raise ArgumentError.new("meter identifier exceeds #{MAX_IDENTIFIER_LENGTH} UTF-8 octets")
        end
      end
    end
  end
end
