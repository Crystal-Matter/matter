require "./cluster"

module Matter
  module Cluster
    # Every `Cluster::Base` subclass by its `CLUSTER_ID`.
    #
    # The table is collected at compile time from `Base.subclasses`, so a
    # cluster is registered by being defined and nothing runs at load time.
    # File-private subclasses (spec fakes) cannot be named from here and are
    # left out. Two classes claiming the same id is a programming error: the
    # first lookup raises `ArgumentError` naming both.
    module Registry
      macro finished
        # `Base.subclasses` is complete once every file has been parsed.
        ENTRIES = [
          {% for klass in Base.subclasses %}
          {% unless klass.private? || klass.annotation(::Matter::Cluster::RegistryExclude) %}
              { {{ klass }}::CLUSTER_ID, {{ klass }} },
            {% end %}
          {% end %}
        ] of {UInt32, Base.class}
      end

      @@by_id : Hash(UInt32, Base.class)?

      # The cluster class registered under *id*, or `nil`.
      def self.for(id : UInt32) : Base.class | Nil
        by_id[id]?
      end

      # Registered cluster ids in ascending order.
      def self.ids : Array(UInt32)
        by_id.keys.sort!
      end

      # Yields every registered `id, class` pair in ascending id order.
      def self.each(& : UInt32, Base.class ->) : Nil
        ids.each { |id| yield id, by_id[id] }
      end

      private def self.by_id : Hash(UInt32, Base.class)
        @@by_id ||= ENTRIES.each_with_object({} of UInt32 => Base.class) do |(id, klass), table|
          if registered = table[id]?
            raise ArgumentError.new("cluster id 0x#{id.to_s(16)} is claimed by both #{registered} and #{klass}")
          end
          table[id] = klass
        end
      end
    end
  end
end
