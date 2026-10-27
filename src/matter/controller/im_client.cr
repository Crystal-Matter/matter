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
      # Leave room for Matter, UDP, and IPv6 headers within the minimum MTU.
      MAX_WRITE_PAYLOAD_SIZE     =      1100
      MAX_INVOKE_RESPONSE_CHUNKS =       128
      MAX_INVOKE_RESPONSE_BYTES  = 1_048_576

      def initialize(@client : Client, @timeout : Time::Span = 10.seconds)
      end

      def read_attribute(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        attribute_id : UInt32,
        fabric_filtered : Bool = true,
        data_version : UInt32? = nil,
      ) : InteractionModel::ReportDataMessage
        path = InteractionModel::AttributePath.new(
          endpoint: endpoint_id,
          cluster: cluster_id,
          attribute: attribute_id
        )

        filters = data_version.try do |version|
          [InteractionModel::DataVersionFilterIB.new(
            InteractionModel::ClusterPath.new(endpoint_id, cluster_id), version)]
        end
        read(session, peer, attribute_paths: [path], fabric_filtered: fabric_filtered,
          data_version_filters: filters)
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
        data_version_filters : Array(InteractionModel::DataVersionFilterIB)? = nil,
      ) : InteractionModel::ReportDataMessage
        if attribute_paths.empty? && event_paths.empty?
          raise Matter::ConfigurationError.new("Read requires an attribute or event path")
        end

        request = InteractionModel::ReadRequestMessage.new(
          attribute_requests: attribute_paths.empty? ? nil : attribute_paths,
          event_requests: event_paths.empty? ? nil : event_paths,
          event_filters: event_filters,
          data_version_filters: data_version_filters,
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

        read_report_data(session, peer, exchange_id, attribute_paths, event_paths)
      end

      private def read_report_data(session : Session::SecureContext, peer : Socket::IPAddress,
                                   exchange_id : UInt16, attribute_paths : Array(InteractionModel::AttributePath),
                                   event_paths : Array(InteractionModel::EventPath)) : InteractionModel::ReportDataMessage
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
          chunk_attributes = report.attribute_reports || [] of InteractionModel::AttributeReportIB
          chunk_events = report.event_reports || [] of InteractionModel::EventReportIB
          validate_read_report_paths!(chunk_attributes, chunk_events, attribute_paths, event_paths)
          attributes.concat(chunk_attributes)
          events.concat(chunk_events)
          if report.more_chunked_messages || !report.suppress_response
            @client.send_encrypted_request(session, peer, Client::PROTOCOL_INTERACTION_MODEL,
              MSG_STATUS_RESPONSE,
              InteractionModel::StatusResponseMessage.new(InteractionModel::StatusCode::Success.value).to_slice,
              exchange_id: exchange_id,
              initiator_message: !message.payload_header.initiator_message?,
              acknowledged_message_id: message.packet_header.message_id)
          end
          unless report.more_chunked_messages
            normalized = attribute_paths.size == 1 ? normalize_read_attribute(attributes, attribute_paths.first) : attributes
            return InteractionModel::ReportDataMessage.new(attribute_reports: normalized,
              event_reports: events, more_chunked_messages: false,
              suppress_response: report.suppress_response,
              interaction_model_revision: report.interaction_model_revision)
          end
        end
      end

      private def validate_read_report_paths!(
        attributes : Array(InteractionModel::AttributeReportIB),
        events : Array(InteractionModel::EventReportIB),
        attribute_paths : Array(InteractionModel::AttributePath),
        event_paths : Array(InteractionModel::EventPath),
      ) : Nil
        last_full_path : InteractionModel::AttributePath? = nil
        attributes.each do |report|
          if report.attribute_data.nil? == report.attribute_status.nil?
            raise Matter::ProtocolError.new("IM: Read response attribute report must have one data or status path")
          end
          candidate = report.attribute_data.try(&.path) || report.attribute_status.try(&.path)
          raise Matter::ProtocolError.new("IM: Read response path differs from request") unless candidate

          inherited = candidate.enable_tag_compression == true ? last_full_path : nil
          if candidate.enable_tag_compression == true && !inherited
            raise Matter::ProtocolError.new("IM: Read response path differs from request")
          end
          resolved = InteractionModel::AttributePath.new(
            endpoint: candidate.endpoint || inherited.try(&.endpoint),
            cluster: candidate.cluster || inherited.try(&.cluster),
            attribute: candidate.attribute || inherited.try(&.attribute),
            list_index: candidate.list_index,
            node: candidate.node || inherited.try(&.node))
          if candidate.enable_tag_compression == true && !resolved.concrete?
            raise Matter::ProtocolError.new("IM: Read response path differs from request")
          end
          unless attribute_paths.any? { |requested| read_attribute_path_matches?(requested, resolved) }
            raise Matter::ProtocolError.new("IM: Read response path differs from request")
          end
          if report.attribute_data && !resolved.concrete?
            raise Matter::ProtocolError.new("IM: Read response path differs from request")
          end
          if candidate.enable_tag_compression != true
            last_full_path = resolved.concrete? ? resolved : nil
          end
        end

        events.each do |report|
          if report.event_data.nil? == report.event_status.nil?
            raise Matter::ProtocolError.new("IM: Read response event report must have one data or status path")
          end
          candidate = report.event_data.try(&.path) || report.event_status.try(&.path)
          raise Matter::ProtocolError.new("IM: Read response path differs from request") unless candidate
          unless event_paths.any? { |requested| read_event_path_matches?(requested, candidate) }
            raise Matter::ProtocolError.new("IM: Read response path differs from request")
          end
          if report.event_data && candidate.wildcard?
            raise Matter::ProtocolError.new("IM: Read response path differs from request")
          end
        end
      end

      private def read_attribute_path_matches?(requested : InteractionModel::AttributePath,
                                               reported : InteractionModel::AttributePath) : Bool
        (requested.node.nil? || reported.node.nil? || requested.node == reported.node) &&
          (requested.endpoint.nil? || requested.endpoint == reported.endpoint) &&
          (requested.cluster.nil? || requested.cluster == reported.cluster) &&
          (requested.attribute.nil? || requested.attribute == reported.attribute) &&
          (requested.list_index.nil? || requested.list_index == reported.list_index)
      end

      private def read_event_path_matches?(requested : InteractionModel::EventPath,
                                           reported : InteractionModel::EventPath) : Bool
        (requested.node.nil? || reported.node.nil? || requested.node == reported.node) &&
          (requested.endpoint.nil? || requested.endpoint == reported.endpoint) &&
          (requested.cluster.nil? || requested.cluster == reported.cluster) &&
          (requested.event.nil? || requested.event == reported.event)
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
        data_version : UInt32? = nil,
      ) : InteractionModel::WriteResponseMessage
        write_attributes(
          session: session,
          peer: peer,
          writes: [{endpoint_id, cluster_id, attribute_id, value}],
          timed_request: timed_request,
          suppress_response: suppress_response,
          timed_request_timeout: timed_request_timeout,
          data_versions: data_version.try { |version| { {endpoint_id, cluster_id} => version } }
        )
      end

      def write_attributes(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        writes : Array(Tuple(UInt16, UInt32, UInt32, Bytes)),
        timed_request : Bool = false,
        suppress_response : Bool = false,
        timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
        data_versions : Hash(Tuple(UInt16, UInt32), UInt32)? = nil,
      ) : InteractionModel::WriteResponseMessage
        write_ibs = writes.flat_map do |endpoint_id, cluster_id, attribute_id, value|
          path = InteractionModel::AttributePath.new(
            endpoint: endpoint_id,
            cluster: cluster_id,
            attribute: attribute_id
          )

          data = InteractionModel::AttributeDataIB.new(
            path: path,
            data: TLV::Any.from_slice(value),
            data_version: data_versions.try(&.[{endpoint_id, cluster_id}]?)
          )
          expand_large_list_write(data, suppress_response, timed_request)
        end
        chunks = chunk_write_requests(write_ibs, suppress_response, timed_request)
        if timed_request && chunks.size > 1
          raise Matter::ConfigurationError.new("Timed WriteRequest cannot be chunked")
        end

        exchange_id = begin_timed_request(session, peer, timed_request_timeout) if timed_request
        exchange_id ||= @client.next_exchange_id
        statuses = [] of InteractionModel::AttributeStatusIB
        chunks.each_with_index do |chunk, index|
          request = write_request(chunk, suppress_response, timed_request, index < chunks.size - 1)
          @client.send_encrypted_request(
            session: session,
            peer: peer,
            protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
            message_type: MSG_WRITE_REQUEST,
            payload: request.to_slice,
            exchange_id: exchange_id,
            requires_ack: true
          )

          response = @client.wait_for_any(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
            [MSG_WRITE_RESPONSE, MSG_STATUS_RESPONSE], @timeout)
          raise Matter::TimeoutError.new("IM: timeout waiting for WriteResponse (exchange=#{exchange_id})") unless response
          unless response.message.packet_header.session_id == session.session_id
            raise Matter::ProtocolError.new("IM: Write response arrived on another session (exchange=#{exchange_id})")
          end
          raise_follow_up_status!(response, "WriteRequest", exchange_id)
          chunk_statuses = InteractionModel::WriteResponseMessage.from_slice(response.message.payload.to_slice).write_responses
          unless chunk_statuses.size == chunk.size
            raise Matter::ProtocolError.new("IM: WriteResponse status count did not match WriteRequest (exchange=#{exchange_id})")
          end
          validate_write_response_paths!(chunk, chunk_statuses, exchange_id)
          statuses.concat(chunk_statuses)
          break unless chunk_statuses.all? { |status| status.status.status == InteractionModel::StatusCode::Success.value }
        end

        InteractionModel::WriteResponseMessage.new(statuses)
      end

      private def validate_write_response_paths!(
        chunk : Array(InteractionModel::AttributeDataIB),
        statuses : Array(InteractionModel::AttributeStatusIB),
        exchange_id : UInt16,
      ) : Nil
        unmatched = chunk.map(&.path)
        statuses.each do |entry|
          index = unmatched.index do |requested|
            write_response_path_matches?(requested, entry.path, entry.status.status, chunk)
          end
          unless index
            raise Matter::ProtocolError.new("IM: WriteResponse path did not match WriteRequest (exchange=#{exchange_id})")
          end
          unmatched.delete_at(index)
        end
      end

      private def write_response_path_matches?(
        requested : InteractionModel::AttributePath,
        reported : InteractionModel::AttributePath,
        status : UInt8,
        chunk : Array(InteractionModel::AttributeDataIB),
      ) : Bool
        return false unless reported.node.nil? && reported.enable_tag_compression != true
        return false unless requested.endpoint == reported.endpoint &&
                            requested.cluster == reported.cluster &&
                            requested.attribute == reported.attribute

        # A failure may identify only the attribute even for a list item
        # request. That abbreviated path is ambiguous when this chunk also
        # writes the whole list, so never use it to satisfy an append there.
        if status != InteractionModel::StatusCode::Success.value &&
           reported.list_index.nil? && !reported.list_index_null? &&
           (requested.list_index || requested.list_index_null?)
          ambiguous = chunk.any? do |item|
            path = item.path
            path.endpoint == requested.endpoint && path.cluster == requested.cluster &&
              path.attribute == requested.attribute && path.list_index.nil? && !path.list_index_null?
          end
          return !ambiguous
        end
        requested.list_index == reported.list_index &&
          requested.list_index_null? == reported.list_index_null?
      end

      private def write_request(items : Array(InteractionModel::AttributeDataIB), suppress_response : Bool,
                                timed_request : Bool, more : Bool) : InteractionModel::WriteRequestMessage
        InteractionModel::WriteRequestMessage.new(
          suppress_response: suppress_response,
          timed_request: timed_request,
          write_requests: items,
          more_chunked_messages: more,
          interaction_model_revision: InteractionModel::INTERACTION_MODEL_REVISION
        )
      end

      private def chunk_write_requests(items : Array(InteractionModel::AttributeDataIB), suppress_response : Bool,
                                       timed_request : Bool) : Array(Array(InteractionModel::AttributeDataIB))
        chunks = [] of Array(InteractionModel::AttributeDataIB)
        current = [] of InteractionModel::AttributeDataIB
        items.each do |item|
          candidate = current + [item]
          if write_request(candidate, suppress_response, timed_request, true).to_slice.size > MAX_WRITE_PAYLOAD_SIZE
            if current.empty?
              raise Matter::ConfigurationError.new("Write attribute exceeds the Matter message size")
            end
            chunks << current
            current = [item]
            if write_request(current, suppress_response, timed_request, true).to_slice.size > MAX_WRITE_PAYLOAD_SIZE
              raise Matter::ConfigurationError.new("Write attribute exceeds the Matter message size")
            end
          else
            current = candidate
          end
        end
        chunks << current unless current.empty?
        chunks << current if chunks.empty?
        chunks
      end

      private def expand_large_list_write(data : InteractionModel::AttributeDataIB,
                                          suppress_response : Bool, timed_request : Bool) : Array(InteractionModel::AttributeDataIB)
        return [data] if write_request([data], suppress_response, timed_request, false).to_slice.size <= MAX_WRITE_PAYLOAD_SIZE
        return [data] unless data.data.header.element_type.array?

        path = data.path
        append_path = InteractionModel::AttributePath.new(
          endpoint: path.endpoint, cluster: path.cluster, attribute: path.attribute,
          list_index_null: true)
        empty = InteractionModel::AttributeDataIB.new(path,
          TLV::Any.new(TLV::List.new, nil, as_array: true), data.data_version)
        items = data.data.as_list.map do |item|
          anonymous = TLV::Any.new(TLV::Header.new(item.header.element_type), item.value)
          InteractionModel::AttributeDataIB.new(append_path, anonymous, data.data_version)
        end
        [empty] + items
      end

      # A single-command consumer must not accept an OK command response while
      # silently ignoring a second failure or conflicting response in the same
      # exchange. The transport still assembles chunked responses; this guard
      # is applied by consumers that expect one terminal response.
      def self.single_invoke_response!(response : InteractionModel::InvokeResponseMessage,
                                       operation : String) : InteractionModel::InvokeResponseIB
        unless response.invoke_responses.size == 1
          raise Matter::ProtocolError.new("#{operation} expected exactly one InvokeResponse, got #{response.invoke_responses.size}")
        end
        response.invoke_responses.first
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

        read_invoke_responses(session, peer, exchange_id, path)
      end

      private def read_invoke_responses(session : Session::SecureContext, peer : Socket::IPAddress,
                                        exchange_id : UInt16,
                                        request_path : InteractionModel::CommandPath) : InteractionModel::InvokeResponseMessage
        deadline = Time.instant + @timeout
        responses = [] of InteractionModel::InvokeResponseIB
        chunks_received = 0
        bytes_received = 0
        loop do
          remaining = deadline - Time.instant
          raise Matter::TimeoutError.new("IM: timeout waiting for InvokeResponse (exchange=#{exchange_id})") if remaining <= 0.seconds
          received = @client.wait_for_any(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
            [MSG_INVOKE_RESPONSE, MSG_STATUS_RESPONSE], remaining)
          raise Matter::TimeoutError.new("IM: timeout waiting for InvokeResponse (exchange=#{exchange_id})") unless received
          message = received.message
          unless message.packet_header.session_id == session.session_id
            raise Matter::ProtocolError.new("IM: InvokeResponse arrived on session #{message.packet_header.session_id}, expected #{session.session_id} (exchange=#{exchange_id})")
          end
          if message.payload_header.message_type == MSG_STATUS_RESPONSE
            raise_follow_up_status!(received, "InvokeRequest", exchange_id)
          end

          chunks_received += 1
          bytes_received += message.payload.size
          if chunks_received > MAX_INVOKE_RESPONSE_CHUNKS || bytes_received > MAX_INVOKE_RESPONSE_BYTES
            raise Matter::ProtocolError.new("IM: InvokeResponse exceeded chunk limit (exchange=#{exchange_id})")
          end
          chunk = begin
            InteractionModel::InvokeResponseMessage.from_slice(message.payload.to_slice)
          rescue ex
            raise Matter::ProtocolError.new("IM: invalid InvokeResponse (exchange=#{exchange_id})", cause: ex)
          end
          chunk.invoke_responses.each do |entry|
            validate_invoke_response_path!(entry, request_path)
          end
          responses.concat(chunk.invoke_responses)
          unless chunk.more_chunked_messages
            return InteractionModel::InvokeResponseMessage.new(
              suppress_response: chunk.suppress_response?,
              invoke_responses: responses,
              interaction_model_revision: chunk.interaction_model_revision)
          end

          @client.send_encrypted_request(session, peer, Client::PROTOCOL_INTERACTION_MODEL,
            MSG_STATUS_RESPONSE,
            InteractionModel::StatusResponseMessage.new(InteractionModel::StatusCode::Success.value).to_slice,
            exchange_id: exchange_id,
            initiator_message: !message.payload_header.initiator_message?,
            acknowledged_message_id: message.packet_header.message_id)
        end
      end

      private def validate_invoke_response_path!(entry : InteractionModel::InvokeResponseIB,
                                                 request_path : InteractionModel::CommandPath) : Nil
        data = entry.command_data
        status = entry.command_status
        if data && status || (!data && !status)
          raise Matter::ProtocolError.new("IM: InvokeResponse must contain one command data or status")
        end
        if status && status.command_path != request_path
          raise Matter::ProtocolError.new("IM: InvokeResponse status path #{status.command_path} differs from request #{request_path}")
        end
        if data && (data.command_path.endpoint != request_path.endpoint ||
           data.command_path.cluster != request_path.cluster)
          # Command data uses a response command ID, which may differ from the
          # invoked command ID. Endpoint and cluster must still match.
          raise Matter::ProtocolError.new("IM: InvokeResponse data path #{data.command_path} differs from request #{request_path}")
        end
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
