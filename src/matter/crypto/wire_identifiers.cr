module Matter
  module Crypto
    module WireIdentifiers
      enum Sec1PointFormat : UInt8
        CompressedEven   = 0x02
        CompressedOdd    = 0x03
        Uncompressed     = 0x04
        IllegalSpecifier = 0x05
      end

      enum DerTag : UInt8
        Integer             = 0x02
        BitString           = 0x03
        OctetString         = 0x04
        Sequence            = 0x30
        Context0Constructed = 0xA0
        Context1Constructed = 0xA1
      end

      DER_NO_UNUSED_BITS    =    0_u8
      DER_LONG_FORM_FLAG    = 0x80_u8
      DER_LENGTH_VALUE_MASK = 0x7F_u8
    end
  end
end
