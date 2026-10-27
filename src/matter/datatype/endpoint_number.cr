require "./id"

module Matter
  module DataType
    define_id EndpointNumber, UInt16, number

    struct EndpointNumber
      ROOT = new(0_u16)
    end
  end
end
