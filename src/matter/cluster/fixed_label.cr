require "./cluster"
require "./label_struct"

module Matter
  module Cluster
    # Fixed Label Cluster (0x0040)
    #
    # Provides fixed (non-writable) labels for an endpoint.
    class FixedLabel < Base
      cluster 0x0040, revision: 1

      attribute 0x0000, :label_list, Array(LabelStruct), default: [] of LabelStruct, fixed: true

      def initialize(endpoint_id : DataType::EndpointNumber, @label_list : Array(LabelStruct))
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("label list contains an oversized LabelStruct field") unless @label_list.all?(&.valid_lengths?)
      end

      def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : InteractionModel::Status | TLV::Any
        if attribute_id == ATTR_LABEL_LIST && @label_list.any? { |entry| !entry.valid_lengths? }
          return InteractionModel::Status.failure
        end
        super
      end
    end
  end
end
