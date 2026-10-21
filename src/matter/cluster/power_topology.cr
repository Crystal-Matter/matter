require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Power Topology (0x009C): the endpoint set served by a power
    # meter or energy source. Dynamic flow reports the currently active subset.
    class PowerTopology < Base
      cluster 0x009C, revision: 1

      feature :node_topology, bit: 0
      feature :tree_topology, bit: 1
      feature :set_topology, bit: 2
      feature :dynamic_power_flow, bit: 3

      MAX_ENDPOINTS = 20

      attribute 0x0000, :available_endpoints, Array(UInt16), computed: true,
        fixed: true, requires: :set_topology
      attribute 0x0001, :active_endpoints, Array(UInt16), default: [] of UInt16,
        persist: true, requires: :dynamic_power_flow

      @available_endpoints : Array(UInt16)

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     available_endpoints : Array(UInt16) = [] of UInt16,
                     active_endpoints : Array(UInt16) = [] of UInt16)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_features!
        validate_endpoints!(available_endpoints)
        validate_endpoints!(active_endpoints)
        if !@feature_map.set_topology? && !available_endpoints.empty?
          raise ArgumentError.new("available endpoints require SetTopology")
        end
        if !@feature_map.dynamic_power_flow? && !active_endpoints.empty?
          raise ArgumentError.new("active endpoints require DynamicPowerFlow")
        end
        raise ArgumentError.new("active endpoints must be available") unless (active_endpoints - available_endpoints).empty?
        @available_endpoints = available_endpoints.dup
        @active_endpoints = active_endpoints.dup
      end

      def available_endpoints : Array(UInt16)
        @available_endpoints.dup
      end

      # ActiveEndpoints is nonvolatile and may change only for DynamicPowerFlow.
      def update_active_endpoints(endpoints : Array(UInt16)) : Nil
        raise ArgumentError.new("DynamicPowerFlow feature is required") unless @feature_map.dynamic_power_flow?
        validate_endpoints!(endpoints)
        raise ArgumentError.new("active endpoints must be available") unless (endpoints - @available_endpoints).empty?
        self.active_endpoints = endpoints.dup
      end

      private def validate_features! : Nil
        topology = [@feature_map.node_topology?, @feature_map.tree_topology?, @feature_map.set_topology?]
        raise ArgumentError.new("select at most one power topology") if topology.count(true) > 1
        if @feature_map.dynamic_power_flow? && !@feature_map.set_topology?
          raise ArgumentError.new("DynamicPowerFlow requires SetTopology")
        end
      end

      private def validate_endpoints!(endpoints : Array(UInt16)) : Nil
        raise ArgumentError.new("power topology supports at most #{MAX_ENDPOINTS} endpoints") if endpoints.size > MAX_ENDPOINTS
        raise ArgumentError.new("power topology endpoints must be unique") unless endpoints.uniq.size == endpoints.size
      end
    end
  end
end
