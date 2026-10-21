require "log"

require "../interaction_model/paths"
require "../interaction_model/tlv_messages"
require "./client"

module Matter
  module Controller
    class ImClient
      Log = ::Log.for("matter.controller.im_client")

      MSG_STATUS_RESPONSE = 0x01_u8
      MSG_READ_REQUEST    = 0x02_u8
      MSG_REPORT_DATA     = 0x05_u8
      MSG_WRITE_REQUEST   = 0x06_u8
      MSG_WRITE_RESPONSE  = 0x07_u8
      MSG_INVOKE_REQUEST  = 0x08_u8
      MSG_INVOKE_RESPONSE = 0x09_u8
      MSG_TIMED_REQUEST   = 0x0A_u8

      DEFAULT_TIMED_REQUEST_TIMEOUT = 10.seconds
      MAX_TIMED_REQUEST_TIMEOUT_MS  = UInt16::MAX
      MAX_READ_REPORT_CHUNKS        =       128
      MAX_READ_REPORT_BYTES         = 1_048_576

      def initialize(@client : Client, @timeout : Time::Span = 10.seconds)
      end

      def read_attribute(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        attribute_id : UInt32,
        fabric_filtered : Bool = true,
      ) : InteractionModel::ReportDataMessage
        path = InteractionModel::AttributePath.new(
          endpoint: endpoint_id,
          cluster: cluster_id,
          attribute: attribute_id
        )

        read(session, peer, attribute_paths: [path], fabric_filtered: fabric_filtered)
      end

      def read_events(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        paths : Array(InteractionModel::EventPath),
        event_min : UInt64? = nil,
        fabric_filtered : Bool = true,
      ) : InteractionModel::ReportDataMessage
        filters = event_min.try { |number| [InteractionModel::EventFilterIB.new(number)] }
        read(session, peer, event_paths: paths, event_filters: filters,
          fabric_filtered: fabric_filtered)
      end

      # Read arbitrary attribute and event paths in one IM exchange. Wildcard
      # paths and event filters are passed through to the server unchanged.
      def read(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        attribute_paths : Array(InteractionModel::AttributePath) = [] of InteractionModel::AttributePath,
        event_paths : Array(InteractionModel::EventPath) = [] of InteractionModel::EventPath,
        event_filters : Array(InteractionModel::EventFilterIB)? = nil,
        fabric_filtered : Bool = true,
      ) : InteractionModel::ReportDataMessage
        if attribute_paths.empty? && event_paths.empty?
          raise Matter::ConfigurationError.new("Read requires an attribute or event path")
        end

        request = InteractionModel::ReadRequestMessage.new(
          attribute_requests: attribute_paths.empty? ? nil : attribute_paths,
          event_requests: event_paths.empty? ? nil : event_paths,
          event_filters: event_filters,
          fabric_filtered: fabric_filtered,
          interaction_model_revision: InteractionModel::INTERACTION_MODEL_REVISION
        )

        payload = request.to_slice
        exchange_id = @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_READ_REQUEST,
          payload: payload,
          requires_ack: true
        )

        read_report_data(session, peer, exchange_id, attribute_paths.size == 1 ? attribute_paths.first : nil)
      end

      private def read_report_data(session : Session::SecureContext, peer : Socket::IPAddress,
                                   exchange_id : UInt16, path : InteractionModel::AttributePath?) : InteractionModel::ReportDataMessage
        deadline = Time.instant + @timeout
        attributes = [] of InteractionModel::AttributeReportIB
        events = [] of InteractionModel::EventReportIB
        bytes_received = 0
        chunks_received = 0
        loop do
          remaining = deadline - Time.instant
          raise Matter::TimeoutError.new("IM: timeout waiting for ReportData (exchange=#{exchange_id})") if remaining <= 0.seconds
          received = @client.wait_for_any(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
            [MSG_REPORT_DATA, MSG_STATUS_RESPONSE], remaining)
          raise Matter::TimeoutError.new("IM: timeout waiting for ReportData (exchange=#{exchange_id})") unless received
          message = received.message
          unless message.packet_header.session_id == session.session_id
            raise Matter::ProtocolError.new("IM: Read response arrived on another session (exchange=#{exchange_id})")
          end
          if message.payload_header.message_type == MSG_STATUS_RESPONSE
            raise_read_status!(message.payload.to_slice, exchange_id)
          end
          chunks_received += 1
          bytes_received += message.payload.size
          if chunks_received > MAX_READ_REPORT_CHUNKS || bytes_received > MAX_READ_REPORT_BYTES
            raise Matter::ProtocolError.new("IM: Read response exceeded chunk limit (exchange=#{exchange_id})")
          end

          report = begin
            InteractionModel::ReportDataMessage.from_slice(message.payload.to_slice)
          rescue ex
            raise Matter::ProtocolError.new("IM: invalid ReportData (exchange=#{exchange_id})", cause: ex)
          end
          if report.subscription_id
            raise Matter::ProtocolError.new("IM: Read response carried a subscription ID (exchange=#{exchange_id})")
          end
          attributes.concat(report.attribute_reports || [] of InteractionModel::AttributeReportIB)
          events.concat(report.event_reports || [] of InteractionModel::EventReportIB)
          if report.more_chunked_messages || !report.suppress_response
            @client.send_encrypted_request(session, peer, Client::PROTOCOL_INTERACTION_MODEL,
              MSG_STATUS_RESPONSE,
              InteractionModel::StatusResponseMessage.new(InteractionModel::StatusCode::Success.value).to_slice,
              exchange_id: exchange_id,
              initiator_message: !message.payload_header.initiator_message?,
              acknowledged_message_id: message.packet_header.message_id)
          end
          unless report.more_chunked_messages
            normalized = path ? normalize_read_attribute(attributes, path) : attributes
            return InteractionModel::ReportDataMessage.new(attribute_reports: normalized,
              event_reports: events, more_chunked_messages: false,
              suppress_response: report.suppress_response,
              interaction_model_revision: report.interaction_model_revision)
          end
        end
      end

      # Matter may report a list as an initial Array value followed by
      # list-index item reports on later chunks. Preserve the existing
      # single-report API by folding those items into one Array value.
      private def normalize_read_attribute(reports : Array(InteractionModel::AttributeReportIB),
                                           path : InteractionModel::AttributePath) : Array(InteractionModel::AttributeReportIB)
        return reports if reports.size < 2
        data = reports.compact_map(&.attribute_data)
        return reports unless data.size == reports.size
        return reports unless data.all? do |entry|
                                candidate = entry.path
                                (candidate.endpoint.nil? || candidate.endpoint == path.endpoint) &&
                                (candidate.cluster.nil? || candidate.cluster == path.cluster) &&
                                (candidate.attribute.nil? || candidate.attribute == path.attribute)
                              end

        first = data.first
        items = TLV::List.new
        data.each do |entry|
          value = entry.data
          if value.header.element_type.array?
            items.concat(value.as_list)
          else
            if index = entry.path.list_index
              unless index == items.size
                raise Matter::ProtocolError.new("IM: Read list item index #{index} did not follow #{items.size} items")
              end
            end
            items << value
          end
        end
        merged = InteractionModel::AttributeDataIB.new(path,
          TLV::Any.new(items, nil, as_array: true), first.data_version)
        [InteractionModel::AttributeReportIB.new(attribute_data: merged)]
      end

      private def raise_read_status!(payload : Bytes, exchange_id : UInt16) : NoReturn
        status = begin
          InteractionModel::StatusResponseMessage.from_slice(payload).status
        rescue ex
          raise Matter::ProtocolError.new("IM: invalid ReadRequest StatusResponse (exchange=#{exchange_id})", cause: ex)
        end
        code = InteractionModel::StatusCode.from_value?(status)
        if code == InteractionModel::StatusCode::Timeout
          raise Matter::TimeoutError.new("IM: ReadRequest timed out (exchange=#{exchange_id})")
        end
        raise Matter::ProtocolError.new("IM: ReadRequest rejected with #{code || "0x#{status.to_s(16)}"} (exchange=#{exchange_id})")
      end

      def write_attribute(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        attribute_id : UInt32,
        value : Bytes,
        timed_request : Bool = false,
        suppress_response : Bool = false,
        timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
      ) : InteractionModel::WriteResponseMessage
        write_attributes(
          session: session,
          peer: peer,
          writes: [{endpoint_id, cluster_id, attribute_id, value}],
          timed_request: timed_request,
          suppress_response: suppress_response,
          timed_request_timeout: timed_request_timeout
        )
      end

      def write_attributes(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        writes : Array(Tuple(UInt16, UInt32, UInt32, Bytes)),
        timed_request : Bool = false,
        suppress_response : Bool = false,
        timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
      ) : InteractionModel::WriteResponseMessage
        write_ibs = writes.map do |endpoint_id, cluster_id, attribute_id, value|
          path = InteractionModel::AttributePath.new(
            endpoint: endpoint_id,
            cluster: cluster_id,
            attribute: attribute_id
          )

          InteractionModel::AttributeDataIB.new(
            path: path,
            data: TLV::Any.from_slice(value),
            data_version: nil
          )
        end

        request = InteractionModel::WriteRequestMessage.new(
          suppress_response: suppress_response,
          timed_request: timed_request,
          write_requests: write_ibs,
          more_chunked_messages: false,
          interaction_model_revision: 12_u8
        )

        exchange_id = begin_timed_request(session, peer, timed_request_timeout) if timed_request
        exchange_id = @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_WRITE_REQUEST,
          payload: request.to_slice,
          exchange_id: exchange_id || @client.next_exchange_id,
          requires_ack: true
        )

        response = if timed_request
                     @client.wait_for_any(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
                       [MSG_WRITE_RESPONSE, MSG_STATUS_RESPONSE], @timeout)
                   else
                     @client.wait_for(exchange_id, Client::PROTOCOL_INTERACTION_MODEL, MSG_WRITE_RESPONSE, @timeout)
                   end
        raise Matter::TimeoutError.new("IM: timeout waiting for WriteResponse (exchange=#{exchange_id})") unless response
        raise_follow_up_status!(response, "WriteRequest", exchange_id) if timed_request

        InteractionModel::WriteResponseMessage.from_slice(response.message.payload.to_slice)
      end

      def invoke(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        command_id : UInt32,
        fields : Bytes = Bytes.empty,
        timed_request : Bool = false,
        timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
      ) : InteractionModel::InvokeResponseMessage
        path = InteractionModel::CommandPath.new(
          endpoint: endpoint_id,
          cluster: cluster_id,
          command: command_id
        )

        command_fields = fields.empty? ? nil : TLV::Any.from_slice(fields)
        command = InteractionModel::CommandDataIBTlv.new(command_path: path, command_fields: command_fields)

        request = InteractionModel::InvokeRequestMessage.new(
          invoke_requests: [command],
          suppress_response: false,
          timed_request: timed_request,
          interaction_model_revision: 12_u8
        )

        exchange_id = begin_timed_request(session, peer, timed_request_timeout) if timed_request
        exchange_id = @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_INVOKE_REQUEST,
          payload: request.to_slice,
          exchange_id: exchange_id || @client.next_exchange_id,
          requires_ack: true
        )

        response = if timed_request
                     @client.wait_for_any(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
                       [MSG_INVOKE_RESPONSE, MSG_STATUS_RESPONSE], @timeout)
                   else
                     @client.wait_for(exchange_id, Client::PROTOCOL_INTERACTION_MODEL, MSG_INVOKE_RESPONSE, @timeout)
                   end
        raise Matter::TimeoutError.new("IM: timeout waiting for InvokeResponse (exchange=#{exchange_id})") unless response
        raise_follow_up_status!(response, "InvokeRequest", exchange_id) if timed_request

        InteractionModel::InvokeResponseMessage.from_slice(response.message.payload.to_slice)
      end

      private def raise_follow_up_status!(response : Client::ReceivedMessage, operation : String,
                                          exchange_id : UInt16) : Nil
        return unless response.message.payload_header.message_type == MSG_STATUS_RESPONSE

        status = begin
          InteractionModel::StatusResponseMessage.from_slice(response.message.payload.to_slice).status
        rescue ex
          raise Matter::ProtocolError.new("IM: invalid #{operation} StatusResponse (exchange=#{exchange_id})", cause: ex)
        end
        code = InteractionModel::StatusCode.from_value?(status)
        if code == InteractionModel::StatusCode::Timeout
          raise Matter::TimeoutError.new("IM: timed #{operation} expired (exchange=#{exchange_id})")
        end
        raise Matter::ProtocolError.new("IM: timed #{operation} rejected with #{code || "0x#{status.to_s(16)}"} (exchange=#{exchange_id})")
      end

      private def begin_timed_request(session : Session::SecureContext, peer : Socket::IPAddress,
                                      window : Time::Span) : UInt16
        milliseconds = window.total_milliseconds.ceil.to_i64
        unless milliseconds.in?(1..MAX_TIMED_REQUEST_TIMEOUT_MS)
          raise Matter::ConfigurationError.new("TimedRequest window must be between 1 and #{MAX_TIMED_REQUEST_TIMEOUT_MS} milliseconds")
        end

        exchange_id = @client.next_exchange_id
        request = InteractionModel::TimedRequestMessage.new(milliseconds.to_u16)
        @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_TIMED_REQUEST,
          payload: request.to_slice,
          exchange_id: exchange_id,
          requires_ack: true
        )

        response = @client.wait_for(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
          MSG_STATUS_RESPONSE, {@timeout, window}.min)
        raise Matter::TimeoutError.new("IM: timeout waiting for TimedRequest StatusResponse (exchange=#{exchange_id})") unless response

        status = begin
          InteractionModel::StatusResponseMessage.from_slice(response.message.payload.to_slice).status
        rescue ex
          raise Matter::ProtocolError.new("IM: invalid TimedRequest StatusResponse (exchange=#{exchange_id})", cause: ex)
        end
        unless status == InteractionModel::StatusCode::Success.value
          label = InteractionModel::StatusCode.from_value?(status).try(&.to_s) || "0x#{status.to_s(16)}"
          raise Matter::ProtocolError.new("IM: TimedRequest rejected with #{label} (exchange=#{exchange_id})")
        end

        exchange_id
      end
    end
  end
end
