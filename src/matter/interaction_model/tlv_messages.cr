require "tlv"
require "./paths"
require "./status_code"

module Matter
  module InteractionModel
    # Interaction Model revision advertised in every IM message (Matter 1.3)
    INTERACTION_MODEL_REVISION = 12_u8

    # Context tag carrying the InteractionModelRevision field in every IM
    # message. `TLV::Field` requires a literal tag, so the annotations below
    # spell out `0xFF`; keep them in sync with this constant.
    INTERACTION_MODEL_REVISION_TAG = 0xFF_u8

    enum MessageType : UInt8
      StatusResponse    = 0x01
      ReadRequest       = 0x02
      SubscribeRequest  = 0x03
      SubscribeResponse = 0x04
      ReportData        = 0x05
      WriteRequest      = 0x06
      WriteResponse     = 0x07
      InvokeRequest     = 0x08
      InvokeResponse    = 0x09
      TimedRequest      = 0x0A
    end

    # Default `MaxIntervalCeiling` for subscribe requests we originate
    DEFAULT_MAX_INTERVAL_CEILING_SECONDS = 3600_u16

    # Control byte of a TLV Null element with an anonymous tag. Raw attribute
    # values are delivered to clusters as element bytes rather than TLV, so a
    # null is passed through as this single byte.

    # Event priority levels (used by clusters for event metadata)
    enum EventPriority : UInt8
      Debug    = 0
      Info     = 1
      Critical = 2
    end

    # TLV-serializable IM message structures matching matter.js schemas

    # AttributeDataIB - per matter.js TlvAttributeReportData
    # Note: fixed_size: true on data_version ensures 4-byte encoding for iOS compatibility
    struct AttributeDataIB
      include TLV::Serializable

      # Tag 0: DataVersion (optional, fixed 4-byte for iOS compatibility)
      @[TLV::Field(tag: 0, optional: true, fixed_size: true)]
      property data_version : UInt32?

      # Tag 1: Path
      @[TLV::Field(tag: 1)]
      property path : AttributePath

      # Tag 2: Data (TLV::Any - the actual attribute value)
      @[TLV::Field(tag: 2)]
      property data : TLV::Any

      def initialize(@path : AttributePath, @data : TLV::Any, @data_version : UInt32? = nil)
      end
    end

    # StatusIB - status code structure
    struct StatusIB
      include TLV::Serializable

      # Tag 0: Status code
      @[TLV::Field(tag: 0)]
      property status : UInt8

      # Tag 1: Cluster-specific status (optional)
      @[TLV::Field(tag: 1, optional: true)]
      property cluster_status : UInt8?

      def initialize(@status : UInt8, @cluster_status : UInt8? = nil)
      end
    end

    # AttributeStatusIB - attribute with status (on error)
    struct AttributeStatusIB
      include TLV::Serializable

      # Tag 0: Path
      @[TLV::Field(tag: 0)]
      property path : AttributePath

      # Tag 1: Status
      @[TLV::Field(tag: 1)]
      property status : StatusIB

      def initialize(@path : AttributePath, @status : StatusIB)
      end
    end

    # AttributeReportIB - wrapper for either data or status
    struct AttributeReportIB
      include TLV::Serializable

      # Tag 0: AttributeStatusIB (optional - present on error)
      @[TLV::Field(tag: 0, optional: true)]
      property attribute_status : AttributeStatusIB?

      # Tag 1: AttributeDataIB (optional - present on success)
      @[TLV::Field(tag: 1, optional: true)]
      property attribute_data : AttributeDataIB?

      def initialize(@attribute_status : AttributeStatusIB? = nil, @attribute_data : AttributeDataIB? = nil)
      end
    end

    # EventDataIB - one journaled event, per Matter Core 10.6.9 and
    # matter.js `TlvEventData`.
    struct EventDataIB
      include TLV::Serializable

      # Tag 0: Path
      @[TLV::Field(tag: 0)]
      property path : EventPath

      # Tag 1: EventNumber
      @[TLV::Field(tag: 1)]
      property event_number : UInt64

      # Tag 2: Priority
      @[TLV::Field(tag: 2)]
      property priority : EventPriority

      # Tag 3: EpochTimestamp (milliseconds since the POSIX epoch)
      @[TLV::Field(tag: 3, optional: true)]
      property epoch_timestamp : UInt64?

      # Tag 4: SystemTimestamp
      @[TLV::Field(tag: 4, optional: true)]
      property system_timestamp : UInt64?

      # Tag 5: DeltaEpochTimestamp
      @[TLV::Field(tag: 5, optional: true)]
      property delta_epoch_timestamp : UInt64?

      # Tag 6: DeltaSystemTimestamp
      @[TLV::Field(tag: 6, optional: true)]
      property delta_system_timestamp : UInt64?

      # Tag 7: Data (the event payload)
      @[TLV::Field(tag: 7, optional: true)]
      property data : TLV::Any?

      def initialize(
        @path : EventPath,
        @event_number : UInt64,
        @priority : EventPriority,
        @data : TLV::Any? = nil,
        @epoch_timestamp : UInt64? = nil,
        @system_timestamp : UInt64? = nil,
        @delta_epoch_timestamp : UInt64? = nil,
        @delta_system_timestamp : UInt64? = nil,
      )
      end
    end

    # EventStatusIB - an event path that could not be read (Matter Core 10.6.15)
    struct EventStatusIB
      include TLV::Serializable

      # Tag 0: Path
      @[TLV::Field(tag: 0)]
      property path : EventPath

      # Tag 1: Status
      @[TLV::Field(tag: 1)]
      property status : StatusIB

      def initialize(@path : EventPath, @status : StatusIB)
      end
    end

    # EventReportIB - wrapper for either data or status (Matter Core 10.6.10)
    struct EventReportIB
      include TLV::Serializable

      # Tag 0: EventStatusIB (optional - present on error)
      @[TLV::Field(tag: 0, optional: true)]
      property event_status : EventStatusIB?

      # Tag 1: EventDataIB (optional - present on success)
      @[TLV::Field(tag: 1, optional: true)]
      property event_data : EventDataIB?

      def initialize(@event_status : EventStatusIB? = nil, @event_data : EventDataIB? = nil)
      end
    end

    # EventFilterIB - the lowest event number a reader still wants
    # (Matter Core 10.6.6)
    struct EventFilterIB
      include TLV::Serializable

      # Tag 0: NodeId (optional)
      @[TLV::Field(tag: 0, optional: true)]
      property node : UInt64?

      # Tag 1: EventMin
      @[TLV::Field(tag: 1)]
      property event_min : UInt64

      def initialize(@event_min : UInt64, @node : UInt64? = nil)
      end
    end

    # ReportDataMessage - the actual ReadResponse/ReportData message
    # Per matter.js TlvDataReportForSend
    # Note: fixed_size: true on subscription_id ensures 4-byte encoding for iOS compatibility
    struct ReportDataMessage
      include TLV::Serializable

      # Tag 0: SubscriptionId (optional, fixed 4-byte for iOS compatibility)
      @[TLV::Field(tag: 0, optional: true, fixed_size: true)]
      property subscription_id : UInt32?

      # Tag 1: AttributeReports (array of AttributeReportIB)
      @[TLV::Field(tag: 1, optional: true)]
      property attribute_reports : Array(AttributeReportIB)?

      # Tag 2: EventReports (array of EventReportIB)
      @[TLV::Field(tag: 2, optional: true)]
      property event_reports : Array(EventReportIB)?

      # Tag 3: MoreChunkedMessages (optional)
      @[TLV::Field(tag: 3, optional: true)]
      property more_chunked_messages : Bool?

      # Tag 4: SuppressResponse (optional)
      @[TLV::Field(tag: 4, optional: true)]
      property suppress_response : Bool?

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision (REQUIRED!)
      @[TLV::Field(tag: 0xFF)]
      property interaction_model_revision : UInt8

      def initialize(
        @subscription_id = nil,
        @attribute_reports = nil,
        @event_reports = nil,
        @more_chunked_messages = nil,
        @suppress_response = nil,
        @interaction_model_revision = INTERACTION_MODEL_REVISION,
      )
      end
    end

    # DataVersionFilterIB suppresses reports for a cluster whose version the
    # client already holds.
    struct DataVersionFilterIB
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property path : ClusterPath

      @[TLV::Field(tag: 1, fixed_size: true)]
      property data_version : UInt32

      def initialize(@path : ClusterPath, @data_version : UInt32)
      end
    end

    # ReadRequest message
    struct ReadRequestMessage
      include TLV::Serializable

      # Tag 0: AttributeRequests (array of AttributePath)
      @[TLV::Field(tag: 0, optional: true)]
      property attribute_requests : Array(AttributePath)?

      # Tag 1: EventRequests (optional)
      @[TLV::Field(tag: 1, optional: true)]
      property event_requests : Array(EventPath)?

      # Tag 2: EventFilters (array of EventFilterIB)
      @[TLV::Field(tag: 2, optional: true)]
      property event_filters : Array(EventFilterIB)?

      # Tag 3: FabricFiltered
      @[TLV::Field(tag: 3, optional: true)]
      property fabric_filtered : Bool?

      # Tag 4: DataVersionFilters (optional)
      @[TLV::Field(tag: 4, optional: true)]
      property data_version_filters : Array(DataVersionFilterIB)?

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF, optional: true)]
      property interaction_model_revision : UInt8?

      def initialize(
        @attribute_requests = nil,
        @fabric_filtered = true,
        @event_requests = nil,
        @event_filters = nil,
        @data_version_filters = nil,
        @interaction_model_revision = nil,
      )
      end
    end

    # WriteRequestMessage
    struct WriteRequestMessage
      include TLV::Serializable

      # Tag 0: SuppressResponse
      @[TLV::Field(tag: 0, optional: true)]
      property suppress_response : Bool?

      # Tag 1: TimedRequest
      @[TLV::Field(tag: 1, optional: true)]
      property timed_request : Bool?

      # Tag 2: WriteRequests (array of AttributeDataIB)
      @[TLV::Field(tag: 2, optional: true)]
      property write_requests : Array(AttributeDataIB)?

      # Tag 3: MoreChunkedMessages
      @[TLV::Field(tag: 3, optional: true)]
      property more_chunked_messages : Bool?

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF, optional: true)]
      property interaction_model_revision : UInt8?

      def initialize(
        @suppress_response = false,
        @timed_request = false,
        @write_requests = nil,
        @more_chunked_messages = false,
        @interaction_model_revision = nil,
      )
      end
    end

    # WriteResponseMessage
    struct WriteResponseMessage
      include TLV::Serializable

      # Tag 0: WriteResponses (array of AttributeStatusIB)
      @[TLV::Field(tag: 0)]
      property write_responses : Array(AttributeStatusIB)

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF)]
      property interaction_model_revision : UInt8

      def initialize(
        @write_responses = [] of AttributeStatusIB,
        @interaction_model_revision = INTERACTION_MODEL_REVISION,
      )
      end
    end

    # SubscribeRequestMessage
    #
    # Field order follows the spec's tag numbering except that tag 8
    # (DataVersionFilters) is declared before tag 7 (IsFabricFiltered) to match
    # the order chip-tool and matter.js emit on the wire; tag 6 is unused.
    struct SubscribeRequestMessage
      include TLV::Serializable

      # Tag 0: KeepSubscriptions
      @[TLV::Field(tag: 0)]
      property? keep_subscriptions : Bool

      # Tag 1: MinIntervalFloor
      @[TLV::Field(tag: 1)]
      property min_interval_floor : UInt16

      # Tag 2: MaxIntervalCeiling
      @[TLV::Field(tag: 2)]
      property max_interval_ceiling : UInt16

      # Tag 3: AttributeRequests (optional)
      @[TLV::Field(tag: 3, optional: true)]
      property attribute_requests : Array(AttributePath)?

      # Tag 4: EventRequests (optional)
      @[TLV::Field(tag: 4, optional: true)]
      property event_requests : Array(EventPath)?

      # Tag 5: EventFilters (array of EventFilterIB)
      @[TLV::Field(tag: 5, optional: true)]
      property event_filters : Array(EventFilterIB)?

      # Tag 8: DataVersionFilters (optional)
      @[TLV::Field(tag: 8, optional: true)]
      property data_version_filters : Array(DataVersionFilterIB)?

      # Tag 7: IsFabricFiltered
      @[TLV::Field(tag: 7)]
      property? is_fabric_filtered : Bool

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF, optional: true)]
      property interaction_model_revision : UInt8?

      def initialize(
        @keep_subscriptions = false,
        @min_interval_floor = 0_u16,
        @max_interval_ceiling = DEFAULT_MAX_INTERVAL_CEILING_SECONDS,
        @is_fabric_filtered = true,
        @attribute_requests = nil,
        @event_requests = nil,
        @event_filters = nil,
        @data_version_filters = nil,
        @interaction_model_revision = nil,
      )
      end
    end

    # SubscribeResponseMessage
    # Note: fixed_size: true ensures correct type widths for iOS compatibility
    struct SubscribeResponseMessage
      include TLV::Serializable

      # Tag 0: SubscriptionId (fixed 4-byte for iOS compatibility)
      @[TLV::Field(tag: 0, fixed_size: true)]
      property subscription_id : UInt32

      # Tag 2: MaxInterval (Note: tag 1 is not used, fixed 2-byte for iOS compatibility)
      @[TLV::Field(tag: 2, fixed_size: true)]
      property max_interval : UInt16

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF)]
      property interaction_model_revision : UInt8

      def initialize(
        @subscription_id : UInt32,
        @max_interval : UInt16,
        @interaction_model_revision = INTERACTION_MODEL_REVISION,
      )
      end
    end

    # CommandDataIB - command invocation data
    struct CommandDataIBTlv
      include TLV::Serializable

      # Tag 0: CommandPath (LIST)
      @[TLV::Field(tag: 0)]
      property command_path : CommandPath

      # Tag 1: CommandFields (optional)
      @[TLV::Field(tag: 1, optional: true)]
      property command_fields : TLV::Any?

      def initialize(@command_path : CommandPath, @command_fields : TLV::Any? = nil)
      end
    end

    # CommandStatusIB - command status on error
    struct CommandStatusIB
      include TLV::Serializable

      # Tag 0: CommandPath (LIST)
      @[TLV::Field(tag: 0)]
      property command_path : CommandPath

      # Tag 1: Status
      @[TLV::Field(tag: 1)]
      property status : StatusIB

      def initialize(@command_path : CommandPath, @status : StatusIB)
      end
    end

    # InvokeResponseIB - wrapper for command response or status
    struct InvokeResponseIB
      include TLV::Serializable

      # Tag 0: CommandData (optional - present on success)
      @[TLV::Field(tag: 0, optional: true)]
      property command_data : CommandDataIBTlv?

      # Tag 1: CommandStatus (optional - present on error)
      @[TLV::Field(tag: 1, optional: true)]
      property command_status : CommandStatusIB?

      def initialize(@command_data : CommandDataIBTlv? = nil, @command_status : CommandStatusIB? = nil)
      end
    end

    # InvokeRequestMessage
    struct InvokeRequestMessage
      include TLV::Serializable

      # Tag 0: SuppressResponse
      @[TLV::Field(tag: 0, optional: true)]
      property suppress_response : Bool?

      # Tag 1: TimedRequest
      @[TLV::Field(tag: 1, optional: true)]
      property timed_request : Bool?

      # Tag 2: InvokeRequests (array of CommandDataIBTlv)
      @[TLV::Field(tag: 2)]
      property invoke_requests : Array(CommandDataIBTlv)

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF, optional: true)]
      property interaction_model_revision : UInt8?

      def initialize(
        @invoke_requests = [] of CommandDataIBTlv,
        @suppress_response = false,
        @timed_request = false,
        @interaction_model_revision = nil,
      )
      end
    end

    # InvokeResponseMessage
    struct InvokeResponseMessage
      include TLV::Serializable

      # Tag 0: SuppressResponse
      @[TLV::Field(tag: 0)]
      property? suppress_response : Bool

      # Tag 1: InvokeResponses (array of InvokeResponseIB)
      @[TLV::Field(tag: 1)]
      property invoke_responses : Array(InvokeResponseIB)

      # Tag 2: MoreChunkedMessages (optional)
      @[TLV::Field(tag: 2, optional: true)]
      property more_chunked_messages : Bool?

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF)]
      property interaction_model_revision : UInt8

      def initialize(
        @suppress_response = false,
        @invoke_responses = [] of InvokeResponseIB,
        @more_chunked_messages = nil,
        @interaction_model_revision = INTERACTION_MODEL_REVISION,
      )
      end
    end

    # Timed interaction deadline, in milliseconds (Matter Core Interaction Model).
    struct TimedRequestMessage
      include TLV::Serializable

      @[TLV::Field(tag: 0)]
      property timeout : UInt16

      @[TLV::Field(tag: 0xFF)]
      property interaction_model_revision : UInt8 = INTERACTION_MODEL_REVISION

      def initialize(@timeout : UInt16, @interaction_model_revision : UInt8 = INTERACTION_MODEL_REVISION)
      end
    end

    # StatusResponseMessage
    struct StatusResponseMessage
      include TLV::Serializable

      # Tag 0: Status code
      @[TLV::Field(tag: 0)]
      property status : UInt8

      # Tag 0xFF (INTERACTION_MODEL_REVISION_TAG): InteractionModelRevision
      @[TLV::Field(tag: 0xFF, optional: true)]
      property interaction_model_revision : UInt8?

      def initialize(@status : UInt8, @interaction_model_revision : UInt8? = nil)
      end
    end
  end
end
