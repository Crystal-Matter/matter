require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Laundry Dryer Controls (0x004A). The host supplies the
    # mode-dependent dryness levels and decides when remote writes are allowed.
    class LaundryDryerControls < Base
      cluster 0x004A, revision: 1

      MIN_DRYNESS_LEVELS = 1
      MAX_DRYNESS_LEVELS = 4

      enum DrynessLevel : UInt8
        Low    = 0
        Normal = 1
        Extra  = 2
        Max    = 3
      end

      attribute 0x0000, :supported_dryness_levels, Array(DrynessLevel),
        default: [] of DrynessLevel, validate: :validate_supported_dryness_levels!,
        copy_on_assign: true
      attribute 0x0001, :selected_dryness_level, DrynessLevel,
        nullable: true, writable: true, write_access: :operate,
        validate: :validate_selected_dryness_level!

      @select_dryness_callback : Proc(DrynessLevel?, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported_dryness_levels : Array(DrynessLevel),
                     @selected_dryness_level : DrynessLevel? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_supported_dryness_levels!(@supported_dryness_levels)
        validate_selected_dryness_level!(@selected_dryness_level)
        @supported_dryness_levels = @supported_dryness_levels.dup
      end

      def supported_dryness_levels : Array(DrynessLevel)
        @supported_dryness_levels.dup
      end

      # Returning a non-success status leaves the advertised selection alone.
      def on_select_dryness(&block : DrynessLevel? -> InteractionModel::Status) : Nil
        @select_dryness_callback = block
      end

      # The host calls this when its active dryer mode changes.
      def configure_mode(levels : Array(DrynessLevel), selected : DrynessLevel?) : Nil
        validate_dryness_configuration!(levels, selected)
        self.selected_dryness_level = nil unless levels.includes?(@selected_dryness_level)
        self.supported_dryness_levels = levels.dup
        self.selected_dryness_level = selected
      end

      before_write :selected_dryness_level do |level|
        if level && !@supported_dryness_levels.includes?(level)
          InteractionModel::Status.constraint_error
        elsif callback = @select_dryness_callback
          status = callback.call(level)
          status unless status.success?
        else
          InteractionModel::Status.invalid_in_state
        end
      end

      private def validate_dryness_configuration!(levels : Array(DrynessLevel), selected : DrynessLevel?) : Nil
        validate_dryness_levels_shape!(levels)
        raise ArgumentError.new("selected dryness level is unsupported") if selected && !levels.includes?(selected)
      end

      private def validate_supported_dryness_levels!(levels : Array(DrynessLevel)) : Nil
        validate_dryness_levels_shape!(levels)
        if @selected_dryness_level && !levels.includes?(@selected_dryness_level)
          raise ArgumentError.new("selected dryness level is unsupported")
        end
      end

      private def validate_dryness_levels_shape!(levels : Array(DrynessLevel)) : Nil
        unless (MIN_DRYNESS_LEVELS..MAX_DRYNESS_LEVELS).includes?(levels.size)
          raise ArgumentError.new("dryer needs one to four dryness levels")
        end
      end

      private def validate_selected_dryness_level!(level : DrynessLevel?) : Nil
        raise ArgumentError.new("selected dryness level is unsupported") if level && !@supported_dryness_levels.includes?(level)
      end

      private def after_restore_state : Nil
        self.selected_dryness_level = nil unless @selected_dryness_level.nil? || @supported_dryness_levels.includes?(@selected_dryness_level)
      end
    end
  end
end
