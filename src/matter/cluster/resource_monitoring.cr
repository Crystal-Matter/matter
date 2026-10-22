require "./cluster"

module Matter
  module Cluster
    # Shared Matter 1.6 types for HEPA, activated-carbon and water-tank
    # resource monitoring. The XML defines one schema with three cluster IDs.
    module ResourceMonitoring
      MAX_CONDITION              = 100_u8
      MAX_REPLACEMENT_PRODUCTS   =      5
      MAX_PRODUCT_IDENTIFIER_LEN =     20

      enum ChangeIndication : UInt8
        Ok       = 0
        Warning  = 1
        Critical = 2
      end

      enum DegradationDirection : UInt8
        Up   = 0
        Down = 1
      end

      enum ProductIdentifierType : UInt8
        Upc    = 0
        Gtin8  = 1
        Ean    = 2
        Gtin14 = 3
        Oem    = 4
      end

      struct ReplacementProduct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter product_identifier_type : ProductIdentifierType

        @[TLV::Field(tag: 1)]
        getter product_identifier_value : String

        def initialize(@product_identifier_type : ProductIdentifierType,
                       @product_identifier_value : String)
          if @product_identifier_value.bytesize > MAX_PRODUCT_IDENTIFIER_LEN
            raise ArgumentError.new("replacement product identifier exceeds 20 bytes")
          end
        end
      end
    end

    # Each concrete cluster gets its own DSL declarations and wire identity.
    macro define_resource_monitoring(name, id)
      class {{ name }} < Base
        cluster {{ id }}, revision: 1

        feature :condition, bit: 0
        feature :warning, bit: 1
        feature :replacement_product_list, bit: 2

        attribute 0x0000, :condition, UInt8, default: ResourceMonitoring::MAX_CONDITION,
          requires: :condition, max: ResourceMonitoring::MAX_CONDITION, validate: :validate_condition!
        attribute 0x0001, :degradation_direction, ResourceMonitoring::DegradationDirection,
          default: ResourceMonitoring::DegradationDirection::Down, fixed: true, requires: :condition,
          validate: :reject_fixed_attribute_change!
        attribute 0x0002, :change_indication, ResourceMonitoring::ChangeIndication,
          default: ResourceMonitoring::ChangeIndication::Ok, validate: :validate_indication!
        attribute 0x0003, :in_place_indicator, Bool, default: true,
          optional: true, present_if: :in_place_indicator_supported?
        attribute 0x0004, :last_changed_time, UInt32, nullable: true, writable: true,
          write_access: :operate, persist: true, optional: true,
          present_if: :last_changed_time_supported?
        attribute 0x0005, :replacement_product_list, Array(ResourceMonitoring::ReplacementProduct),
          default: [] of ResourceMonitoring::ReplacementProduct, fixed: true,
          requires: :replacement_product_list, validate: :reject_fixed_attribute_change!

        command 0x00, :reset_condition, access: :operate, optional: true,
          present_if: :reset_condition_supported?

        @reset_condition_callback : Proc(InteractionModel::Status)?

        def initialize(endpoint_id : DataType::EndpointNumber,
                       @feature_map : Feature = Feature::None,
                       condition : UInt8? = nil,
                       @degradation_direction : ResourceMonitoring::DegradationDirection = ResourceMonitoring::DegradationDirection::Down,
                       @change_indication : ResourceMonitoring::ChangeIndication = ResourceMonitoring::ChangeIndication::Ok,
                       @in_place_indicator : Bool = true,
                       @in_place_indicator_supported : Bool = false,
                       @last_changed_time : UInt32? = nil,
                       @last_changed_time_supported : Bool = false,
                       @replacement_product_list : Array(ResourceMonitoring::ReplacementProduct) = [] of ResourceMonitoring::ReplacementProduct,
                       @reset_condition_supported : Bool = false)
          super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
          if !@feature_map.condition? && condition
            raise ArgumentError.new("Condition requires the Condition feature")
          end
          @condition = condition || full_condition
          validate_condition!(@condition)
          validate_indication!(@change_indication)
          # Resource Monitoring 2.8.6.6 requires each replacement-product
          # struct to be unique; the XML also limits this list to five.
          if @replacement_product_list.size > ResourceMonitoring::MAX_REPLACEMENT_PRODUCTS ||
             @replacement_product_list.uniq.size != @replacement_product_list.size
            raise ArgumentError.new("ReplacementProductList must have at most five unique entries")
          end
          if !@feature_map.replacement_product_list? && !@replacement_product_list.empty?
            raise ArgumentError.new("ReplacementProductList requires its feature")
          end
          @replacement_product_list = @replacement_product_list.dup
          raise ArgumentError.new("LastChangedTime requires attribute support") if @last_changed_time && !@last_changed_time_supported
        end

        # The list has fixed quality. Return a copy so host code cannot
        # mutate the advertised value without validation or notification.
        def replacement_product_list : Array(ResourceMonitoring::ReplacementProduct)
          @replacement_product_list.dup
        end

        def in_place_indicator_supported? : Bool
          @in_place_indicator_supported
        end

        def last_changed_time_supported? : Bool
          @last_changed_time_supported
        end

        def reset_condition_supported?(_command_id : UInt32 = CMD_RESET_CONDITION) : Bool
          @reset_condition_supported
        end

        # The host reports a new resource assessment. Validate the complete
        # report before changing either visible attribute.
        def update_resource(condition : UInt8, indication : ResourceMonitoring::ChangeIndication) : Nil
          raise ArgumentError.new("Condition feature is absent") unless @feature_map.condition?
          validate_condition!(condition)
          validate_indication!(indication)
          self.condition = condition
          self.change_indication = indication
        end

        def update_change_indication(indication : ResourceMonitoring::ChangeIndication) : Nil
          validate_indication!(indication)
          self.change_indication = indication
        end

        # The host must confirm that the physical resource was replaced or
        # refilled before this command reports success. LastChangedTime is
        # intentionally left to the host or controller; automatic time update
        # is optional in the specification.
        def on_reset_condition(&block : -> InteractionModel::Status) : Nil
          @reset_condition_callback = block
        end

        def reset_condition : InteractionModel::Status
          return InteractionModel::Status.invalid_in_state unless callback = @reset_condition_callback
          status = callback.call
          return status unless status.success?
          self.condition = full_condition if @feature_map.condition?
          self.change_indication = ResourceMonitoring::ChangeIndication::Ok
          status
        end

        private def full_condition : UInt8
          @degradation_direction.up? ? 0_u8 : ResourceMonitoring::MAX_CONDITION
        end

        private def reject_fixed_attribute_change!(_value) : Nil
          raise ArgumentError.new("fixed resource attributes cannot change after construction")
        end

        private def validate_condition!(value : UInt8) : Nil
          raise ArgumentError.new("Condition exceeds 100 percent") if value > ResourceMonitoring::MAX_CONDITION
        end

        private def validate_indication!(value : ResourceMonitoring::ChangeIndication) : Nil
          unless {ResourceMonitoring::ChangeIndication::Ok, ResourceMonitoring::ChangeIndication::Warning,
                  ResourceMonitoring::ChangeIndication::Critical}.includes?(value)
            raise ArgumentError.new("Unknown ChangeIndication")
          end
          if value.warning? && !@feature_map.warning?
            raise ArgumentError.new("Warning indication requires Warning feature")
          end
        end
      end
    end

    define_resource_monitoring HepaFilterMonitoring, 0x0071
    define_resource_monitoring ActivatedCarbonFilterMonitoring, 0x0072
    define_resource_monitoring WaterTankLevelMonitoring, 0x0079
  end
end
