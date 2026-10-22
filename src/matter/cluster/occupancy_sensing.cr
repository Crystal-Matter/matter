require "./cluster"

module Matter
  module Cluster
    # Occupancy Sensing Cluster (0x0406)
    #
    # Provides an interface to occupancy sensing functionality based on various sensing
    # modalities (PIR, Ultrasonic, Physical Contact, etc.), including configuration and
    # provision of notifications of occupancy status.
    #
    # Features:
    # - Other (OTHER): Other sensing modality
    # - PassiveInfrared (PIR): PIR sensing
    # - Ultrasonic (US): Ultrasonic sensing
    # - PhysicalContact (PHY): Physical contact sensing
    # - ActiveInfrared (AIR): Active IR sensing
    # - Radar (RADAR): Radar/microwave sensing
    # - RfSensing (RFSENS): RF signal analysis
    # - Vision (VIS): Vision-based sensing
    #
    # Matter 1.6 § 2.7. A device supplies occupancy readings after applying
    # its own sensing delays and thresholds; this cluster exposes their settings.
    class OccupancySensing < Base
      cluster 0x0406, revision: 7

      feature :other, bit: 0            # OTHER - Other sensing modality
      feature :passive_infrared, bit: 1 # PIR - PIR sensing
      feature :ultrasonic, bit: 2       # US - Ultrasonic sensing
      feature :physical_contact, bit: 3 # PHY - Physical contact sensing
      feature :active_infrared, bit: 4  # AIR - Active IR sensing
      feature :radar, bit: 5            # RADAR - Radar/microwave sensing
      feature :rf_sensing, bit: 6       # RFSENS - RF signal analysis
      feature :vision, bit: 7           # VIS - Vision-based sensing
      feature :occupancy_event, bit: 9  # OCCEVENT - OccupancyChanged events

      MODALITY_FEATURE_MASK = 0xFF_u32

      # Fixed limits apply whenever the optional HoldTime attribute is exposed.
      struct HoldTimeLimits
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter hold_time_min : UInt16

        @[TLV::Field(tag: 1)]
        getter hold_time_max : UInt16

        @[TLV::Field(tag: 2)]
        getter hold_time_default : UInt16

        def initialize(@hold_time_min : UInt16 = 1_u16,
                       @hold_time_max : UInt16 = 600_u16,
                       @hold_time_default : UInt16 = 60_u16)
          raise ArgumentError.new("hold_time_min must be at least 1") if @hold_time_min < 1
          minimum_max = Math.max(@hold_time_min, 10_u16)
          raise ArgumentError.new("hold_time_max must be at least #{minimum_max}") if @hold_time_max < minimum_max
          unless (@hold_time_min..@hold_time_max).includes?(@hold_time_default)
            raise ArgumentError.new("hold_time_default must be within hold time limits")
          end
        end
      end

      struct OccupancyChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter occupancy : UInt8

        def initialize(@occupancy : UInt8)
        end
      end

      # Occupancy sensor types (legacy enum)
      enum OccupancySensorType : UInt8
        PIR              = 0
        Ultrasonic       = 1
        PIRAndUltrasonic = 2
        PhysicalContact  = 3
      end

      # Occupancy bitmap (bit 0 = occupied)
      OCCUPANCY_OCCUPIED   = 0x01_u8
      OCCUPANCY_UNOCCUPIED = 0x00_u8

      # OccupancySensorTypeBitmap (bit 0 = PIR)
      SENSOR_TYPE_BITMAP_PIR              = 0x01_u8
      SENSOR_TYPE_BITMAP_ULTRASONIC       = 0x02_u8
      SENSOR_TYPE_BITMAP_PHYSICAL_CONTACT = 0x04_u8
      SENSOR_TYPE_BITMAP_MASK             = 0x07_u8

      # Specification defaults and limits of the per-modality delays and thresholds
      DEFAULT_DELAY     =  0_u16
      DEFAULT_THRESHOLD =   1_u8
      MIN_THRESHOLD     =   1_u8
      MAX_THRESHOLD     = 254_u8

      attribute 0x0000, :occupancy, UInt8, default: OCCUPANCY_UNOCCUPIED,
        max: OCCUPANCY_OCCUPIED, on_change: :report_occupancy_change
      attribute 0x0001, :occupancy_sensor_type, OccupancySensorType, default: OccupancySensorType::PIR, fixed: true,
        validate: :reject_fixed_attribute_change!
      attribute 0x0002, :occupancy_sensor_type_bitmap, UInt8, default: SENSOR_TYPE_BITMAP_PIR, fixed: true,
        validate: :reject_fixed_attribute_change!
      attribute 0x0003, :hold_time, UInt16, nullable: true, optional: true,
        writable: true, write_access: :manage, present_if: :hold_time,
        validate: :validate_hold_time, on_change: :sync_hold_time
      attribute 0x0004, :hold_time_limits, HoldTimeLimits,
        default: HoldTimeLimits.new, fixed: true, present_if: :hold_time,
        validate: :reject_fixed_attribute_change!

      attribute 0x0010, :pir_occupied_to_unoccupied_delay, UInt16,
        default: DEFAULT_DELAY, writable: true, write_access: :manage,
        optional: true, present_if: :pir_timing_supported?,
        validate: :validate_legacy_delay, on_change: :sync_legacy_hold_time
      attribute 0x0011, :pir_unoccupied_to_occupied_delay, UInt16, default: DEFAULT_DELAY, writable: true, write_access: :manage, optional: true, present_if: :pir_timing_supported?
      attribute 0x0012, :pir_unoccupied_to_occupied_threshold, UInt8, default: DEFAULT_THRESHOLD, writable: true, write_access: :manage, optional: true, min: MIN_THRESHOLD, max: MAX_THRESHOLD, present_if: :pir_timing_supported?

      attribute 0x0020, :ultrasonic_occupied_to_unoccupied_delay, UInt16,
        default: DEFAULT_DELAY, writable: true, write_access: :manage,
        optional: true, requires: :ultrasonic, present_if: :hold_time,
        validate: :validate_legacy_delay, on_change: :sync_legacy_hold_time
      attribute 0x0021, :ultrasonic_unoccupied_to_occupied_delay, UInt16, default: DEFAULT_DELAY, writable: true, write_access: :manage, optional: true, requires: :ultrasonic, present_if: :hold_time
      attribute 0x0022, :ultrasonic_unoccupied_to_occupied_threshold, UInt8, default: DEFAULT_THRESHOLD, writable: true, write_access: :manage, optional: true, min: MIN_THRESHOLD, max: MAX_THRESHOLD, requires: :ultrasonic, present_if: :hold_time

      attribute 0x0030, :physical_contact_occupied_to_unoccupied_delay, UInt16,
        default: DEFAULT_DELAY, writable: true, write_access: :manage,
        optional: true, requires: :physical_contact, present_if: :hold_time,
        validate: :validate_legacy_delay, on_change: :sync_legacy_hold_time
      attribute 0x0031, :physical_contact_unoccupied_to_occupied_delay, UInt16, default: DEFAULT_DELAY, writable: true, write_access: :manage, optional: true, requires: :physical_contact, present_if: :hold_time
      attribute 0x0032, :physical_contact_unoccupied_to_occupied_threshold, UInt8, default: DEFAULT_THRESHOLD, writable: true, write_access: :manage, optional: true, min: MIN_THRESHOLD, max: MAX_THRESHOLD, requires: :physical_contact, present_if: :hold_time

      event 0x00, :occupancy_changed, priority: :info, requires: :occupancy_event,
        payload: OccupancyChangedEvent

      before_write :hold_time do |value|
        if value.nil? || !(@hold_time_limits.hold_time_min..@hold_time_limits.hold_time_max).includes?(value)
          InteractionModel::Status.constraint_error
        end
      end

      before_write :pir_occupied_to_unoccupied_delay do |value|
        InteractionModel::Status.constraint_error unless valid_legacy_delay?(value)
      end

      before_write :ultrasonic_occupied_to_unoccupied_delay do |value|
        InteractionModel::Status.constraint_error unless valid_legacy_delay?(value)
      end

      before_write :physical_contact_occupied_to_unoccupied_delay do |value|
        InteractionModel::Status.constraint_error unless valid_legacy_delay?(value)
      end

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::PassiveInfrared,
                     @occupancy : UInt8 = OCCUPANCY_UNOCCUPIED,
                     occupancy_sensor_type : OccupancySensorType? = nil,
                     occupancy_sensor_type_bitmap : UInt8? = nil,
                     @hold_time : UInt16? = nil,
                     @hold_time_limits : HoldTimeLimits = HoldTimeLimits.new,
                     pir_occupied_to_unoccupied_delay : UInt16? = nil,
                     @pir_unoccupied_to_occupied_delay : UInt16 = DEFAULT_DELAY,
                     @pir_unoccupied_to_occupied_threshold : UInt8 = DEFAULT_THRESHOLD,
                     ultrasonic_occupied_to_unoccupied_delay : UInt16? = nil,
                     @ultrasonic_unoccupied_to_occupied_delay : UInt16 = DEFAULT_DELAY,
                     @ultrasonic_unoccupied_to_occupied_threshold : UInt8 = DEFAULT_THRESHOLD,
                     physical_contact_occupied_to_unoccupied_delay : UInt16? = nil,
                     @physical_contact_unoccupied_to_occupied_delay : UInt16 = DEFAULT_DELAY,
                     @physical_contact_unoccupied_to_occupied_threshold : UInt8 = DEFAULT_THRESHOLD)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        if (@feature_map.value & MODALITY_FEATURE_MASK).zero?
          raise ArgumentError.new("occupancy sensing requires at least one sensing modality")
        end
        sensor_bitmap = derived_sensor_type_bitmap
        @occupancy_sensor_type_bitmap = occupancy_sensor_type_bitmap || sensor_bitmap
        if @occupancy_sensor_type_bitmap > SENSOR_TYPE_BITMAP_MASK
          raise ArgumentError.new("occupancy_sensor_type_bitmap must use only PIR, Ultrasonic, and PhysicalContact bits")
        end
        @occupancy_sensor_type = occupancy_sensor_type ||
                                 case
                                 when (sensor_bitmap & SENSOR_TYPE_BITMAP_PIR) != 0 &&
                                      (sensor_bitmap & SENSOR_TYPE_BITMAP_ULTRASONIC) != 0
                                   OccupancySensorType::PIRAndUltrasonic
                                 when (sensor_bitmap & SENSOR_TYPE_BITMAP_PIR) != 0
                                   OccupancySensorType::PIR
                                 when (sensor_bitmap & SENSOR_TYPE_BITMAP_PHYSICAL_CONTACT) != 0
                                   OccupancySensorType::PhysicalContact
                                 when (sensor_bitmap & SENSOR_TYPE_BITMAP_ULTRASONIC) != 0
                                   OccupancySensorType::Ultrasonic
                                 else
                                   OccupancySensorType::PIR
                                 end
        raise ArgumentError.new("occupancy must be <= #{OCCUPANCY_OCCUPIED}") if @occupancy > OCCUPANCY_OCCUPIED
        if hold_time = @hold_time
          unless (@hold_time_limits.hold_time_min..@hold_time_limits.hold_time_max).includes?(hold_time)
            raise ArgumentError.new("hold_time must be within configured limits")
          end
          {pir_occupied_to_unoccupied_delay, ultrasonic_occupied_to_unoccupied_delay,
           physical_contact_occupied_to_unoccupied_delay}.each do |delay|
            if delay && delay != hold_time
              raise ArgumentError.new("legacy occupied-to-unoccupied delays must be equivalent to hold_time")
            end
          end
        end
        @pir_occupied_to_unoccupied_delay = pir_occupied_to_unoccupied_delay || @hold_time || DEFAULT_DELAY
        @ultrasonic_occupied_to_unoccupied_delay = ultrasonic_occupied_to_unoccupied_delay || @hold_time || DEFAULT_DELAY
        @physical_contact_occupied_to_unoccupied_delay = physical_contact_occupied_to_unoccupied_delay || @hold_time || DEFAULT_DELAY
        validate_threshold("pir_unoccupied_to_occupied_threshold", @pir_unoccupied_to_occupied_threshold)
        validate_threshold("ultrasonic_unoccupied_to_occupied_threshold", @ultrasonic_unoccupied_to_occupied_threshold)
        validate_threshold("physical_contact_unoccupied_to_occupied_threshold", @physical_contact_unoccupied_to_occupied_threshold)
      end

      # Reports a device-processed occupancy state. HoldTime remains optional.
      def update_occupancy(occupied : Bool) : Nil
        self.occupancy = occupied ? OCCUPANCY_OCCUPIED : OCCUPANCY_UNOCCUPIED
      end

      def occupied? : Bool
        (@occupancy & OCCUPANCY_OCCUPIED) != 0
      end

      private def pir_timing_supported? : Bool
        !@hold_time.nil? && (@feature_map.passive_infrared? ||
          (!@feature_map.ultrasonic? && !@feature_map.physical_contact?))
      end

      private def derived_sensor_type_bitmap : UInt8
        bitmap = 0_u8
        bitmap |= SENSOR_TYPE_BITMAP_PIR if @feature_map.passive_infrared?
        bitmap |= SENSOR_TYPE_BITMAP_ULTRASONIC if @feature_map.ultrasonic?
        bitmap |= SENSOR_TYPE_BITMAP_PHYSICAL_CONTACT if @feature_map.physical_contact?
        bitmap
      end

      private def reject_fixed_attribute_change!(_value) : Nil
        raise ArgumentError.new("fixed occupancy sensing attributes cannot change after construction")
      end

      private def validate_hold_time(value : UInt16?) : Nil
        return unless value
        return if (@hold_time_limits.hold_time_min..@hold_time_limits.hold_time_max).includes?(value)
        raise ArgumentError.new("hold_time must be within configured limits")
      end

      private def valid_legacy_delay?(value : UInt16) : Bool
        @hold_time.nil? || (@hold_time_limits.hold_time_min..@hold_time_limits.hold_time_max).includes?(value)
      end

      private def validate_legacy_delay(value : UInt16) : Nil
        return if valid_legacy_delay?(value)
        raise ArgumentError.new("legacy occupied-to-unoccupied delay must be within hold time limits")
      end

      private def sync_hold_time(value : UInt16?) : Nil
        return unless value
        self.pir_occupied_to_unoccupied_delay = value
        self.ultrasonic_occupied_to_unoccupied_delay = value
        self.physical_contact_occupied_to_unoccupied_delay = value
      end

      private def sync_legacy_hold_time(value : UInt16) : Nil
        self.hold_time = value unless @hold_time.nil?
      end

      private def after_restore_state : Nil
        if hold_time = @hold_time
          unless (@hold_time_limits.hold_time_min..@hold_time_limits.hold_time_max).includes?(hold_time)
            hold_time = @hold_time_limits.hold_time_default
            @hold_time = hold_time
          end
          @pir_occupied_to_unoccupied_delay = hold_time
          @ultrasonic_occupied_to_unoccupied_delay = hold_time
          @physical_contact_occupied_to_unoccupied_delay = hold_time
        end
      end

      private def report_occupancy_change(value : UInt8) : Nil
        emit_occupancy_changed(OccupancyChangedEvent.new(value)) if @feature_map.occupancy_event?
      end

      private def validate_threshold(name : String, threshold : UInt8) : Nil
        return if (MIN_THRESHOLD..MAX_THRESHOLD).includes?(threshold)
        raise ArgumentError.new("#{name} must be between #{MIN_THRESHOLD} and #{MAX_THRESHOLD}")
      end
    end
  end
end
