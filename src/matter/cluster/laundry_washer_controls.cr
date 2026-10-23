require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Laundry Washer Controls (0x0053). Supported options follow
    # the selected mode; the host decides whether a remote change is possible.
    class LaundryWasherControls < Base
      cluster 0x0053, revision: 2

      feature :spin, bit: 0
      feature :rinse, bit: 1

      MAX_SPIN_SPEEDS     =    16
      MAX_SPIN_LABEL_SIZE =    64
      MAX_RINSES          =     4
      MAX_SPIN_INDEX      = 15_u8

      enum NumberOfRinses : UInt8
        None   = 0
        Normal = 1
        Extra  = 2
        Max    = 3
      end

      attribute 0x0000, :spin_speeds, Array(String), default: [] of String,
        requires: :spin, validate: :validate_spin_speeds!, copy_on_assign: true
      attribute 0x0001, :spin_speed_current, UInt8, nullable: true,
        writable: true, write_access: :operate, requires: :spin,
        max: MAX_SPIN_INDEX, validate: :validate_spin_speed_current!
      attribute 0x0002, :number_of_rinses, NumberOfRinses,
        default: NumberOfRinses::None, writable: true, write_access: :operate,
        requires: :rinse, validate: :validate_number_of_rinses!
      attribute 0x0003, :supported_rinses, Array(NumberOfRinses),
        default: [] of NumberOfRinses, requires: :rinse,
        validate: :validate_supported_rinses!, copy_on_assign: true

      @select_spin_speed_callback : Proc(UInt8?, InteractionModel::Status)?
      @select_rinses_callback : Proc(NumberOfRinses, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature,
                     @spin_speeds : Array(String) = [] of String,
                     @spin_speed_current : UInt8? = nil,
                     @number_of_rinses : NumberOfRinses = NumberOfRinses::None,
                     @supported_rinses : Array(NumberOfRinses) = [] of NumberOfRinses)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("Laundry Washer Controls requires Spin or Rinse") unless @feature_map.spin? || @feature_map.rinse?
        if @feature_map.spin?
          validate_spin_speeds!(@spin_speeds)
          validate_spin_speed_current!(@spin_speed_current)
        elsif !@spin_speeds.empty? || @spin_speed_current
          raise ArgumentError.new("Spin feature is absent")
        end
        if @feature_map.rinse?
          validate_supported_rinses!(@supported_rinses)
          validate_number_of_rinses!(@number_of_rinses)
        elsif !@supported_rinses.empty? || @number_of_rinses != NumberOfRinses::None
          raise ArgumentError.new("Rinse feature is absent")
        end
        @spin_speeds = @spin_speeds.dup
        @supported_rinses = @supported_rinses.dup
        @configured_number_of_rinses = @number_of_rinses
      end

      def spin_speeds : Array(String)
        @spin_speeds.dup
      end

      def supported_rinses : Array(NumberOfRinses)
        @supported_rinses.dup
      end

      def on_select_spin_speed(&block : UInt8? -> InteractionModel::Status) : Nil
        @select_spin_speed_callback = block
      end

      def on_select_rinses(&block : NumberOfRinses -> InteractionModel::Status) : Nil
        @select_rinses_callback = block
      end

      # Update the options exposed by the currently selected washer mode.
      def configure_spin_mode(speeds : Array(String), current : UInt8?) : Nil
        raise ArgumentError.new("Spin feature is absent") unless @feature_map.spin?
        validate_spin_configuration!(speeds, current)
        self.spin_speed_current = nil if @spin_speed_current && @spin_speed_current.as(UInt8) >= speeds.size
        self.spin_speeds = speeds.dup
        self.spin_speed_current = current
      end

      def configure_rinse_mode(rinses : Array(NumberOfRinses), current : NumberOfRinses) : Nil
        raise ArgumentError.new("Rinse feature is absent") unless @feature_map.rinse?
        validate_rinse_configuration!(rinses, current)
        # The two attributes are one mode configuration. Set the selection
        # first so the list validator can keep the public invariant intact.
        old = @number_of_rinses
        @number_of_rinses = current
        self.supported_rinses = rinses.dup
        increment_version_and_notify(ATTR_NUMBER_OF_RINSES) if old != current
      end

      before_write :spin_speed_current do |index|
        if index && index >= @spin_speeds.size
          InteractionModel::Status.constraint_error
        elsif callback = @select_spin_speed_callback
          status = callback.call(index)
          status unless status.success?
        else
          InteractionModel::Status.invalid_in_state
        end
      end

      before_write :number_of_rinses do |rinses|
        if !@supported_rinses.includes?(rinses)
          InteractionModel::Status.constraint_error
        elsif callback = @select_rinses_callback
          status = callback.call(rinses)
          status unless status.success?
        else
          InteractionModel::Status.invalid_in_state
        end
      end

      private def validate_spin_configuration!(speeds : Array(String), current : UInt8?) : Nil
        validate_spin_labels!(speeds)
        raise ArgumentError.new("spin speed index is unsupported") if current && current >= speeds.size
      end

      private def validate_spin_speeds!(speeds : Array(String)) : Nil
        validate_spin_labels!(speeds)
        if @spin_speed_current && @spin_speed_current.as(UInt8) >= speeds.size
          raise ArgumentError.new("spin speed index is unsupported")
        end
      end

      private def validate_spin_labels!(speeds : Array(String)) : Nil
        if speeds.size > MAX_SPIN_SPEEDS || speeds.any? { |speed| speed.bytesize > MAX_SPIN_LABEL_SIZE }
          raise ArgumentError.new("SpinSpeeds allows at most sixteen labels of at most 64 bytes")
        end
      end

      private def validate_spin_speed_current!(index : UInt8?) : Nil
        raise ArgumentError.new("spin speed index is unsupported") if index && index >= @spin_speeds.size
      end

      private def validate_rinse_configuration!(rinses : Array(NumberOfRinses), current : NumberOfRinses) : Nil
        if rinses.empty? || rinses.size > MAX_RINSES || rinses.uniq.size != rinses.size || !rinses.includes?(current)
          raise ArgumentError.new("rinse selection must be one of one to four distinct supported values")
        end
      end

      private def validate_supported_rinses!(rinses : Array(NumberOfRinses)) : Nil
        validate_rinse_configuration!(rinses, @number_of_rinses)
      end

      private def validate_number_of_rinses!(rinses : NumberOfRinses) : Nil
        raise ArgumentError.new("rinse selection is unsupported") unless @supported_rinses.includes?(rinses)
      end

      private def after_restore_state : Nil
        if @feature_map.spin? && @spin_speed_current && @spin_speed_current.as(UInt8) >= @spin_speeds.size
          self.spin_speed_current = nil
        end
        if @feature_map.rinse? && !@supported_rinses.includes?(@number_of_rinses)
          self.number_of_rinses = @configured_number_of_rinses
        end
      end
    end
  end
end
