require "tlv"

require "./interaction_model/paths"
require "./interaction_model/tlv_messages"

module Matter
  # The node's event store.
  #
  # Matter numbers events per node, not per endpoint, so one monotonic counter
  # serves every cluster on the node. Records are kept in a bounded ring buffer
  # per priority - a flood of Debug events can never push a Critical one out -
  # and are handed back in event-number order regardless of which buffer they
  # came from.
  #
  # Events are emitted from cluster callbacks on arbitrary fibers, so every
  # entry point takes the journal's own lock. It never calls back into a
  # cluster or the protocol layer while holding it.
  class EventJournal
    Log = ::Log.for("matter.event_journal")

    # Ring buffer capacity per priority. Critical events are the ones a
    # controller must not miss, Debug the ones it can afford to.
    DEBUG_CAPACITY    =  32
    INFO_CAPACITY     =  64
    CRITICAL_CAPACITY = 128

    # The first event number handed out. Matter reserves 0 as "no event".
    FIRST_EVENT_NUMBER = 1_u64

    # One journaled event.
    struct Record
      getter event_number : UInt64
      getter endpoint : UInt16
      getter cluster : UInt32
      getter event : UInt32
      getter priority : InteractionModel::EventPriority
      getter epoch_timestamp_ms : UInt64

      # The fabric the event belongs to, or `nil` when it is node scoped and
      # therefore visible to every fabric.
      getter fabric_index : UInt8?
      getter data : TLV::Any

      def initialize(
        @event_number : UInt64,
        @endpoint : UInt16,
        @cluster : UInt32,
        @event : UInt32,
        @priority : InteractionModel::EventPriority,
        @epoch_timestamp_ms : UInt64,
        @fabric_index : UInt8?,
        @data : TLV::Any,
      )
      end

      # Whether *path* selects this record, honouring its wildcards.
      def matches?(path : InteractionModel::EventPath) : Bool
        (path.endpoint.nil? || path.endpoint == @endpoint) &&
          (path.cluster.nil? || path.cluster == @cluster) &&
          (path.event.nil? || path.event == @event)
      end

      # Whether any of *paths* selects this record.
      def matches_any?(paths : Array(InteractionModel::EventPath)) : Bool
        paths.any? { |path| matches?(path) }
      end

      # Whether a reader on *fabric_index* may see this record. A node-scoped
      # record is visible to everyone.
      def visible_to?(fabric_index : UInt8?) : Bool
        own = @fabric_index
        own.nil? || own == fabric_index
      end

      # Whether a path selecting this record asked for urgent delivery.
      def urgent_for?(paths : Array(InteractionModel::EventPath)) : Bool
        paths.any? { |path| path.is_urgent? && matches?(path) }
      end

      # The concrete path of this record, as a report carries it.
      def to_path : InteractionModel::EventPath
        InteractionModel::EventPath.new(endpoint: @endpoint, cluster: @cluster, event: @event)
      end
    end

    @mutex = Mutex.new
    @next_event_number : UInt64 = FIRST_EVENT_NUMBER
    @buffers : Hash(InteractionModel::EventPriority, Deque(Record))

    def initialize
      @buffers = {
        InteractionModel::EventPriority::Debug    => Deque(Record).new(DEBUG_CAPACITY),
        InteractionModel::EventPriority::Info     => Deque(Record).new(INFO_CAPACITY),
        InteractionModel::EventPriority::Critical => Deque(Record).new(CRITICAL_CAPACITY),
      }
    end

    # The buffer capacity for *priority*.
    def self.capacity(priority : InteractionModel::EventPriority) : Int32
      case priority
      in .debug?    then DEBUG_CAPACITY
      in .info?     then INFO_CAPACITY
      in .critical? then CRITICAL_CAPACITY
      end
    end

    # Journals one event and returns the event number it was given.
    def record(
      endpoint : UInt16,
      cluster : UInt32,
      event : UInt32,
      priority : InteractionModel::EventPriority,
      data : TLV::Any,
      fabric_index : UInt8? = nil,
      epoch_timestamp_ms : UInt64? = nil,
    ) : Record
      @mutex.synchronize do
        entry = Record.new(
          event_number: @next_event_number,
          endpoint: endpoint,
          cluster: cluster,
          event: event,
          priority: priority,
          epoch_timestamp_ms: epoch_timestamp_ms || Time.utc.to_unix_ms.to_u64,
          fabric_index: fabric_index,
          data: data
        )
        @next_event_number &+= 1

        buffer = @buffers[priority]
        buffer.shift if buffer.size >= EventJournal.capacity(priority)
        buffer.push(entry)

        Log.debug do
          "Recorded event #{entry.event_number}: endpoint=#{endpoint} cluster=0x#{cluster.to_s(16)} " \
          "event=0x#{event.to_s(16)} priority=#{priority} fabric_index=#{fabric_index.inspect}"
        end

        entry
      end
    end

    # Every retained record matching *paths* and visible to *fabric_index*,
    # in event-number order.
    #
    # * *after* keeps only records numbered above it (what a subscription that
    #   has already reported up to *after* still owes).
    # * *min_event_number* keeps only records numbered at or above it (what an
    #   `EventFilterIB` asks for).
    # * *paths* selects; `nil` or an empty array selects nothing.
    def query(
      paths : Array(InteractionModel::EventPath)?,
      after : UInt64? = nil,
      min_event_number : UInt64? = nil,
      fabric_index : UInt8? = nil,
    ) : Array(Record)
      selected = [] of Record
      return selected if paths.nil? || paths.empty?

      @mutex.synchronize do
        @buffers.each_value do |buffer|
          buffer.each do |entry|
            next if after && entry.event_number <= after
            next if min_event_number && entry.event_number < min_event_number
            next unless entry.visible_to?(fabric_index)
            next unless entry.matches_any?(paths)
            selected << entry
          end
        end
      end

      selected.sort_by!(&.event_number)
    end

    # Yields the records `query` would return, in event-number order.
    def each(
      paths : Array(InteractionModel::EventPath)?,
      after : UInt64? = nil,
      min_event_number : UInt64? = nil,
      fabric_index : UInt8? = nil,
      & : Record ->
    ) : Nil
      query(paths, after, min_event_number, fabric_index).each { |entry| yield entry }
    end

    # The number of the most recently journaled event, or 0 when the node has
    # not emitted one yet.
    def latest_event_number : UInt64
      @mutex.synchronize { @next_event_number - 1 }
    end

    # The number the next journaled event will be given.
    def next_event_number : UInt64
      @mutex.synchronize { @next_event_number }
    end

    # The number of records retained across every priority.
    def size : Int32
      @mutex.synchronize { @buffers.each_value.sum(&.size) }
    end

    # A removed fabric's numeric index may be assigned to a different fabric.
    # Erase its retained events before that happens, without resetting the
    # node-wide event number or removing events visible to other fabrics.
    def remove_fabric(fabric_index : UInt8) : Nil
      @mutex.synchronize do
        @buffers.each_value(&.reject! { |record| record.fabric_index == fabric_index })
      end
    end

    # Drops every retained record. The event number keeps counting up, so a
    # controller can never be handed a number it has already seen.
    def clear : Nil
      @mutex.synchronize { @buffers.each_value(&.clear) }
    end
  end
end
