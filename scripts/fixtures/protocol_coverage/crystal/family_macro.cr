module Family
  macro define_member(name, id)
    class {{ name }}
      cluster {{ id }}, revision: 2
      attribute 0x0000, :shared, UInt8
      attribute 0x0001, :optional, UInt8,
        optional: true
    end
  end

  define_member First, 0x1237
  define_member Second, 0x1238
end
