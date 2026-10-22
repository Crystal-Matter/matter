module Matter
  module DataType
    # Matter operational Vendor IDs exclude Common/Unspecified (0) and the
    # reserved range above the four test Vendor IDs.
    module VendorId
      OPERATIONAL_MINIMUM =      1_u16
      OPERATIONAL_MAXIMUM = 0xFFF4_u16

      def self.valid_operational?(value : UInt16) : Bool
        value >= OPERATIONAL_MINIMUM && value <= OPERATIONAL_MAXIMUM
      end
    end
  end
end
