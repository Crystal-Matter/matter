require "./im_client"

module Matter
  module Controller
    # A dedicated CASE client owns one attribute/event subscription. The
    # controller acknowledges each ReportData at the Interaction Model layer
    # and checks the subscription id on every subsequent report. Call
    # #next_report before MaxInterval elapses.
    class AttributeSubscription
      alias Report = InteractionModel::ReportDataMessage
      MAX_REPORT_CHUNKS = ImClient::MAX_READ_REPORT_CHUNKS
      MAX_REPORT_BYTES  = ImClient::MAX_READ_REPORT_BYTES

      getter subscription_id : UInt32
      getter max_interval : UInt16
      getter initial_reports : Array(Report)
      getter last_report_at : Time::Instant

      def initialize(@client : Client, @session : Session::SecureContext,
                     @peer : Socket::IPAddress, paths : Array(InteractionModel::AttributePath),
                     min_interval : UInt16 = 0_u16, max_interval : UInt16 = 60_u16,
                     @timeout : Time::Span = 10.seconds,
                     event_paths : Array(InteractionModel::EventPath) = [] of InteractionModel::EventPath,
                     event_filters : Array(InteractionModel::EventFilterIB)? = nil,
                     data_version_filters : Array(InteractionModel::DataVersionFilterIB)? = nil)
        if (paths.empty? && event_paths.empty?) || max_interval == 0_u16 || max_interval < min_interval
          raise Matter::ConfigurationError.new("Invalid subscription intervals")
        end
        request = InteractionModel::SubscribeRequestMessage.new(
          keep_subscriptions: false,
          min_interval_floor: min_interval,
          max_interval_ceiling: max_interval,
          attribute_requests: paths.empty? ? nil : paths,
          event_requests: event_paths.empty? ? nil : event_paths,
          event_filters: event_filters,
          data_version_filters: data_version_filters,
          is_fabric_filtered: true,
          interaction_model_revision: InteractionModel::INTERACTION_MODEL_REVISION)
        exchange_id = @client.send_encrypted_request(@session, @peer,
          Client::PROTOCOL_INTERACTION_MODEL,
          InteractionModel::MessageType::SubscribeRequest.value,
          request.to_slice)
        @initial_reports = [] of Report
        @subscription_id = 0_u32
        @max_interval = 0_u16
        @last_report_at = Time.instant
        receive_initial(exchange_id)
      end

      def initialize(client : Client, session : Session::SecureContext,
                     peer : Socket::IPAddress, path : InteractionModel::AttributePath,
                     min_interval : UInt16 = 0_u16, max_interval : UInt16 = 60_u16,
                     timeout : Time::Span = 10.seconds)
        initialize(client, session, peer, [path], min_interval, max_interval, timeout)
      end

      # Returns one logical update (which may have multiple ReportData chunks).
      # A timeout is a recovery signal: the caller must establish a new CASE
      # session and subscription before trusting a replacement Anchor.
      def next_report(timeout_span : Time::Span = (@max_interval.to_i + 5).seconds) : Array(Report)
        first = receive_relevant(timeout_span)
        collect_report(first)
      end

      # A short poll may find no report while the subscription is healthy.
      # Only the negotiated MaxInterval plus a bounded grace period signals a
      # stale stream that requires CASE and subscription renewal.
      def poll_report(timeout_span : Time::Span) : Array(Report)?
        assert_live!
        remaining = expiry_at - Time.instant
        first = begin
          receive_relevant({timeout_span, remaining}.min)
        rescue Matter::TimeoutError
          assert_live!
          return
        end
        collect_report(first)
      end

      private def collect_report(first : Client::ReceivedMessage) : Array(Report)
        unless first.message.payload_header.message_type == InteractionModel::MessageType::ReportData.value
          raise Matter::ProtocolError.new("Subscription expected ReportData")
        end
        exchange_id = first.message.payload_header.exchange_id
        reports = [] of Report
        bytes_received = 0
        received = first
        loop do
          bytes_received += received.message.payload.size
          if reports.size >= MAX_REPORT_CHUNKS || bytes_received > MAX_REPORT_BYTES
            raise Matter::ProtocolError.new("Subscription report exceeded chunk limit")
          end
          record_report(received, reports, exchange_id)
          break unless reports.last.more_chunked_messages
          received = receive_relevant(@timeout)
        end
        reports
      end

      private def expiry_at : Time::Instant
        @last_report_at + (@max_interval.to_i + 5).seconds
      end

      private def assert_live! : Nil
        if Time.instant >= expiry_at
          raise Matter::TimeoutError.new("Datastore subscription exceeded MaxInterval")
        end
      end

      private def receive_initial(exchange_id : UInt16) : Nil
        bytes_received = 0
        loop do
          received = receive_relevant(@timeout)
          message = received.message
          unless message.payload_header.exchange_id == exchange_id
            raise Matter::ProtocolError.new("Subscription handshake changed exchange")
          end
          case message.payload_header.message_type
          when InteractionModel::MessageType::ReportData.value
            bytes_received += message.payload.size
            if @initial_reports.size >= MAX_REPORT_CHUNKS || bytes_received > MAX_REPORT_BYTES
              raise Matter::ProtocolError.new("Subscription priming exceeded chunk limit")
            end
            record_report(received, @initial_reports, exchange_id)
          when InteractionModel::MessageType::SubscribeResponse.value
            if @initial_reports.empty? || @initial_reports.last.more_chunked_messages
              raise Matter::ProtocolError.new("SubscribeResponse preceded final priming report")
            end
            response = InteractionModel::SubscribeResponseMessage.from_slice(message.payload.to_slice)
            unless response.subscription_id == @subscription_id && response.max_interval > 0_u16
              raise Matter::ProtocolError.new("SubscribeResponse identity or interval mismatch")
            end
            @max_interval = response.max_interval
            return
          else
            raise Matter::ProtocolError.new("Unexpected message during subscription handshake")
          end
        end
      end

      private def record_report(received : Client::ReceivedMessage, reports : Array(Report),
                                exchange_id : UInt16) : Nil
        message = received.message
        unless message.payload_header.exchange_id == exchange_id &&
               message.payload_header.message_type == InteractionModel::MessageType::ReportData.value
          raise Matter::ProtocolError.new("Unexpected subscription report exchange")
        end
        report = Report.from_slice(message.payload.to_slice)
        id = report.subscription_id || raise Matter::ProtocolError.new("Subscription report omitted ID")
        if @subscription_id == 0_u32
          @subscription_id = id
        elsif id != @subscription_id
          raise Matter::AuthenticationError.new("Subscription ID changed")
        end
        if status = report.attribute_reports.try(&.find(&.attribute_status)).try(&.attribute_status)
          raise Matter::ProtocolError.new("Subscription attribute status #{status.status.status}")
        end
        if status = report.event_reports.try(&.find(&.event_status)).try(&.event_status)
          raise Matter::ProtocolError.new("Subscription event status #{status.status.status}")
        end
        reports << report
        @last_report_at = Time.instant
        @client.send_encrypted_request(@session, @peer,
          Client::PROTOCOL_INTERACTION_MODEL,
          InteractionModel::MessageType::StatusResponse.value,
          InteractionModel::StatusResponseMessage.new(
            InteractionModel::StatusCode::Success.value).to_slice,
          exchange_id: exchange_id,
          initiator_message: !message.payload_header.initiator_message?,
          acknowledged_message_id: message.packet_header.message_id)
      end

      private def receive_relevant(timeout_span : Time::Span) : Client::ReceivedMessage
        deadline = Time.instant + timeout_span
        loop do
          remaining = deadline - Time.instant
          raise Matter::TimeoutError.new("Datastore subscription timed out") if remaining <= 0.seconds
          received = @client.receive_message(remaining) ||
                     raise Matter::TimeoutError.new("Datastore subscription timed out")
          message = received.message
          # Client only delivers encrypted messages after validating the
          # registered CASE session's AEAD and replay counter. UDP may present
          # the same peer as IPv4 or IPv4-mapped IPv6, so its socket spelling
          # is not an identity check.
          next unless message.packet_header.session_id == @session.session_id &&
                      message.payload_header.protocol_id == Client::PROTOCOL_INTERACTION_MODEL
          if message.payload_header.message_type == InteractionModel::MessageType::StatusResponse.value
            status = InteractionModel::StatusResponseMessage.from_slice(message.payload.to_slice)
            raise Matter::ProtocolError.new("Subscription rejected: IM status #{status.status}")
          end
          return received
        end
      end
    end

    class ImClient
      def subscribe_events(session : Session::SecureContext, peer : Socket::IPAddress,
                           paths : Array(InteractionModel::EventPath),
                           event_min : UInt64? = nil,
                           min_interval : UInt16 = 0_u16, max_interval : UInt16 = 60_u16) : AttributeSubscription
        filters = event_min.try { |number| [InteractionModel::EventFilterIB.new(number)] }
        AttributeSubscription.new(@client, session, peer, [] of InteractionModel::AttributePath,
          min_interval, max_interval, @timeout, paths, filters)
      end

      def subscribe(session : Session::SecureContext, peer : Socket::IPAddress,
                    attribute_paths : Array(InteractionModel::AttributePath) = [] of InteractionModel::AttributePath,
                    event_paths : Array(InteractionModel::EventPath) = [] of InteractionModel::EventPath,
                    event_filters : Array(InteractionModel::EventFilterIB)? = nil,
                    min_interval : UInt16 = 0_u16, max_interval : UInt16 = 60_u16,
                    data_version_filters : Array(InteractionModel::DataVersionFilterIB)? = nil) : AttributeSubscription
        AttributeSubscription.new(@client, session, peer, attribute_paths,
          min_interval, max_interval, @timeout, event_paths, event_filters, data_version_filters)
      end

      def subscribe_attributes(session : Session::SecureContext, peer : Socket::IPAddress,
                               paths : Array(InteractionModel::AttributePath),
                               min_interval : UInt16 = 0_u16, max_interval : UInt16 = 60_u16) : AttributeSubscription
        AttributeSubscription.new(@client, session, peer, paths,
          min_interval, max_interval, @timeout)
      end

      def subscribe_attribute(session : Session::SecureContext, peer : Socket::IPAddress,
                              endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                              min_interval : UInt16 = 0_u16, max_interval : UInt16 = 60_u16) : AttributeSubscription
        AttributeSubscription.new(@client, session, peer,
          InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id,
            attribute: attribute_id), min_interval, max_interval, @timeout)
      end
    end
  end
end
