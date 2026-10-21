require "./cluster"

module Matter
  module Cluster
    # Power Source Cluster (0x002F)
    #
    # Provides attributes and events for determining detailed information about power sources
    # present on a node, such as batteries or wired power.
    #
    # Features:
    # - Wired (WIRED): Wired power source
    # - Battery (BAT): Battery power source
    # - Rechargeable (RECHG): Rechargeable battery
    # - Replaceable (REPLC): Replaceable battery
    #
    # Note: Wired and Battery features are mutually exclusive.
    #
    # Specification: Matter 1.6 Power Source cluster
    class PowerSource < Base
      cluster 0x002F, revision: 3

      feature :wired, bit: 0        # WIRED - Wired power source
      feature :battery, bit: 1      # BAT - Battery power source
      feature :rechargeable, bit: 2 # RECHG - Rechargeable battery
      feature :replaceable, bit: 3  # REPLC - Replaceable battery
      conflicts :wired, :battery

      # Description strings are at most 60 characters; BatPercentRemaining
      # is in half-percent units (0..200).
      DESCRIPTION_MAX_LENGTH    =  60
      BAT_PERCENT_REMAINING_MAX = 200

      # Power source status values
      enum PowerSourceStatus : UInt8
        Unspecified = 0 # Status is not specified
        Active      = 1 # Source is available and currently supplying power
        Standby     = 2 # Source is available but not currently supplying power
        Unavailable = 3 # Source is not currently available to supply power
      end

      # Wired current type values
      enum WiredCurrentType : UInt8
        AC = 0 # Alternating current
        DC = 1 # Direct current
      end

      # Battery charge level values (coarse ranking)
      enum BatChargeLevel : UInt8
        Ok       = 0 # Charge level is nominal
        Warning  = 1 # Charge level is low, intervention may soon be required
        Critical = 2 # Charge level is critical, immediate intervention is required
      end

      # Battery replaceability values
      enum BatReplaceability : UInt8
        Unspecified        = 0 # Replaceability is unspecified or unknown
        NotReplaceable     = 1 # Battery is not replaceable
        UserReplaceable    = 2 # Battery is replaceable by the user or customer
        FactoryReplaceable = 3 # Battery is replaceable by an authorized factory technician
      end

      # Battery charge state values
      enum BatChargeState : UInt8
        Unknown        = 0 # Charge state is unknown
        IsCharging     = 1 # Battery is charging
        IsAtFullCharge = 2 # Battery is at full charge
        IsNotCharging  = 3 # Battery is not charging
      end

      # Base attributes
      attribute 0x0000, :status, PowerSourceStatus, default: PowerSourceStatus::Active
      attribute 0x0001, :order, UInt8, default: 0_u8
      attribute 0x0002, :description, String, default: "Battery", fixed: true

      # Feature attributes. Those without a default are present exactly when
      # the device supplied a value.
      attribute 0x0003, :wired_assessed_input_voltage, UInt32, nullable: true, optional: true, omit_changes: true, requires: :wired, present_if: :wired_assessed_input_voltage
      attribute 0x0004, :wired_assessed_input_frequency, UInt16, nullable: true, optional: true, omit_changes: true, requires: :wired, present_if: :wired_assessed_input_frequency
      attribute 0x0005, :wired_current_type, WiredCurrentType, default: WiredCurrentType::AC, fixed: true, requires: :wired
      attribute 0x0009, :wired_present, Bool, nullable: true, optional: true, requires: :wired, present_if: :wired_present

      attribute 0x000B, :bat_voltage, UInt32, nullable: true, optional: true, omit_changes: true, requires: :battery, present_if: :bat_voltage
      attribute 0x000C, :bat_percent_remaining, UInt8, nullable: true, optional: true, max: BAT_PERCENT_REMAINING_MAX, requires: :battery, present_if: :bat_percent_remaining
      attribute 0x000D, :bat_time_remaining, UInt32, nullable: true, optional: true, requires: :battery, present_if: :bat_time_remaining
      attribute 0x000E, :bat_charge_level, BatChargeLevel, nullable: true, requires: :battery, present_if: :bat_charge_level
      attribute 0x000F, :bat_replacement_needed, Bool, nullable: true, requires: :battery, present_if: :bat_replacement_needed
      attribute 0x0010, :bat_replaceability, BatReplaceability, nullable: true, fixed: true, requires: :battery, present_if: :bat_replaceability
      attribute 0x0011, :bat_present, Bool, nullable: true, optional: true, requires: :battery, present_if: :bat_present

      attribute 0x0013, :bat_replacement_description, String, nullable: true, fixed: true, requires: :replaceable, present_if: :bat_replacement_description
      attribute 0x0019, :bat_quantity, UInt8, nullable: true, fixed: true, requires: :replaceable, present_if: :bat_quantity

      attribute 0x001A, :bat_charge_state, BatChargeState, nullable: true, optional: true, requires: :rechargeable, present_if: :bat_charge_state
      attribute 0x001B, :bat_time_to_full_charge, UInt32, nullable: true, optional: true, requires: :rechargeable, present_if: :bat_time_to_full_charge
      attribute 0x001C, :bat_functional_while_charging, Bool, nullable: true, optional: true, requires: :rechargeable, present_if: :bat_functional_while_charging

      # The endpoint numbers powered by this source are required on every
      # Power Source instance, regardless of its feature map.
      attribute 0x001F, :endpoint_list, Array(UInt16), default: [] of UInt16

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::Battery,
                     @status : PowerSourceStatus = PowerSourceStatus::Active,
                     @order : UInt8 = 0_u8,
                     @description : String = "Battery",
                     # Wired feature
                     @wired_assessed_input_voltage : UInt32? = nil,
                     @wired_assessed_input_frequency : UInt16? = nil,
                     @wired_current_type : WiredCurrentType = WiredCurrentType::AC,
                     @wired_present : Bool? = nil,
                     # Battery feature
                     @bat_voltage : UInt32? = nil,
                     @bat_percent_remaining : UInt8? = nil,
                     @bat_time_remaining : UInt32? = nil,
                     @bat_charge_level : BatChargeLevel? = nil,
                     @bat_replacement_needed : Bool? = nil,
                     @bat_replaceability : BatReplaceability? = nil,
                     @bat_present : Bool? = nil,
                     # Replaceable feature
                     @bat_replacement_description : String? = nil,
                     @bat_quantity : UInt8? = nil,
                     # Rechargeable feature
                     @bat_charge_state : BatChargeState? = nil,
                     @bat_time_to_full_charge : UInt32? = nil,
                     @bat_functional_while_charging : Bool? = nil,
                     @endpoint_list : Array(UInt16) = [] of UInt16)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        raise ArgumentError.new("endpoint_list must not contain duplicates") unless @endpoint_list.uniq.size == @endpoint_list.size
        @endpoint_list = @endpoint_list.dup

        raise ArgumentError.new("description must be <= #{DESCRIPTION_MAX_LENGTH} characters") if @description.size > DESCRIPTION_MAX_LENGTH

        if desc = @bat_replacement_description
          raise ArgumentError.new("bat_replacement_description must be <= #{DESCRIPTION_MAX_LENGTH} characters") if desc.size > DESCRIPTION_MAX_LENGTH
        end

        # A feature's mandatory attributes are supplied together or not at all
        if @feature_map.battery?
          battery_attrs = [@bat_charge_level, @bat_replacement_needed, @bat_replaceability]
          if battery_attrs.any?(Nil) && battery_attrs.any?(&.!=(nil))
            raise ArgumentError.new("Battery feature requires bat_charge_level, bat_replacement_needed, and bat_replaceability")
          end
        end

        if @feature_map.replaceable? && !@feature_map.battery?
          raise ArgumentError.new("Replaceable feature requires Battery feature")
        end

        if @feature_map.replaceable?
          replaceable_attrs = [@bat_replacement_description, @bat_quantity]
          if replaceable_attrs.any?(Nil) && replaceable_attrs.any?(&.!=(nil))
            raise ArgumentError.new("Replaceable feature requires bat_replacement_description and bat_quantity")
          end
        end

        if @feature_map.rechargeable? && !@feature_map.battery?
          raise ArgumentError.new("Rechargeable feature requires Battery feature")
        end
      end

      # Update the remaining battery percentage (0-200 half-percent units,
      # nil = unknown) and report the change to subscribed controllers.
      def update_bat_percent_remaining(value : UInt8?)
        return unless @feature_map.battery?

        if percent = value
          raise ArgumentError.new("bat_percent_remaining must be <= #{BAT_PERCENT_REMAINING_MAX}") if percent > BAT_PERCENT_REMAINING_MAX
        end

        self.bat_percent_remaining = value
      end

      # Update battery charge level
      def update_bat_charge_level(level : BatChargeLevel)
        return unless @feature_map.battery?

        self.bat_charge_level = level
      end

      # Update battery replacement needed status
      def update_bat_replacement_needed(needed : Bool)
        return unless @feature_map.battery?

        self.bat_replacement_needed = needed
      end

      # Update the endpoints supplied by this source when the node's power
      # mapping changes. Copy the caller's list before storing it.
      def update_endpoint_list(endpoints : Array(UInt16)) : Nil
        raise ArgumentError.new("endpoint_list must not contain duplicates") unless endpoints.uniq.size == endpoints.size
        self.endpoint_list = endpoints.dup
      end

      # Check if Battery feature is enabled (for backward compatibility)
      def battery_feature_enabled? : Bool
        @feature_map.battery?
      end

      # Check if Replaceable feature is enabled (for backward compatibility)
      def replaceable_feature_enabled? : Bool
        @feature_map.replaceable?
      end

      # Called with the previous and the new value when the charge level changes
      def on_charge_level_changed(&block : BatChargeLevel?, BatChargeLevel? -> Nil) : Nil
        on_bat_charge_level_changed(&block)
      end

      # Called with the previous and the new value when replacement-needed changes
      def on_replacement_needed_changed(&block : Bool?, Bool? -> Nil) : Nil
        on_bat_replacement_needed_changed(&block)
      end
    end
  end
end
