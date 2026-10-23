require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Energy Preference (0x009B). A device advertises one or both
    # preference scales; controllers select a persisted index into each scale.
    class EnergyPreference < Base
      cluster 0x009B, revision: 1

      feature :energy_balance, bit: 0
      feature :low_power_mode_sensitivity, bit: 1

      MIN_BALANCES                 =      2
      MAX_BALANCES                 =     10
      MIN_STEP                     =   0_u8
      MAX_STEP                     = 100_u8
      MAX_LABEL_BYTES              =     64
      PRIORITY_COUNT               =      2
      SUPPORTED_FEATURES           = Feature::EnergyBalance.value | Feature::LowPowerModeSensitivity.value
      PERSISTED_ENERGY_STEP_KEY    = "selected_energy_step"
      PERSISTED_LOW_POWER_STEP_KEY = "selected_low_power_step"

      enum EnergyPriority : UInt8
        Comfort          = 0
        Speed            = 1
        Efficiency       = 2
        WaterConsumption = 3
      end

      struct Balance
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter step : UInt8

        @[TLV::Field(tag: 1, optional: true)]
        getter label : String?

        def initialize(@step : UInt8, @label : String? = nil)
        end
      end

      attribute 0x0000, :energy_balances, Array(Balance), default: [] of Balance,
        fixed: true, requires: :energy_balance, copy_on_assign: true,
        validate: :validate_energy_balances!
      attribute 0x0001, :current_energy_balance, UInt8, default: 0_u8,
        writable: true, write_access: :operate, persist: true,
        requires: :energy_balance, validate: :validate_current_energy_balance!
      attribute 0x0002, :energy_priorities, Array(EnergyPriority), default: [] of EnergyPriority,
        fixed: true, requires: :energy_balance, copy_on_assign: true,
        validate: :validate_priorities!
      attribute 0x0003, :low_power_mode_sensitivities, Array(Balance), default: [] of Balance,
        fixed: true, requires: :low_power_mode_sensitivity, copy_on_assign: true,
        validate: :validate_low_power_mode_sensitivities!
      attribute 0x0004, :current_low_power_mode_sensitivity, UInt8, default: 0_u8,
        writable: true, write_access: :operate, persist: true,
        requires: :low_power_mode_sensitivity, validate: :validate_current_low_power_mode_sensitivity!

      before_write :current_energy_balance do |index|
        InteractionModel::Status.constraint_error unless index < @energy_balances.size
      end

      before_write :current_low_power_mode_sensitivity do |index|
        InteractionModel::Status.constraint_error unless index < @low_power_mode_sensitivities.size
      end

      @restored_energy_step : UInt8? = nil
      @restored_low_power_step : UInt8? = nil

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::EnergyBalance,
                     energy_balances : Array(Balance) = [] of Balance,
                     energy_priorities : Array(EnergyPriority) = [] of EnergyPriority,
                     low_power_mode_sensitivities : Array(Balance) = [] of Balance,
                     current_energy_balance : UInt8 = 0_u8,
                     current_low_power_mode_sensitivity : UInt8 = 0_u8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        if (@feature_map.value & SUPPORTED_FEATURES).zero? || (@feature_map.value & ~SUPPORTED_FEATURES) != 0
          raise ArgumentError.new("Energy Preference requires BALA or LPMS and no unknown feature bits")
        end

        if @feature_map.energy_balance?
          validate_balances!(energy_balances, require_extremes: true)
          validate_priorities!(energy_priorities)
          raise ArgumentError.new("CurrentEnergyBalance is outside EnergyBalances") unless current_energy_balance < energy_balances.size
        elsif !energy_balances.empty? || !energy_priorities.empty? || current_energy_balance != 0
          raise ArgumentError.new("EnergyBalance configuration requires BALA")
        end

        if @feature_map.low_power_mode_sensitivity?
          validate_balances!(low_power_mode_sensitivities)
          unless current_low_power_mode_sensitivity < low_power_mode_sensitivities.size
            raise ArgumentError.new("CurrentLowPowerModeSensitivity is outside LowPowerModeSensitivities")
          end
        elsif !low_power_mode_sensitivities.empty? || current_low_power_mode_sensitivity != 0
          raise ArgumentError.new("LowPowerModeSensitivity configuration requires LPMS")
        end

        @energy_balances = energy_balances.dup
        @energy_priorities = energy_priorities.dup
        @low_power_mode_sensitivities = low_power_mode_sensitivities.dup
        @current_energy_balance = current_energy_balance
        @current_low_power_mode_sensitivity = current_low_power_mode_sensitivity
      end

      # A manufacturer may update a fixed scale as its capabilities change.
      # Keep the user's extreme preference and choose the nearest step for an
      # intermediate selection.
      def update_energy_balances(balances : Array(Balance)) : Nil
        raise ArgumentError.new("EnergyBalance requires BALA") unless @feature_map.energy_balance?
        validate_balances!(balances, require_extremes: true)
        previous_index = @current_energy_balance
        previous_step = @energy_balances[previous_index].step
        next_index = if previous_index.zero?
                       0
                     elsif previous_index == @energy_balances.size - 1
                       balances.size - 1
                     else
                       balances.each_index.min_by { |index| (balances[index].step.to_i - previous_step.to_i).abs }
                     end
        @current_energy_balance = next_index.to_u8
        self.energy_balances = balances
        increment_version_and_notify(ATTR_CURRENT_ENERGY_BALANCE) if previous_index != @current_energy_balance
      end

      def update_low_power_mode_sensitivities(balances : Array(Balance)) : Nil
        raise ArgumentError.new("LowPowerModeSensitivity requires LPMS") unless @feature_map.low_power_mode_sensitivity?
        validate_balances!(balances)
        previous_index = @current_low_power_mode_sensitivity
        previous_step = @low_power_mode_sensitivities[previous_index].step
        next_index = balances.each_index.min_by { |index| (balances[index].step.to_i - previous_step.to_i).abs }
        @current_low_power_mode_sensitivity = next_index.to_u8
        self.low_power_mode_sensitivities = balances
        increment_version_and_notify(ATTR_CURRENT_LOW_POWER_MODE_SENSITIVITY) if previous_index != @current_low_power_mode_sensitivity
      end

      def update_energy_priorities(priorities : Array(EnergyPriority)) : Nil
        raise ArgumentError.new("EnergyPriorities requires BALA") unless @feature_map.energy_balance?
        validate_priorities!(priorities)
        return if @energy_priorities == priorities
        self.energy_priorities = priorities
        self.current_energy_balance = 0_u8
      end

      private def validate_current_energy_balance!(index : UInt8) : Nil
        raise ArgumentError.new("CurrentEnergyBalance is outside EnergyBalances") unless index < @energy_balances.size
      end

      private def validate_energy_balances!(balances : Array(Balance)) : Nil
        validate_balances!(balances, require_extremes: true)
        raise ArgumentError.new("CurrentEnergyBalance is outside EnergyBalances") unless @current_energy_balance < balances.size
      end

      private def validate_current_low_power_mode_sensitivity!(index : UInt8) : Nil
        unless index < @low_power_mode_sensitivities.size
          raise ArgumentError.new("CurrentLowPowerModeSensitivity is outside LowPowerModeSensitivities")
        end
      end

      private def validate_low_power_mode_sensitivities!(balances : Array(Balance)) : Nil
        validate_balances!(balances)
        unless @current_low_power_mode_sensitivity < balances.size
          raise ArgumentError.new("CurrentLowPowerModeSensitivity is outside LowPowerModeSensitivities")
        end
      end

      private def validate_balances!(balances : Array(Balance), require_extremes : Bool = false) : Nil
        unless (MIN_BALANCES..MAX_BALANCES).includes?(balances.size)
          raise ArgumentError.new("preference scale must have 2 to 10 steps")
        end
        previous_step = nil.as(UInt8?)
        balances.each do |balance|
          unless (MIN_STEP..MAX_STEP).includes?(balance.step) &&
                 (previous_step.nil? || balance.step > previous_step.as(UInt8))
            raise ArgumentError.new("preference steps must increase from 0 to 100")
          end
          if (label = balance.label) && label.bytesize > MAX_LABEL_BYTES
            raise ArgumentError.new("preference label exceeds 64 bytes")
          end
          previous_step = balance.step
        end
        if require_extremes && (balances.first.step != MIN_STEP || balances.last.step != MAX_STEP)
          raise ArgumentError.new("EnergyBalances must start at 0 and end at 100")
        end
      end

      private def validate_priorities!(priorities : Array(EnergyPriority)) : Nil
        unless priorities.size == PRIORITY_COUNT && priorities.uniq.size == PRIORITY_COUNT
          raise ArgumentError.new("EnergyPriorities must contain two distinct priorities")
        end
      end

      private def after_restore_state : Nil
        if @feature_map.energy_balance?
          @current_energy_balance = if step = @restored_energy_step
                                      nearest_index(@energy_balances, step).to_u8
                                    elsif @current_energy_balance < @energy_balances.size
                                      @current_energy_balance
                                    else
                                      0_u8
                                    end
        end
        if @feature_map.low_power_mode_sensitivity?
          @current_low_power_mode_sensitivity = if step = @restored_low_power_step
                                                  nearest_index(@low_power_mode_sensitivities, step).to_u8
                                                elsif @current_low_power_mode_sensitivity < @low_power_mode_sensitivities.size
                                                  @current_low_power_mode_sensitivity
                                                else
                                                  0_u8
                                                end
        end
        @restored_energy_step = nil
        @restored_low_power_step = nil
      end

      private def nearest_index(balances : Array(Balance), step : UInt8) : Int32
        balances.each_index.min_by { |index| (balances[index].step.to_i - step.to_i).abs }
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        if @feature_map.energy_balance?
          document[PERSISTED_ENERGY_STEP_KEY] = @energy_balances[@current_energy_balance].step.to_i64
        end
        if @feature_map.low_power_mode_sensitivity?
          document[PERSISTED_LOW_POWER_STEP_KEY] = @low_power_mode_sensitivities[@current_low_power_mode_sensitivity].step.to_i64
        end
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        @restored_energy_step = persisted_step(document, PERSISTED_ENERGY_STEP_KEY)
        @restored_low_power_step = persisted_step(document, PERSISTED_LOW_POWER_STEP_KEY)
      end

      private def persisted_step(document : Storage::Document, key : String) : UInt8?
        value = document[key]?.as?(Int64)
        return unless value && (MIN_STEP.to_i64..MAX_STEP.to_i64).includes?(value)
        value.to_u8
      end
    end
  end
end
