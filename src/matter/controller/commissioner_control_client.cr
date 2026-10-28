require "../cluster/commissioner_control"
require "./im_client"

module Matter
  module Controller
    # Typed client-side wire operations for Matter 1.6 reverse commissioning.
    # The application decides consent and which local node to place in the
    # window after an approved result; this client does not make that decision.
    class CommissionerControlClient
      alias Control = Cluster::CommissionerControl

      def initialize(@im : ImClient)
      end

      def request_approval(session : Session::SecureContext, peer : Socket::IPAddress,
                           endpoint : UInt16, request : Control::RequestCommissioningApprovalRequest) : Nil
        client_identity!(session)
        response = @im.invoke(session, peer, endpoint, Control::CLUSTER_ID,
          Control::CMD_REQUEST_COMMISSIONING_APPROVAL, request.to_slice)
        item = ImClient.single_invoke_response!(response, "RequestCommissioningApproval")
        path = InteractionModel::CommandPath.new(endpoint, Control::CLUSTER_ID,
          Control::CMD_REQUEST_COMMISSIONING_APPROVAL)
        status = item.command_status ||
                 raise Matter::ProtocolError.new("RequestCommissioningApproval omitted command status")
        unless status.command_path == path
          raise Matter::ProtocolError.new("RequestCommissioningApproval returned an unexpected status path")
        end
        unless status.status.status == InteractionModel::StatusCode::Success.value
          raise Matter::CommissioningError.new("RequestCommissioningApproval failed (status=#{status.status.status})")
        end
      end

      # Read the fabric-filtered result journal once. A nil result means the
      # asynchronous host decision has not appeared; callers may poll or use
      # the general IM event subscription API before requesting approval.
      # Use unique RequestIDs or event_min to exclude a prior result for a
      # reused RequestID.
      def approval_result(session : Session::SecureContext, peer : Socket::IPAddress,
                          endpoint : UInt16, request_id : UInt64,
                          event_min : UInt64? = nil) : InteractionModel::StatusCode?
        fabric_index, client_node_id = client_identity!(session)
        path = InteractionModel::EventPath.new(endpoint: endpoint, cluster: Control::CLUSTER_ID,
          event: Control::EVENT_COMMISSIONING_REQUEST_RESULT)
        report = @im.read_events(session, peer, [path], event_min: event_min, fabric_filtered: true)
        if items = report.event_reports
          items.each do |item|
            if status = item.event_status
              raise Matter::ProtocolError.new("CommissioningRequestResult read failed (status=#{status.status.status})")
            end
            event = item.event_data
            next unless event
            next unless event.path.endpoint == endpoint && event.path.cluster == Control::CLUSTER_ID &&
                        event.path.event == Control::EVENT_COMMISSIONING_REQUEST_RESULT
            data = event.data || raise Matter::ProtocolError.new("CommissioningRequestResult omitted event data")
            result = Control::CommissioningRequestResultEvent.from_tlv(data)
            next unless result.request_id == request_id && result.client_node_id == client_node_id &&
                        result.fabric_index == fabric_index
            return result.status_code
          end
        end
        nil
      end

      def commission_node(session : Session::SecureContext, peer : Socket::IPAddress,
                          endpoint : UInt16, request : Control::CommissionNodeRequest) : Control::ReverseOpenCommissioningWindowResponse
        client_identity!(session)
        unless (Control::MIN_RESPONSE_TIMEOUT..Control::MAX_RESPONSE_TIMEOUT).includes?(request.response_timeout_seconds)
          raise Matter::ConfigurationError.new("CommissionNode response timeout is outside Matter 1.6 bounds")
        end
        response = @im.invoke(session, peer, endpoint, Control::CLUSTER_ID,
          Control::CMD_COMMISSION_NODE, request.to_slice,
          response_timeout: request.response_timeout_seconds.seconds)
        item = ImClient.single_invoke_response!(response, "CommissionNode")
        if status = item.command_status
          expected = InteractionModel::CommandPath.new(endpoint, Control::CLUSTER_ID, Control::CMD_COMMISSION_NODE)
          unless status.command_path == expected
            raise Matter::ProtocolError.new("CommissionNode returned an unexpected status path")
          end
          raise Matter::CommissioningError.new("CommissionNode failed (status=#{status.status.status})")
        end
        data = item.command_data || raise Matter::ProtocolError.new("CommissionNode omitted response data")
        expected = InteractionModel::CommandPath.new(endpoint, Control::CLUSTER_ID,
          Control::CMD_COMMISSION_NODE_RESPONSE)
        unless data.command_path == expected
          raise Matter::ProtocolError.new("CommissionNode returned an unexpected response path")
        end
        fields = data.command_fields || raise Matter::ProtocolError.new("CommissionNode omitted window parameters")
        window = Control::ReverseOpenCommissioningWindowResponse.from_tlv(fields)
        unless Control.valid_window?(window)
          raise Matter::ProtocolError.new("CommissionNode returned invalid reverse window parameters")
        end
        window
      end

      private def client_identity!(session : Session::SecureContext) : Tuple(UInt8, UInt64)
        unless session.case_session?
          raise Matter::ConfigurationError.new("Commissioner Control requires a CASE session")
        end
        fabric_index = session.fabric_index ||
                       raise Matter::ConfigurationError.new("Commissioner Control session has no fabric index")
        node_id = session.local_node_id ||
                  raise Matter::ConfigurationError.new("Commissioner Control session has no local NodeID")
        {fabric_index, node_id.id}
      end
    end
  end
end
