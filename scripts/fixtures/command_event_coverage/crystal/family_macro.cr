module Family
  macro define_member(name, id)
    class {{ name }}
      cluster {{ id }}, revision: 2
      command 0x00, :reset, requires: :test
      event 0x00, :started, priority: :info
    end
  end

  define_member First, 0x1235
  define_member Second, 0x1236
end
