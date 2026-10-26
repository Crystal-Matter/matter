require "socket"

require "../interaction_model/paths"
require "../session/context"
require "../storage/record"

module Matter
  module Protocol
    # A subscription that has completed its handshake and is receiving reports.
    #
    # Created once the controller has acknowledged the priming ReportData and
    # the SubscribeResponse has gone out; matching changes queue for serialized
    # Report transactions on device-initiated exchanges.
    class ActiveSubscription
      property subscription_id : UInt32
      property min_interval : UInt16
      property max_interval : UInt16
      property peer : Socket::IPAddress
      property session : Session::SecureContext
      property attribute_paths : Array(InteractionModel::AttributePath)
      property event_paths : Array(InteractionModel::EventPath)
      property last_report_time : Time
      property exchange_id : UInt16

      # The highest event number this subscription has already reported. The
      # journal is drained from here on every report.
      property last_event_number : UInt64

      # The SubscribeRequest's fabric-filter choice applies to every report.
      getter? fabric_filtered : Bool

      def initialize(
        @subscription_id,
        @min_interval,
        @max_interval,
        @peer,
        @session,
        @attribute_paths,
        @exchange_id,
        @event_paths = [] of InteractionModel::EventPath,
        @last_event_number = 0_u64,
        @fabric_filtered = true,
      )
        @last_report_time = Time.utc
      end

      # Whether this subscription watches the given point, honouring the
      # wildcards a path may leave open.
      def matches?(endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32) : Bool
        @attribute_paths.any? do |path|
          endpoint_match = path.endpoint.nil? || path.endpoint == endpoint_id
          cluster_match = path.cluster.nil? || path.cluster == cluster_id
          attribute_match = path.attribute.nil? || path.attribute == attribute_id
          endpoint_match && cluster_match && attribute_match
        end
      end

      # Whether this subscription watches events at all.
      def events? : Bool
        !@event_paths.empty?
      end

      # Whether the subscription has gone silent for longer than the interval
      # the controller accepted.
      def expired?(now : Time = Time.utc) : Bool
        now > @last_report_time + @max_interval.seconds
      end

      # Whether the minimum interval the controller asked for has elapsed since
      # the last report, so a non-urgent change may go out now.
      def min_interval_elapsed?(now : Time = Time.utc) : Bool
        now >= @last_report_time + @min_interval.seconds
      end

      # One subscribed event path in its persisted form.
      struct EventPathRecord
        include Storage::Record

        getter node : UInt64?
        getter endpoint : UInt16?
        getter cluster : UInt32?
        getter event : UInt32?
        getter? urgent : Bool = false

        def initialize(@node : UInt64?, @endpoint : UInt16?, @cluster : UInt32?, @event : UInt32?, @urgent : Bool)
        end

        def self.from_path(path : InteractionModel::EventPath) : EventPathRecord
          new(path.node, path.endpoint, path.cluster, path.event, path.is_urgent?)
        end

        def to_path : InteractionModel::EventPath
          InteractionModel::EventPath.new(
            node: @node,
            endpoint: @endpoint,
            cluster: @cluster,
            event: @event,
            is_urgent: urgent?
          )
        end
      end

      # One subscribed attribute path in its persisted form.
      struct AttributePathRecord
        include Storage::Record

        getter endpoint : UInt16?
        getter cluster : UInt32?
        getter attribute : UInt32?
        getter list_index : UInt16?

        def initialize(@endpoint : UInt16?, @cluster : UInt32?, @attribute : UInt32?, @list_index : UInt16?)
        end

        def self.from_path(path : InteractionModel::AttributePath) : AttributePathRecord
          new(path.endpoint, path.cluster, path.attribute, path.list_index)
        end

        def to_path : InteractionModel::AttributePath
          InteractionModel::AttributePath.new(endpoint: @endpoint, cluster: @cluster, attribute: @attribute, list_index: @list_index)
        end
      end

      # The persisted form of a subscription (`subscriptions/<subscription_id>`).
      # The session is referenced by id and resolved on restore.
      struct SubscriptionRecord
        include Storage::Record

        getter subscription_id : UInt32
        getter min_interval : UInt16
        getter max_interval : UInt16
        getter peer_address : String
        getter peer_port : UInt16
        getter session_id : UInt16
        getter exchange_id : UInt16
        getter last_report_at : Time
        getter attribute_paths : Array(AttributePathRecord)

        # Added with event subscriptions; a store written before they existed
        # has neither key, so both carry a default rather than a nilable type.
        getter event_paths : Array(EventPathRecord) = [] of EventPathRecord
        getter last_event_number : UInt64 = 0_u64
        getter? fabric_filtered : Bool = true

        def initialize(
          @subscription_id : UInt32,
          @min_interval : UInt16,
          @max_interval : UInt16,
          @peer_address : String,
          @peer_port : UInt16,
          @session_id : UInt16,
          @exchange_id : UInt16,
          @last_report_at : Time,
          @attribute_paths : Array(AttributePathRecord),
          @event_paths : Array(EventPathRecord) = [] of EventPathRecord,
          @last_event_number : UInt64 = 0_u64,
          @fabric_filtered : Bool = true,
        )
        end
      end

      def to_record : SubscriptionRecord
        SubscriptionRecord.new(
          subscription_id: @subscription_id,
          min_interval: @min_interval,
          max_interval: @max_interval,
          peer_address: @peer.address,
          peer_port: @peer.port.to_u16,
          session_id: @session.session_id,
          exchange_id: @exchange_id,
          last_report_at: @last_report_time,
          attribute_paths: @attribute_paths.map { |path| AttributePathRecord.from_path(path) },
          event_paths: @event_paths.map { |path| EventPathRecord.from_path(path) },
          last_event_number: @last_event_number,
          fabric_filtered: @fabric_filtered
        )
      end

      # Rebuilds a subscription from its record and the resolved *session*.
      def self.from_record(record : SubscriptionRecord, session : Session::SecureContext) : ActiveSubscription
        subscription = new(
          subscription_id: record.subscription_id,
          min_interval: record.min_interval,
          max_interval: record.max_interval,
          peer: Socket::IPAddress.new(record.peer_address, record.peer_port.to_i),
          session: session,
          attribute_paths: record.attribute_paths.map(&.to_path),
          exchange_id: record.exchange_id,
          event_paths: record.event_paths.map(&.to_path),
          last_event_number: record.last_event_number,
          fabric_filtered: record.fabric_filtered?
        )
        subscription.last_report_time = record.last_report_at
        subscription
      end
    end
  end
end
