require "log"
require "socket"

require "../codec/message_codec"
require "../interaction_model/paths"
require "../interaction_model/tlv_messages"
require "../event_journal"
require "../node"
require "../session/context"
require "./im_handler"
require "./message_type"
require "./response_sender"
require "./session_registry"
require "./subscription"

module Matter
  module Protocol
    # Drives subscriptions: the chunked priming report, the SubscribeResponse
    # that completes the handshake, and every report a cluster change raises
    # afterwards.
    #
    # Reports originate on arbitrary fibers - a cluster callback, a device
    # timer, an endpoint added at runtime - so every method here runs inside
    # `SessionRegistry#synchronize`, the same lock inbound message handling
    # takes.
    class SubscriptionManager
      Log                   = ::Log.for("matter.protocol.subscription_manager")
      REPORT_STATUS_TIMEOUT = 30.seconds

      # An exchange with chunks still to send, waiting for the controller to
      # acknowledge the chunk in flight.
      abstract class PendingChunks
        getter peer : Socket::IPAddress
        getter session : Session::SecureContext
        getter remaining_chunks : Array(Bytes)

        def initialize(@peer, @session, @remaining_chunks)
        end

        # Takes the next chunk off the queue, or `nil` when none are left.
        def next_chunk : Bytes?
          @remaining_chunks.shift?
        end

        def more_chunks? : Bool
          !@remaining_chunks.empty?
        end
      end

      # A ReadRequest whose response did not fit in one message.
      class PendingRead < PendingChunks
      end

      # An InvokeRequest whose command responses span multiple messages.
      class PendingInvoke < PendingChunks
        getter on_sent : Proc(Nil)?
        getter on_failed : Proc(Nil)?

        def initialize(peer : Socket::IPAddress, session : Session::SecureContext,
                       remaining_chunks : Array(Bytes), @on_sent : Proc(Nil)? = nil,
                       @on_failed : Proc(Nil)? = nil)
          super(peer, session, remaining_chunks)
        end
      end

      # One active subscription Report transaction. Its dirty attribute keys
      # and event cursor are committed only after the final IM Status.Success.
      class PendingUpdate < PendingChunks
        getter subscription_id : UInt32
        getter event_cursor : UInt64?
        getter dirty_attributes : Set(Tuple(UInt16, UInt32, UInt32))
        property last_progress_at : Time::Span

        def initialize(@subscription_id, @event_cursor, @dirty_attributes,
                       peer : Socket::IPAddress, session : Session::SecureContext,
                       remaining_chunks : Array(Bytes))
          super(peer, session, remaining_chunks)
          @last_progress_at = Time.monotonic
        end
      end

      # A SubscribeRequest whose priming report is still being delivered. The
      # subscription becomes active once the last chunk is acknowledged.
      class PendingSubscription < PendingChunks
        getter subscription_id : UInt32
        getter min_interval : UInt16
        getter max_interval : UInt16
        getter attribute_paths : Array(InteractionModel::AttributePath)
        getter event_paths : Array(InteractionModel::EventPath)

        # The highest event number the priming report carried, so the first
        # update does not repeat what the controller has already seen.
        getter last_event_number : UInt64

        def initialize(
          @subscription_id,
          @min_interval,
          @max_interval,
          @attribute_paths,
          peer : Socket::IPAddress,
          session : Session::SecureContext,
          remaining_chunks : Array(Bytes),
          @event_paths = [] of InteractionModel::EventPath,
          @last_event_number = 0_u64,
        )
          super(peer, session, remaining_chunks)
        end
      end

      # Exchange IDs are scoped to sessions; two controllers may reuse one.
      alias ExchangeKey = Tuple(UInt16, UInt16)
      @pending_subscriptions : Hash(ExchangeKey, PendingSubscription) = {} of ExchangeKey => PendingSubscription
      @pending_reads : Hash(ExchangeKey, PendingRead) = {} of ExchangeKey => PendingRead
      @pending_invokes : Hash(ExchangeKey, PendingInvoke) = {} of ExchangeKey => PendingInvoke
      @pending_updates : Hash(ExchangeKey, PendingUpdate) = {} of ExchangeKey => PendingUpdate
      @inflight_updates = {} of UInt32 => ExchangeKey
      alias AttributeKey = Tuple(UInt16, UInt32, UInt32)
      @dirty_attributes = {} of UInt32 => Set(AttributeKey)

      def initialize(
        @registry : SessionRegistry,
        @node : Node,
        @sender : ResponseSender,
      )
      end

      # Tracks a subscription whose priming report has begun, so the
      # controller's acknowledgement can carry it to completion.
      def await_subscription(exchange_id : UInt16, pending : PendingSubscription) : Nil
        @registry.synchronize { @pending_subscriptions[{pending.session.session_id, exchange_id}] = pending }
      end

      # A new SubscribeRequest with KeepSubscriptions=false terminates both
      # active and in-flight subscriptions from the same CASE subscriber.
      # Matching by fabric and node rather than session survives CASE renewal.
      def replace_subscriber_subscriptions(session : Session::SecureContext) : Nil
        fabric_index = session.fabric_index
        peer_node_id = session.peer_node_id
        return unless session.case_session? && fabric_index && peer_node_id

        @registry.synchronize do
          @pending_subscriptions.reject! do |_exchange_id, pending|
            owner = pending.session
            owner.case_session? && owner.fabric_index == fabric_index && owner.peer_node_id.try(&.id) == peer_node_id.id
          end
          @registry.remove_subscriptions_for_subscriber(fabric_index, peer_node_id.id)
        end
      end

      # Tracks a read response with chunks still to send.
      def await_read(exchange_id : UInt16, pending : PendingRead) : Nil
        @registry.synchronize { @pending_reads[{pending.session.session_id, exchange_id}] = pending }
      end

      def await_invoke(exchange_id : UInt16, pending : PendingInvoke) : Nil
        @registry.synchronize { @pending_invokes[{pending.session.session_id, exchange_id}] = pending }
      end

      # Advances the chunked exchange *exchange_id*, returning whether it was
      # one of ours.
      #
      # Priming and read chunks accept StatusResponse or iOS's bare MRP ACK.
      # Active subscription updates require an IM StatusResponse; transport
      # acknowledgement alone cannot commit the report transaction. *trigger*
      # is the message the next chunk answers.
      def advance(exchange_id : UInt16, trigger : Codec::MessageCodec::Message, success : Bool = true) : Bool
        @registry.synchronize do
          key = {trigger.packet_header.session_id, exchange_id}
          if pending = @pending_subscriptions[key]?
            unless success
              @pending_subscriptions.delete(key)
              Log.warn { "Subscription #{pending.subscription_id} aborted: peer rejected a ReportData chunk" }
              return true
            end

            if chunk = pending.next_chunk
              Log.debug { "Subscription #{pending.subscription_id}: sending next chunk (#{pending.remaining_chunks.size} remaining)" }
              send_chunk(pending, trigger, chunk)
            else
              @pending_subscriptions.delete(key)
              complete_subscription(pending, trigger, exchange_id)
            end

            return true
          end

          if pending = @pending_updates[key]?
            # MRP only confirms transport delivery. Chunk ordering and
            # successful completion require an IM StatusResponse.
            return false unless trigger.payload_header.protocol_id == ProtocolId::InteractionModel.value &&
                                trigger.payload_header.message_type == InteractionModel::MessageType::StatusResponse.value
            unless success
              @pending_updates.delete(key)
              @inflight_updates.delete(pending.subscription_id)
              @dirty_attributes.delete(pending.subscription_id)
              @registry.remove_subscription(pending.subscription_id)
              @sender.send_encrypted_ack(trigger, pending.peer, pending.session) if trigger.payload_header.requires_acknowledge?
              Log.warn { "Subscription #{pending.subscription_id} terminated: subscriber rejected ReportData" }
              return true
            end

            if chunk = pending.remaining_chunks.first?
              send_chunk(pending, trigger, chunk)
              pending.next_chunk
              pending.last_progress_at = Time.monotonic
            else
              @pending_updates.delete(key)
              @inflight_updates.delete(pending.subscription_id)
              if subscription = @registry.active_subscriptions[pending.subscription_id]?
                if cursor = pending.event_cursor
                  subscription.last_event_number = cursor
                end
                subscription.last_report_time = Time.utc
              end
              @sender.send_encrypted_ack(trigger, pending.peer, pending.session) if trigger.payload_header.requires_acknowledge?
            end
            return true
          end

          if pending = @pending_reads[key]?
            unless success
              @pending_reads.delete(key)
              Log.warn { "Read response aborted: peer rejected a ReportData chunk (exchange=#{exchange_id})" }
              return true
            end

            if chunk = pending.next_chunk
              Log.debug { "Read response: sending next chunk (#{pending.remaining_chunks.size} remaining)" }
              send_chunk(pending, trigger, chunk)
            end
            @pending_reads.delete(key) unless pending.more_chunks?

            return true
          end

          if pending = @pending_invokes[key]?
            # InvokeResponse chunking requires an IM Status.Success. A transport
            # MRP acknowledgement only confirms datagram delivery.
            return false unless trigger.payload_header.protocol_id == ProtocolId::InteractionModel.value &&
                                trigger.payload_header.message_type == InteractionModel::MessageType::StatusResponse.value
            unless success
              @pending_invokes.delete(key)
              pending.on_failed.try(&.call)
              Log.warn { "Invoke response aborted: peer rejected a chunk (exchange=#{exchange_id})" }
              return true
            end

            if chunk = pending.remaining_chunks.first?
              Log.debug { "Invoke response: sending next chunk (#{pending.remaining_chunks.size} remaining)" }
              begin
                send_chunk(pending, trigger, chunk)
                pending.next_chunk
              rescue ex
                @pending_invokes.delete(key)
                pending.on_failed.try(&.call)
                raise ex
              end
            end
            unless pending.more_chunks?
              @pending_invokes.delete(key)
              pending.on_sent.try(&.call)
            end

            return true
          end

          false
        end
      end

      # Reports one changed attribute to every subscription watching it.
      def notify(endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32) : Nil
        notify_batched([{endpoint_id, cluster_id, attribute_id}])
      end

      # Queues a batch of changed attributes, coalescing one ReportData per
      # subscription when its minimum interval permits.
      #
      # Batching matters: controllers (iOS especially) throttle a device that
      # sends a report per attribute during a burst of changes.
      def notify_batched(attributes : Array(Tuple(UInt16, UInt32, UInt32))) : Nil
        return if attributes.empty?

        @registry.synchronize do
          subscriptions = @registry.active_subscriptions
          prune_inflight_updates(subscriptions)
          Log.debug { "notify_batched: #{attributes.size} attribute(s), active=#{subscriptions.size}" }
          return if subscriptions.empty?

          subscriptions.each_value do |subscription|
            dirty = @dirty_attributes.put_if_absent(subscription.subscription_id) { Set(AttributeKey).new }
            attributes.each do |attribute|
              dirty << attribute if subscription.matches?(*attribute)
            end
            next unless subscription.min_interval_elapsed?
            next if @inflight_updates.has_key?(subscription.subscription_id)

            reports = collect_reports(subscription, dirty.to_a)
            # Every report drains whatever the journal still owes this
            # subscription, so a non-urgent event rides out with the next
            # attribute change rather than waiting for its own report.
            events = pending_events(subscription)
            next if reports.empty? && events.empty?

            Log.debug { "Sending batched subscription update: subscription_id=#{subscription.subscription_id}, peer=#{subscription.peer}, reports=#{reports.size}, events=#{events.size}" }
            send_update(subscription, reports, events)
          end
        end
      end

      # Run before the registry's expiry sweep: a quiet subscriber still needs
      # a ReportData at MaxInterval, while dirty values wait for MinInterval.
      def tick(now : Time = Time.utc, monotonic_now : Time::Span = Time.monotonic) : Nil
        @registry.synchronize do
          subscriptions = @registry.active_subscriptions
          prune_inflight_updates(subscriptions, monotonic_now)
          @dirty_attributes.reject! { |id, _| !subscriptions.has_key?(id) }

          subscriptions.each_value do |subscription|
            dirty = @dirty_attributes[subscription.subscription_id]?
            min_elapsed = subscription.min_interval_elapsed?(now)
            max_elapsed = now >= subscription.last_report_time + subscription.max_interval.seconds
            next unless min_elapsed
            next if @inflight_updates.has_key?(subscription.subscription_id)
            report_due = max_elapsed || dirty.try(&.empty?) == false || subscription.events?
            next unless report_due

            reports = dirty ? collect_reports(subscription, dirty.to_a) : [] of InteractionModel::AttributeReportIB
            events = pending_events(subscription)
            next if reports.empty? && events.empty? && !max_elapsed

            send_update(subscription, reports, events)
          end
        end
      end

      # Reports newly journaled events to every subscription watching them.
      #
      # A subscription's minimum interval damps ordinary events: they wait in
      # the journal until the interval has elapsed (or until an attribute
      # report goes out and takes them along). An event on a path the
      # controller marked urgent goes out immediately, which is what
      # `EventPath#is_urgent?` is for.
      def notify_events : Nil
        @registry.synchronize do
          subscriptions = @registry.active_subscriptions
          prune_inflight_updates(subscriptions)
          return if subscriptions.empty?

          now = Time.utc
          subscriptions.each_value do |subscription|
            next unless subscription.events?

            records = journal_records(subscription)
            next if records.empty?

            urgent = records.any?(&.urgent_for?(subscription.event_paths))
            next unless urgent || subscription.min_interval_elapsed?(now)
            next if @inflight_updates.has_key?(subscription.subscription_id)

            Log.debug do
              "Sending event report: subscription_id=#{subscription.subscription_id}, " \
              "events=#{records.size}, urgent=#{urgent}"
            end
            send_update(subscription, [] of InteractionModel::AttributeReportIB, event_reports(subscription, records))
          end
        end
      end

      # One Report transaction may need several ReportData messages. Keep
      # them on one exchange and wait for each IM status before proceeding.
      private def send_update(
        subscription : ActiveSubscription,
        reports : Array(InteractionModel::AttributeReportIB),
        events : Array(InteractionModel::EventReportIB),
      ) : Nil
        return if @inflight_updates.has_key?(subscription.subscription_id)
        limit = @sender.im_payload_limit(subscription.session, subscription.peer)
        chunks = IMHandler.encode_chunked_report_data(reports, subscription.subscription_id,
          events, max_payload_size: limit)
        dirty = @dirty_attributes[subscription.subscription_id]? || Set(AttributeKey).new
        @dirty_attributes[subscription.subscription_id] = Set(AttributeKey).new
        cursor = events.reverse_each.compact_map(&.event_data).first?.try(&.event_number)
        begin
          exchange_id = @sender.send_report(subscription.session, subscription.peer, chunks.first[0])
          key = {subscription.session.session_id, exchange_id}
          @pending_updates[key] = PendingUpdate.new(subscription.subscription_id, cursor, dirty,
            subscription.peer, subscription.session, chunks[1..].map(&.[0]))
          @inflight_updates[subscription.subscription_id] = key
        rescue ex
          @dirty_attributes[subscription.subscription_id].concat(dirty)
          raise ex
        end
        subscription.last_report_time = Time.utc
      end

      private def prune_inflight_updates(subscriptions : Hash(UInt32, ActiveSubscription),
                                         monotonic_now : Time::Span = Time.monotonic) : Nil
        @inflight_updates.reject! do |subscription_id, key|
          pending = @pending_updates[key]?
          subscription = subscriptions[subscription_id]?
          timed_out = false
          if pending && subscription && subscription.session.session_id == pending.session.session_id
            if monotonic_now < pending.last_progress_at + REPORT_STATUS_TIMEOUT
              next false
            end
            # §8.5 permits termination when a ReportData with
            # SuppressResponse=false receives no IM StatusResponse. This
            # avoids blocking later deltas indefinitely behind that exchange.
            timed_out = true
            @registry.remove_subscription(subscription_id)
            Log.warn { "Subscription #{subscription_id} terminated: ReportData status timed out" }
          end
          @pending_updates.delete(key)
          if subscription && pending && !timed_out
            # CASE renewal kept the subscription but abandoned the old
            # exchange. Replay its snapshot on the new session.
            dirty = @dirty_attributes.put_if_absent(subscription_id) { Set(AttributeKey).new }
            dirty.concat(pending.dirty_attributes)
          else
            @dirty_attributes.delete(subscription_id)
          end
          true
        end
      end

      # The journal records *subscription* has not reported yet, in event
      # number order.
      private def journal_records(subscription : ActiveSubscription) : Array(EventJournal::Record)
        return [] of EventJournal::Record unless subscription.events?

        @node.event_journal.query(
          subscription.event_paths,
          after: subscription.last_event_number,
          fabric_index: subscription.session.fabric_index
        )
      end

      # Turns *records* into reports. The cursor advances only after sending.
      private def event_reports(
        subscription : ActiveSubscription,
        records : Array(EventJournal::Record),
      ) : Array(InteractionModel::EventReportIB)
        return [] of InteractionModel::EventReportIB if records.empty?

        records.map { |record| InteractionModel::EventReportIB.new(event_data: IMHandler.build_event_data(record)) }
      end

      # Everything the journal owes *subscription*, ready to report.
      private def pending_events(subscription : ActiveSubscription) : Array(InteractionModel::EventReportIB)
        event_reports(subscription, journal_records(subscription))
      end

      # The reports *subscription* wants out of *attributes*, read at the
      # subscriber's fabric.
      private def collect_reports(
        subscription : ActiveSubscription,
        attributes : Array(Tuple(UInt16, UInt32, UInt32)),
      ) : Array(InteractionModel::AttributeReportIB)
        reports = [] of InteractionModel::AttributeReportIB

        attributes.each do |(endpoint_id, cluster_id, attribute_id)|
          next unless subscription.matches?(endpoint_id, cluster_id, attribute_id)

          cluster = @node.clusters[{endpoint_id, cluster_id}]?
          unless cluster
            Log.warn { "Subscription update skipped: cluster not found (endpoint=#{endpoint_id}, cluster=0x#{cluster_id.to_s(16)})" }
            next
          end

          value = cluster.read_attribute(attribute_id, subscription.session.fabric_index)
          unless value.is_a?(TLV::Any)
            Log.warn { "Subscription update skipped: read_attribute returned #{value.class} (endpoint=#{endpoint_id}, cluster=0x#{cluster_id.to_s(16)}, attr=0x#{attribute_id.to_s(16)})" }
            next
          end

          attribute_data = InteractionModel::AttributeDataIB.new(
            path: InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id),
            data: value,
            data_version: cluster.data_version
          )
          reports << InteractionModel::AttributeReportIB.new(attribute_data: attribute_data)
        end

        reports
      end

      private def send_chunk(pending : PendingChunks, trigger : Codec::MessageCodec::Message, chunk : Bytes) : Nil
        @sender.send_im_response(
          original_msg: trigger,
          peer: pending.peer,
          session: pending.session,
          message_type: pending.is_a?(PendingInvoke) ? InteractionModel::MessageType::InvokeResponse.value : InteractionModel::MessageType::ReportData.value,
          payload: chunk,
          cache_for_mrp: true
        )
      end

      # Answers the last acknowledgement with the SubscribeResponse and moves
      # the subscription into the registry, where reports find it.
      private def complete_subscription(
        pending : PendingSubscription,
        trigger : Codec::MessageCodec::Message,
        exchange_id : UInt16,
      ) : Nil
        Log.debug { "All ReportData chunks sent for subscription #{pending.subscription_id}; sending SubscribeResponse" }

        payload = IMHandler.encode_subscribe_response(pending.subscription_id, pending.max_interval)
        Log.trace { "Encoded SubscribeResponse TLV (#{payload.size} bytes): #{payload.hexstring}" }

        @sender.send_im_response(
          original_msg: trigger,
          peer: pending.peer,
          session: pending.session,
          message_type: InteractionModel::MessageType::SubscribeResponse.value,
          payload: payload
        )

        @registry.add_subscription(ActiveSubscription.new(
          subscription_id: pending.subscription_id,
          min_interval: pending.min_interval,
          max_interval: pending.max_interval,
          peer: pending.peer,
          session: pending.session,
          attribute_paths: pending.attribute_paths,
          exchange_id: exchange_id,
          event_paths: pending.event_paths,
          last_event_number: pending.last_event_number
        ))
      end
    end
  end
end
