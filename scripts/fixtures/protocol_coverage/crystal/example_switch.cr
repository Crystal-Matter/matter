module Matter
  module Cluster
    class ExampleSwitch < Base
      # attribute 0x0006, :commented_out, UInt8, default: 0_u8
      cluster 0x1234, revision: 2

      attribute 0x0000, :required, UInt8, default: 0_u8
      attribute 0x0003, :always_required, UInt8,
        default: 0_u8
      attribute 0x0007, :declared_optional, UInt8,
        default: 0_u8, optional: true
    end
  end
end
