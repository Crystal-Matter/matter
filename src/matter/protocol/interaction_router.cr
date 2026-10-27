require "log"
require "socket"

require "../codec/message_codec"
require "../interaction_model/paths"
require "../interaction_model/status_code"
require "../interaction_model/tlv_messages"
require "../node"
require "../session/context"
require "./im_handler"
require "./response_sender"
require "./session_registry"
require "./subscription_manager"

module Matter
  module Protocol
    # Routes Interaction Model messages to the data model and answers them.
    #
    # Parsing, reading, writing and invoking live in `IMHandler`; this decides
    # which of them a message wants, enforces timed interactions, and puts the
    # response on the wire. It is always called with the registry lock held.
    class InteractionRouter
      Log = ::Log.for("matter.protocol.interaction_router")

      property on_invoke_response_sent : Proc(UInt64, UInt16, Nil)?
      property on_invoke_response_failed : Proc(UInt64, UInt16, Nil)?

      WRITE_CHUNK_TIMEOUT = 60.seconds

      # Deadlines of TimedRequests awaiting their Invoke or Write, keyed by
      # `{session_id, exchange_id}` so one session cannot consume another's.
      @timed_request_deadlines : Hash(Tuple(UInt16, UInt16), Time::Instant) = {} of Tuple(UInt16, UInt16) => Time::Instant

      # A chunked WriteRequest receives one WriteResponse per chunk. The list
      # operation begun by an earlier chunk remains scoped to that exchange.
      @write_list_states : Hash(Tuple(UInt64, UInt16), Tuple(IMHandler::WriteListState, Time::Instant)) = {} of Tuple(UInt64, UInt16) => Tuple(IMHandler::WriteListState, Time::Instant)

      def initialize(
        @registry : SessionRegistry,
        @node : Node,
        @subscriptions : SubscriptionManager,
        @sender : ResponseSender,
      )
      end

      # The clusters the Interaction Model resolves paths against.
      private def clusters : Hash(Tuple(UInt16, UInt32), Cluster::Base)
        @node.clusters
      end

      def handle(
        msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Nil
        Log.debug do
          "InteractionModel message: type=0x#{msg.payload_header.message_type.to_s(16)}, exchange=#{msg.payload_header.exchange_id}, " \
          "requires_ack=#{msg.payload_header.requires_acknowledge?}, initiator=#{msg.payload_header.initiator_message?}"
        end

        # Matter spec 4.11.8: a response carrying the acknowledged message id is
        # the ACK; a standalone one is only sent when the response is slow.
        case InteractionModel::MessageType.from_value?(msg.payload_header.message_type)
        when InteractionModel::MessageType::StatusResponse
          handle_status_response(msg.payload, msg, peer, session)
        when InteractionModel::MessageType::ReadRequest
          handle_read_request(msg.payload, msg, peer, session)
        when InteractionModel::MessageType::SubscribeRequest
          handle_subscribe_request(msg.payload, msg, peer, session)
        when InteractionModel::MessageType::WriteRequest
          handle_write_request(msg.payload, msg, peer, session)
        when InteractionModel::MessageType::InvokeRequest
          handle_invoke_request(msg.payload, msg, peer, session)
        when InteractionModel::MessageType::TimedRequest
          handle_timed_request(msg.payload, msg, peer, session)
        else
          Log.warn { "Unknown IM message type: 0x#{msg.payload_header.message_type.to_s(16)}" }
        end
      rescue ex
        Log.error(exception: ex) do
          "Error handling IM message: peer=#{peer.address}:#{peer.port} session_id=#{msg.packet_header.session_id} " \
          "msg_id=#{msg.packet_header.message_id} exchange=#{msg.payload_header.exchange_id} " \
          "type=0x#{msg.payload_header.message_type.to_s(16)} payload_hex=#{msg.payload.hexstring}"
        end
      end

      # ----------------------------------------------------------------------
      # Timed interactions
      # ----------------------------------------------------------------------

      # TimedRequest: arms the deadline the following Invoke or Write must meet.
      private def handle_timed_request(
        decrypted : Bytes,
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Nil
        exchange_id = original_msg.payload_header.exchange_id

        timeout_ms = 0_u16
        begin
          timeout_ms = InteractionModel::TimedRequestMessage.from_slice(decrypted).timeout
        rescue ex
          Log.error(exception: ex) do
            "TimedRequest: failed to parse request (session_id=#{session.session_id} exchange=#{exchange_id} bytes=#{decrypted.hexstring})"
          end
        end

        # Even an unparseable request is answered SUCCESS: some controllers
        # abort the interaction outright without a StatusResponse here.
        # The spec-defined timeout is a UInt16 of milliseconds, so at most ~65s.
        @timed_request_deadlines[{session.session_id, exchange_id}] = Time.instant + timeout_ms.milliseconds
        Log.info { "TimedRequest: timeout_ms=#{timeout_ms} (session_id=#{session.session_id} exchange=#{exchange_id})" }

        send_status(original_msg, peer, session, InteractionModel::StatusCode::Success)
      end

      # The request's timed flag must match whether this secure exchange was
      # armed. An expired TimedRequest is a timeout; a missing or extra flag is
      # TimedRequestMismatch. The deadline is spent in every case.
      private def timed_interaction_satisfied?(
        timed_request : Bool?,
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Bool
        deadline = @timed_request_deadlines.delete({session.session_id, original_msg.payload_header.exchange_id})
        if deadline && Time.instant > deadline
          Log.warn do
            "Request rejected: expired TimedRequest " \
            "(session_id=#{session.session_id} exchange=#{original_msg.payload_header.exchange_id} peer=#{peer.address}:#{peer.port})"
          end
          send_status(original_msg, peer, session, InteractionModel::StatusCode::Timeout)
          return false
        end

        return true if (timed_request == true) == !deadline.nil?

        Log.warn do
          "Request rejected: TimedRequest flag mismatch " \
          "(session_id=#{session.session_id} exchange=#{original_msg.payload_header.exchange_id} peer=#{peer.address}:#{peer.port})"
        end
        send_status(original_msg, peer, session, InteractionModel::StatusCode::TimedRequestMismatch)
        false
      end

      # ----------------------------------------------------------------------
      # Requests
      # ----------------------------------------------------------------------

      # StatusResponse: acknowledges a ReportData chunk of ours, or is a bare
      # acknowledgement we owe an ACK for.
      private def handle_status_response(
        decrypted : Bytes,
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Nil
        Log.debug { "Handling StatusResponse (exchange=#{original_msg.payload_header.exchange_id})" }

        status_code = InteractionModel::StatusCode::InvalidAction.value
        begin
          status_code = InteractionModel::StatusResponseMessage.from_slice(decrypted).status
          if status_code == InteractionModel::StatusCode::Success.value
            Log.debug { "StatusResponse: SUCCESS" }
          else
            Log.warn { "StatusResponse: status=0x#{status_code.to_s(16)}" }
          end
        rescue ex
          Log.error(exception: ex) { "Failed to parse StatusResponse (#{decrypted.size} bytes): #{decrypted.hexstring}" }
        end

        success = status_code == InteractionModel::StatusCode::Success.value
        return if @subscriptions.advance(original_msg.payload_header.exchange_id, original_msg, success)

        if original_msg.payload_header.requires_acknowledge?
          Log.trace { "StatusResponse requires ACK, sending standalone ACK" }
          @sender.send_encrypted_ack(original_msg, peer, session)
        end
      end

      # ReadRequest: read the paths and answer, chunking to stay inside the
      # UDP MTU.
      private def handle_read_request(
        decrypted : Bytes,
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Nil
        request = IMHandler.parse_read_request(decrypted)
        unless request
          Log.error { "Failed to parse ReadRequest" }
          return
        end

        event_requests = request.event_requests || [] of InteractionModel::EventPath
        Log.info do
          "ReadRequest: #{(request.attribute_requests || [] of InteractionModel::AttributePath).size} attribute(s) " \
          "and #{event_requests.size} event path(s) requested"
        end

        reports = read_attributes(request.attribute_requests, session,
          request.fabric_filtered != false, request.data_version_filters)
        events = read_events(request.event_requests, request.event_filters, session)
        chunks = IMHandler.encode_chunked_report_data(reports, nil, events,
          max_payload_size: @sender.im_payload_limit(session, peer))
        first_chunk, _ = chunks.first
        remaining_chunks = chunks[1..].map(&.[0])
        Log.debug { "ReadResponse: #{reports.size} attribute report(s), #{events.size} event report(s) in #{chunks.size} chunk(s)" }

        @sender.send_im_response(
          original_msg: original_msg,
          peer: peer,
          session: session,
          message_type: InteractionModel::MessageType::ReportData.value,
          payload: first_chunk,
          cache_for_mrp: true
        )

        return if remaining_chunks.empty?

        exchange_id = original_msg.payload_header.exchange_id
        @subscriptions.await_read(exchange_id, SubscriptionManager::PendingRead.new(
          peer: peer,
          session: session,
          remaining_chunks: remaining_chunks
        ))
        Log.debug { "Waiting for StatusResponse/ACK on exchange #{exchange_id} (#{remaining_chunks.size} chunks remaining)" }
      rescue ex
        Log.error(exception: ex) do
          "Error handling ReadRequest: peer=#{peer.address}:#{peer.port} session_id=#{session.session_id} " \
          "exchange=#{original_msg.payload_header.exchange_id} msg_id=#{original_msg.packet_header.message_id} " \
          "payload_hex=#{decrypted.hexstring}"
        end
      end

      # SubscribeRequest: send the priming report, then wait for the
      # controller's acknowledgement before the SubscribeResponse.
      #
      # Matter subscription flow: SubscribeRequest -> ReportData (with the
      # subscription id) -> StatusResponse -> SubscribeResponse.
      private def handle_subscribe_request(
        decrypted : Bytes,
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Nil
        request = IMHandler.parse_subscribe_request(decrypted)
        unless request
          Log.error { "Failed to parse SubscribeRequest" }
          return
        end

        attribute_requests = request.attribute_requests || [] of InteractionModel::AttributePath
        event_requests = request.event_requests || [] of InteractionModel::EventPath
        Log.info do
          "SubscribeRequest: #{attribute_requests.size} attribute(s), #{event_requests.size} event path(s), " \
          "min=#{request.min_interval_floor}s, max=#{request.max_interval_ceiling}s"
        end
        attribute_requests.each_with_index do |path, index|
          Log.debug { "  Subscribe #{index}: #{describe_path(path)}" }
        end
        event_requests.each_with_index do |path, index|
          Log.debug { "  Subscribe event #{index}: #{path}" }
        end

        @subscriptions.replace_subscriber_subscriptions(session) unless request.keep_subscriptions?

        subscription_id = @registry.allocate_subscription_id
        Log.info { "Created subscription #{subscription_id}" }

        reports = read_attributes(request.attribute_requests, session,
          request.is_fabric_filtered?, request.data_version_filters)
        # Captured before the read so nothing journaled between the two is
        # reported twice: the priming report never carries a higher number.
        last_event_number = @node.event_journal.latest_event_number
        events = read_events(request.event_requests, request.event_filters, session)
        chunks = IMHandler.encode_chunked_report_data(reports, subscription_id, events,
          max_payload_size: @sender.im_payload_limit(session, peer))
        first_chunk, _ = chunks.first
        remaining_chunks = chunks[1..].map(&.[0])
        Log.debug { "Initial ReportData: #{reports.size} attribute report(s), #{events.size} event report(s) in #{chunks.size} chunk(s)" }

        @sender.send_im_response(
          original_msg: original_msg,
          peer: peer,
          session: session,
          message_type: InteractionModel::MessageType::ReportData.value,
          payload: first_chunk,
          cache_for_mrp: true
        )

        # The exchange id correlates the acknowledgement with this subscription.
        exchange_id = original_msg.payload_header.exchange_id
        @subscriptions.await_subscription(exchange_id, SubscriptionManager::PendingSubscription.new(
          subscription_id: subscription_id,
          min_interval: request.min_interval_floor,
          max_interval: request.max_interval_ceiling,
          attribute_paths: attribute_requests.map do |path|
            InteractionModel::AttributePath.new(endpoint: path.endpoint, cluster: path.cluster, attribute: path.attribute)
          end,
          peer: peer,
          session: session,
          remaining_chunks: remaining_chunks,
          event_paths: event_requests,
          last_event_number: last_event_number,
          fabric_filtered: request.is_fabric_filtered?
        ))
        Log.debug { "Waiting for StatusResponse on exchange #{exchange_id} (#{remaining_chunks.size} chunks remaining)" }
      rescue ex
        Log.error(exception: ex) do
          "Error handling SubscribeRequest: peer=#{peer.address}:#{peer.port} session_id=#{session.session_id} " \
          "exchange=#{original_msg.payload_header.exchange_id} msg_id=#{original_msg.packet_header.message_id} " \
          "payload_hex=#{decrypted.hexstring}"
        end
      end

      # WriteRequest: apply the writes and answer with their statuses.
      private def handle_write_request(
        decrypted : Bytes,
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Nil
        request = IMHandler.parse_write_request(decrypted)
        unless request
          Log.error { "Failed to parse WriteRequest" }
          return
        end

        return unless timed_interaction_satisfied?(request.timed_request, original_msg, peer, session)

        if request.more_chunked_messages && request.timed_request
          send_status(original_msg, peer, session, InteractionModel::StatusCode::InvalidAction)
          return
        end

        Log.info { "WriteRequest: #{(request.write_requests || [] of InteractionModel::AttributeDataIB).size} attribute(s) to write" }

        now = Time.instant
        @write_list_states.reject! { |_key, state| state[1] <= now }
        exchange_key = {session.object_id, original_msg.payload_header.exchange_id}
        list_state = @write_list_states.delete(exchange_key).try(&.[0]) || IMHandler::WriteListState.new
        write_responses = IMHandler.write_attributes(
          request.write_requests,
          clusters,
          session_id: session.session_id,
          is_case_session: session.case_session?,
          fabric_index: session.fabric_index,
          peer_subject_ids: peer_subject_ids(session),
          list_state: list_state,
          timed_interaction: request.timed_request == true
        )
        @write_list_states[exchange_key] = {list_state, now + WRITE_CHUNK_TIMEOUT} if request.more_chunked_messages
        Log.debug { "WriteResponse: #{write_responses.size} status(es)" }

        @sender.send_im_response(
          original_msg: original_msg,
          peer: peer,
          session: session,
          message_type: InteractionModel::MessageType::WriteResponse.value,
          payload: IMHandler.encode_write_response(write_responses),
          cache_for_mrp: true
        )
        Log.debug { "Sent WriteResponse" }
      rescue ex
        Log.error(exception: ex) do
          "Error handling WriteRequest: peer=#{peer.address}:#{peer.port} session_id=#{session.session_id} " \
          "exchange=#{original_msg.payload_header.exchange_id} msg_id=#{original_msg.packet_header.message_id} " \
          "payload_hex=#{decrypted.hexstring}"
        end
      end

      # InvokeRequest: run the commands and answer with their responses.
      private def handle_invoke_request(
        decrypted : Bytes,
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
      ) : Nil
        request = IMHandler.parse_invoke_request(decrypted)
        unless request
          Log.error { "Failed to parse InvokeRequest" }
          return
        end

        return unless timed_interaction_satisfied?(request.timed_request, original_msg, peer, session)

        Log.info { "InvokeRequest: #{request.invoke_requests.size} command(s) requested" }

        invoke_responses = IMHandler.invoke_commands(
          request.invoke_requests,
          clusters,
          session.session_id.to_u64,
          session.case_session?,
          session.fabric_index,
          peer_subject_ids(session),
          peer,
          session.peer_icac,
          timed_interaction: request.timed_request == true,
          session_identity: session.object_id.to_u64,
          exchange_id: original_msg.payload_header.exchange_id
        )

        status_count = invoke_responses.count { |response| response.command_status != nil }
        Log.info { "InvokeResponse: #{invoke_responses.size} response(s), #{status_count} status(es)" }

        # SuppressResponse hides status-only results, but CommandDataIB still
        # requires an InvokeResponse (Core 8.8.3.2.1).
        if request.suppress_response && invoke_responses.none? { |response| response.command_data != nil }
          Log.info { "Response suppressed per suppressResponse flag" }
          @on_invoke_response_failed.try(&.call(session.object_id.to_u64, original_msg.payload_header.exchange_id))
          return
        end

        chunks = IMHandler.encode_chunked_invoke_response(invoke_responses,
          suppress_response: request.suppress_response || false,
          max_payload_size: @sender.im_payload_limit(session, peer))
        @sender.send_im_response(
          original_msg: original_msg,
          peer: peer,
          session: session,
          message_type: InteractionModel::MessageType::InvokeResponse.value,
          payload: chunks.first,
          cache_for_mrp: true
        )
        if chunks.size > 1
          @subscriptions.await_invoke(original_msg.payload_header.exchange_id,
            SubscriptionManager::PendingInvoke.new(peer, session, chunks[1..]))
        end
        @on_invoke_response_sent.try(&.call(session.object_id.to_u64, original_msg.payload_header.exchange_id))
        Log.info { "Sent InvokeResponse in #{chunks.size} chunk(s)" }
      rescue ex
        @on_invoke_response_failed.try(&.call(session.object_id.to_u64, original_msg.payload_header.exchange_id))
        Log.error(exception: ex) do
          "Error handling InvokeRequest: peer=#{peer.address}:#{peer.port} session_id=#{session.session_id} " \
          "exchange=#{original_msg.payload_header.exchange_id} msg_id=#{original_msg.packet_header.message_id} " \
          "payload_hex=#{decrypted.hexstring}"
        end
      end

      # ----------------------------------------------------------------------
      # Shared
      # ----------------------------------------------------------------------

      private def read_attributes(
        paths : Array(InteractionModel::AttributePath)?,
        session : Session::SecureContext,
        fabric_filtered : Bool = true,
        data_version_filters : Array(InteractionModel::DataVersionFilterIB)? = nil,
      ) : Array(InteractionModel::AttributeReportIB)
        IMHandler.read_attributes(
          paths,
          clusters,
          session.fabric_index,
          session.case_session?,
          peer_subject_ids(session),
          fabric_filtered,
          session.session_id.to_u64,
          data_version_filters,
          session.local_node_id.try(&.id)
        )
      end

      private def read_events(
        paths : Array(InteractionModel::EventPath)?,
        filters : Array(InteractionModel::EventFilterIB)?,
        session : Session::SecureContext,
      ) : Array(InteractionModel::EventReportIB)
        IMHandler.read_events(
          paths,
          @node.event_journal,
          clusters,
          filters,
          session.fabric_index,
          session.case_session?,
          peer_subject_ids(session),
          local_node_id: session.local_node_id.try(&.id)
        )
      end

      # The ACL subjects of *session*, or `nil` when it has none to check.
      private def peer_subject_ids(session : Session::SecureContext) : Array(UInt64)?
        session.peer_subject_ids.empty? ? nil : session.peer_subject_ids
      end

      private def send_status(
        original_msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
        status : InteractionModel::StatusCode,
      ) : Nil
        @sender.send_im_response(
          original_msg: original_msg,
          peer: peer,
          session: session,
          message_type: InteractionModel::MessageType::StatusResponse.value,
          payload: InteractionModel::StatusResponseMessage.new(status: status.value).to_slice,
          cache_for_mrp: true
        )
      end

      private def describe_path(path : InteractionModel::AttributePath) : String
        endpoint = path.endpoint.try(&.to_s) || "*"
        cluster = path.cluster.try { |cluster_id| "0x#{cluster_id.to_s(16)}" } || "*"
        attribute = path.attribute.try { |attribute_id| "0x#{attribute_id.to_s(16)}" } || "*"
        "endpoint=#{endpoint} cluster=#{cluster} attr=#{attribute}"
      end
    end
  end
end
