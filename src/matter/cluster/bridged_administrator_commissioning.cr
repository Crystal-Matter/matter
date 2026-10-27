require "./administrator_commissioning"
require "../fabric"
require "../datatype/node_id"

module Matter
  module Cluster
    # Administrator Commissioning on a FabricSynchronizedNode Bridged Node.
    # The host forwards commands to the actual node and publishes its observed
    # window state. Callback results describe the completed remote operation,
    # not a queued job. This cluster never opens the bridge's own PASE window.
    class BridgedAdministratorCommissioning < Base
      alias OpenRequest = AdministratorCommissioning::OpenCommissioningWindowRequest
      alias WindowStatus = AdministratorCommissioning::CommissioningWindowStatus
      alias OpenCallback = Proc(UInt8, UInt64, UInt8, OpenRequest, InteractionModel::Status)
      alias RevokeCallback = Proc(UInt8, UInt64, UInt8, InteractionModel::Status)

      cluster AdministratorCommissioning::CLUSTER_ID, revision: AdministratorCommissioning::CLUSTER_REVISION,
        name: "AdministratorCommissioning"

      attribute AdministratorCommissioning::ATTR_WINDOW_STATUS, :window_status, WindowStatus,
        default: WindowStatus::WindowNotOpen
      attribute AdministratorCommissioning::ATTR_ADMIN_FABRIC_INDEX, :admin_fabric_index, UInt8,
        nullable: true
      attribute AdministratorCommissioning::ATTR_ADMIN_VENDOR_ID, :admin_vendor_id, UInt16,
        nullable: true

      command AdministratorCommissioning::CMD_OPEN_COMMISSIONING_WINDOW,
        :open_commissioning_window, request: OpenRequest, access: :administer, timed: true
      command AdministratorCommissioning::CMD_REVOKE_COMMISSIONING,
        :revoke_commissioning, access: :administer, timed: true

      getter target_fabric_index : UInt8
      getter target_node_id : UInt64

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @target_fabric_index : UInt8,
        @target_node_id : UInt64,
        @on_open : OpenCallback,
        @on_revoke : RevokeCallback,
      )
        unless (Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX).includes?(@target_fabric_index)
          raise ArgumentError.new("target fabric index is outside the operational range")
        end
        unless (DataType::NodeId::OPERATIONAL_MINIMUM..DataType::NodeId::OPERATIONAL_MAXIMUM).includes?(@target_node_id)
          raise ArgumentError.new("target node ID is outside the operational range")
        end
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def open_commissioning_window(request : OpenRequest) : InteractionModel::Status
        caller_fabric = authenticated_caller_fabric
        return InteractionModel::Status.unsupported_access unless caller_fabric
        @on_open.call(@target_fabric_index, @target_node_id, caller_fabric, request)
      end

      def revoke_commissioning : InteractionModel::Status
        caller_fabric = authenticated_caller_fabric
        return InteractionModel::Status.unsupported_access unless caller_fabric
        @on_revoke.call(@target_fabric_index, @target_node_id, caller_fabric)
      end

      # The host calls this after observing the remote node. Successful command
      # forwarding alone does not prove the remote window changed state.
      def publish_remote_window_state(
        status : WindowStatus,
        admin_fabric_index : UInt8?,
        admin_vendor_id : UInt16?,
      ) : Nil
        if status == WindowStatus::BasicWindowOpen
          raise ArgumentError.new("Basic Commissioning window state requires the Basic Commissioning feature")
        end
        self.window_status = status
        self.admin_fabric_index = admin_fabric_index
        self.admin_vendor_id = admin_vendor_id
      end

      private def authenticated_caller_fabric : UInt8?
        request_fabric_index if request_is_case_session?
      end
    end
  end
end
