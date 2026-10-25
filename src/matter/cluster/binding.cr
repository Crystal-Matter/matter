require "./cluster"

module Matter
  module Cluster
    # Fabric-scoped Binding cluster (0x001E).
    class Binding < Base
      cluster 0x001E, revision: 1, persist_state: false

      struct Target
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 1, optional: true)]
        property node : UInt64?

        @[TLV::Field(tag: 2, optional: true)]
        property group : UInt16?

        @[TLV::Field(tag: 3, optional: true)]
        property endpoint : UInt16?

        @[TLV::Field(tag: 4, optional: true)]
        property cluster : UInt32?

        @[TLV::Field(tag: 254, optional: true)]
        property fabric_index : UInt8?

        def initialize(
          @node : UInt64? = nil,
          @group : UInt16? = nil,
          @endpoint : UInt16? = nil,
          @cluster : UInt32? = nil,
          @fabric_index : UInt8? = nil,
        )
        end
      end

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter binding : Array(Target)

        def initialize(@data_version, @binding)
        end
      end

      attribute 0x0000, :binding, Array(Target), computed: true, writable: true,
        read_access: :view, write_access: :manage, fabric_scoped: true

      before_write :binding do |entries|
        if request_fabric_index.nil?
          InteractionModel::Status.unsupported_access
        elsif entries.any? { |entry| !valid_target?(entry) }
          InteractionModel::Status.constraint_error
        end
      end

      @binding = [] of Target

      def binding : Array(Target)
        if fabric_index = request_fabric_index
          @binding.select { |entry| entry.fabric_index == fabric_index }
        else
          @binding
        end
      end

      def binding=(entries : Array(Target)) : Nil
        if entries.any? { |entry| !valid_target?(entry) }
          raise Matter::ClusterError.new("Invalid binding target", InteractionModel::StatusCode::ConstraintError)
        end
        if fabric_index = request_fabric_index
          @binding.reject! { |entry| entry.fabric_index == fabric_index }
          @binding.concat(entries.map do |entry|
            entry.fabric_index = fabric_index
            entry
          end)
        else
          @binding = entries
        end
        increment_version_and_notify(ATTR_BINDING)
      end

      # Drop only the removed fabric's targets before its local index is reused.
      # Return whether state changed so callers can persist the new document.
      def remove_fabric(fabric_index : UInt8) : Bool
        previous_size = @binding.size
        @binding.reject! { |entry| entry.fabric_index == fabric_index }
        return false if @binding.size == previous_size

        increment_version_and_notify(ATTR_BINDING)
        true
      end

      private def valid_target?(entry : Target) : Bool
        unicast = !entry.node.nil? && !entry.endpoint.nil? && entry.group.nil?
        group = entry.group
        multicast = entry.node.nil? && entry.endpoint.nil? && !group.nil? && group > 0_u16
        unicast || multicast
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @binding).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        @data_version = state.data_version
        @binding = state.binding
      end
    end
  end
end
