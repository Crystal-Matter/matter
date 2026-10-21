require "./cluster"

module Matter
  module Cluster
    # Node-level directory of endpoints that expose Power Source clusters.
    class PowerSourceConfiguration < Base
      cluster 0x002E, revision: 1

      MAX_SOURCES = 6

      attribute 0x0000, :sources, Array(UInt16),
        default: [] of UInt16, persist: true

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @sources : Array(UInt16) = [] of UInt16)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("sources must contain at most #{MAX_SOURCES} endpoints") if @sources.size > MAX_SOURCES
        raise ArgumentError.new("sources must not contain duplicate endpoints") unless @sources.uniq.size == @sources.size
        @sources = @sources.dup
      end

      # Replaces the endpoint directory when the node's power topology changes.
      def update_sources(endpoints : Array(UInt16)) : Nil
        raise ArgumentError.new("sources must contain at most #{MAX_SOURCES} endpoints") if endpoints.size > MAX_SOURCES
        raise ArgumentError.new("sources must not contain duplicate endpoints") unless endpoints.uniq.size == endpoints.size
        self.sources = endpoints.dup
      end
    end
  end
end
