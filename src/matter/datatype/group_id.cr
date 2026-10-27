require "./id"

module Matter
  module DataType
    define_id GroupId, UInt16

    struct GroupId
      RESERVED = new(0_u16)
    end
  end
end
