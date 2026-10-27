require "./cluster"
require "./label_struct"

module Matter
  module Cluster
    # User Label Cluster (0x0041)
    #
    # Provides writable labels for an endpoint.
    class UserLabel < Base
      cluster 0x0041, revision: 1

      # Longest label and value a LabelStruct entry may carry.
      LABEL_MAX_LENGTH = LabelStruct::MAX_LENGTH

      attribute 0x0000, :label_list, Array(LabelStruct), default: [] of LabelStruct, writable: true, write_access: :manage

      # Entries are bounded per field; the DSL has no per-element constraint.
      before_write :label_list do |labels|
        too_long = labels.any? { |entry| !entry.valid_lengths? }
        InteractionModel::Status.constraint_error if too_long
      end

      def initialize(endpoint_id : DataType::EndpointNumber, @label_list : Array(LabelStruct) = [] of LabelStruct)
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
