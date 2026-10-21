module Matter
  module InteractionModel
    # Shared vocabulary for the human readable `to_s` form of every path type:
    # `E:1/C:0x6/A:0x0`, `E:1/C:0x6/Cmd:0x1`, `N:*/E:1/C:0x28/Evt:0x0`.
    module PathFormat
      NODE      = "N:"
      ENDPOINT  = "E:"
      CLUSTER   = "C:"
      ATTRIBUTE = "A:"
      EVENT     = "Evt:"
      COMMAND   = "Cmd:"
      SEPARATOR = "/"
      WILDCARD  = "*"
      URGENT    = "(urgent)"

      # `E:1` or `E:*` when the endpoint is a wildcard
      def self.endpoint(io : IO, endpoint : UInt16?) : Nil
        io << ENDPOINT
        io << (endpoint || WILDCARD)
      end

      # `N:1` or `N:*` when the node is a wildcard
      def self.node(io : IO, node : UInt64?) : Nil
        io << NODE
        io << (node || WILDCARD)
      end

      # `/C:0x6`, or nothing when the cluster is a wildcard
      def self.cluster(io : IO, cluster : UInt32?) : Nil
        identifier(io, CLUSTER, cluster)
      end

      # `/A:0x0`, or nothing when the attribute is a wildcard
      def self.attribute(io : IO, attribute : UInt32?) : Nil
        identifier(io, ATTRIBUTE, attribute)
      end

      # `/Evt:0x0`, or nothing when the event is a wildcard
      def self.event(io : IO, event : UInt32?) : Nil
        identifier(io, EVENT, event)
      end

      # `/Cmd:0x1`
      def self.command(io : IO, command : UInt32) : Nil
        identifier(io, COMMAND, command)
      end

      private def self.identifier(io : IO, prefix : String, id : UInt32?) : Nil
        return unless id
        io << SEPARATOR << prefix << Hex::PREFIX
        id.to_s(io, 16)
      end
    end

    # The endpoint/cluster pair carried by a DataVersionFilterIB.
    @[TLV::ListFormat]
    struct ClusterPath
      include TLV::Serializable

      @[TLV::Field(tag: 0, optional: true, fixed_size: true)]
      property node : UInt64?

      @[TLV::Field(tag: 1, fixed_size: true)]
      property endpoint : UInt16

      @[TLV::Field(tag: 2, fixed_size: true)]
      property cluster : UInt32

      def initialize(@endpoint : UInt16, @cluster : UInt32, @node : UInt64? = nil)
      end
    end

    # Attribute path identifying a specific attribute
    # Encoded as a TLV list per Matter spec (and matter.js/CHIP encodings),
    # and TLV::Serializable decoding is tolerant of list/structure variations.
    # Note: fixed_size: true ensures proper type widths for iOS compatibility.
    #
    # Matter spec allows Boolean `true` as a wildcard indicator for path fields.
    # iOS/Apple controllers send `true` instead of omitting fields for wildcards.
    # We handle this by accepting Bool in the union type and converting to nil.
    @[TLV::ListFormat]
    struct AttributePath
      include TLV::Serializable

      @[TLV::Field(tag: 0, optional: true)]
      property enable_tag_compression : Bool?

      @[TLV::Field(tag: 1, optional: true, fixed_size: true)]
      property node_raw : UInt64?

      # Internal storage accepts Bool for wildcard indicator from iOS
      @[TLV::Field(tag: 2, fixed_size: true)]
      property endpoint_raw : UInt16 | Bool?

      @[TLV::Field(tag: 3, fixed_size: true)]
      property cluster_raw : UInt32 | Bool?

      @[TLV::Field(tag: 4, fixed_size: true)]
      property attribute_raw : UInt32 | Bool?

      @[TLV::Field(tag: 5, fixed_size: true)]
      property list_index_raw : UInt16 | Bool?

      # TLV null means append; an omitted tag means a whole-list path.
      # TLV::Serializable decodes both into nil, so keep the wire distinction.
      getter? list_index_null : Bool = false

      @[TLV::Field(tag: 6, optional: true, fixed_size: true)]
      property wildcard_path_flags_raw : UInt32?

      def initialize(
        endpoint : UInt16? = nil,
        cluster : UInt32? = nil,
        attribute : UInt32? = nil,
        list_index : UInt16? = nil,
        *,
        list_index_null : Bool = false,
        enable_tag_compression : Bool? = nil,
        node : UInt64? = nil,
        wildcard_path_flags : UInt32? = nil,
      )
        @enable_tag_compression = enable_tag_compression
        @node_raw = node
        @endpoint_raw = endpoint
        @cluster_raw = cluster
        @attribute_raw = attribute
        @list_index_raw = list_index
        @list_index_null = list_index_null
        @wildcard_path_flags_raw = wildcard_path_flags
      end

      def node : UInt64?
        @node_raw
      end

      def wildcard_path_flags : UInt32?
        @wildcard_path_flags_raw
      end

      # Getters that convert Bool (wildcard) to nil
      def endpoint : UInt16?
        value = @endpoint_raw
        value.is_a?(UInt16) ? value : nil
      end

      def cluster : UInt32?
        value = @cluster_raw
        value.is_a?(UInt32) ? value : nil
      end

      def attribute : UInt32?
        value = @attribute_raw
        value.is_a?(UInt32) ? value : nil
      end

      def list_index : UInt16?
        value = @list_index_raw
        value.is_a?(UInt16) ? value : nil
      end

      # Setters for API compatibility
      def endpoint=(value : UInt16?)
        @endpoint_raw = value
      end

      def node=(value : UInt64?)
        @node_raw = value
      end

      def cluster=(value : UInt32?)
        @cluster_raw = value
      end

      def attribute=(value : UInt32?)
        @attribute_raw = value
      end

      def list_index=(value : UInt16?)
        @list_index_raw = value
        @list_index_null = false
      end

      def self.from_tlv(any : TLV::Any) : self
        path = previous_def
        element = case value = any.value
                  when TLV::List
                    value.find { |item| item.header.ids == 5_u8 }
                  when TLV::Structure
                    value[5_u8]?
                  end
        path.set_list_index_null(element.try(&.header.element_type.null?) == true)
        path
      end

      protected def set_list_index_null(value : Bool) : Nil
        @list_index_null = value
      end

      def wildcard_path_flags=(value : UInt32?)
        @wildcard_path_flags_raw = value
      end

      # Wildcard path matches all endpoints/clusters/attributes
      def wildcard?
        endpoint.nil? || cluster.nil? || attribute.nil?
      end

      # Concrete path specifies a single attribute
      def concrete?
        !wildcard?
      end

      def to_s(io : IO) : Nil
        PathFormat.endpoint(io, endpoint)
        PathFormat.cluster(io, cluster)
        PathFormat.attribute(io, attribute)
        if index = list_index
          io << PathFormat::SEPARATOR << "[" << index << "]"
        elsif @list_index_null
          io << PathFormat::SEPARATOR << "[+]"
        end
      end

      def ==(other : AttributePath) : Bool
        endpoint == other.endpoint &&
          cluster == other.cluster &&
          attribute == other.attribute &&
          list_index == other.list_index &&
          list_index_null? == other.list_index_null?
      end
    end

    # Command path identifying a specific command
    # Supports both list-form [endpoint, cluster, command] and structure-form {0=>endpoint, 1=>cluster, 2=>command}
    # Note: fixed_size: true ensures proper type widths for iOS compatibility
    @[TLV::ListFormat]
    struct CommandPath
      include TLV::Serializable

      @[TLV::Field(tag: 0, fixed_size: true, optional: true)]
      property endpoint : UInt16?

      @[TLV::Field(tag: 1, fixed_size: true)]
      property cluster : UInt32

      @[TLV::Field(tag: 2, fixed_size: true)]
      property command : UInt32

      def initialize(@endpoint : UInt16?, @cluster : UInt32, @command : UInt32)
      end

      def to_s(io : IO) : Nil
        PathFormat.endpoint(io, endpoint) if endpoint
        PathFormat.cluster(io, cluster)
        PathFormat.command(io, command)
      end

      def ==(other : CommandPath) : Bool
        @endpoint == other.endpoint &&
          @cluster == other.cluster &&
          @command == other.command
      end
    end

    # Event path identifying a specific event
    # Supports both list-form and structure-form
    # Note: fixed_size: true ensures proper type widths for iOS compatibility
    #
    # Matter spec allows Boolean `true` as a wildcard indicator for path fields.
    # Some controllers may send `true` instead of omitting fields for wildcards.
    @[TLV::ListFormat]
    struct EventPath
      include TLV::Serializable

      @[TLV::Field(tag: 0, fixed_size: true)]
      property node_raw : UInt64 | Bool?

      # Internal storage accepts Bool for wildcard indicator from iOS
      @[TLV::Field(tag: 1, fixed_size: true)]
      property endpoint_raw : UInt16 | Bool?

      @[TLV::Field(tag: 2, fixed_size: true)]
      property cluster_raw : UInt32 | Bool?

      @[TLV::Field(tag: 3, fixed_size: true)]
      property event_raw : UInt32 | Bool?

      # Omitted rather than written as `false`, matching matter.js and the
      # spec's optional EventPathIB field: a report path carries no urgency.
      @[TLV::Field(tag: 4, optional: true)]
      property is_urgent_raw : Bool?

      def initialize(
        node : UInt64? = nil,
        endpoint : UInt16? = nil,
        cluster : UInt32? = nil,
        event : UInt32? = nil,
        is_urgent : Bool = false,
      )
        @node_raw = node
        @endpoint_raw = endpoint
        @cluster_raw = cluster
        @event_raw = event
        @is_urgent_raw = is_urgent ? true : nil
      end

      # Whether the subscriber asked for events on this path to be reported
      # without waiting out the subscription's minimum interval.
      #
      # ameba:disable Naming/PredicateName -- IsUrgent is the spec's field name.
      def is_urgent? : Bool
        @is_urgent_raw == true
      end

      def is_urgent=(value : Bool) : Bool
        @is_urgent_raw = value ? true : nil
        value
      end

      # Getters that convert Bool (wildcard) to nil
      def node : UInt64?
        value = @node_raw
        value.is_a?(UInt64) ? value : nil
      end

      def endpoint : UInt16?
        value = @endpoint_raw
        value.is_a?(UInt16) ? value : nil
      end

      def cluster : UInt32?
        value = @cluster_raw
        value.is_a?(UInt32) ? value : nil
      end

      def event : UInt32?
        value = @event_raw
        value.is_a?(UInt32) ? value : nil
      end

      # Setters for API compatibility
      def node=(value : UInt64?)
        @node_raw = value
      end

      def endpoint=(value : UInt16?)
        @endpoint_raw = value
      end

      def cluster=(value : UInt32?)
        @cluster_raw = value
      end

      def event=(value : UInt32?)
        @event_raw = value
      end

      # Wildcard path matches all endpoints/clusters/events
      def wildcard?
        endpoint.nil? || cluster.nil? || event.nil?
      end

      def to_s(io : IO) : Nil
        PathFormat.node(io, node)
        io << PathFormat::SEPARATOR
        PathFormat.endpoint(io, endpoint)
        PathFormat.cluster(io, cluster)
        PathFormat.event(io, event)
        io << PathFormat::SEPARATOR << PathFormat::URGENT if is_urgent?
      end

      def ==(other : EventPath) : Bool
        node == other.node &&
          endpoint == other.endpoint &&
          cluster == other.cluster &&
          event == other.event &&
          is_urgent? == other.is_urgent?
      end
    end

    # Data version for optimistic concurrency control
    alias DataVersion = UInt32

    # Concrete attribute path with data version
    struct ConcreteAttributePath
      property endpoint : UInt16
      property cluster : UInt32
      property attribute : UInt32
      property list_index : UInt16?

      def initialize(
        @endpoint : UInt16,
        @cluster : UInt32,
        @attribute : UInt32,
        @list_index : UInt16? = nil,
      )
      end

      def to_path : AttributePath
        AttributePath.new(@endpoint, @cluster, @attribute, @list_index)
      end

      def to_s(io : IO) : Nil
        to_path.to_s(io)
      end

      def ==(other : ConcreteAttributePath) : Bool
        @endpoint == other.endpoint &&
          @cluster == other.cluster &&
          @attribute == other.attribute &&
          @list_index == other.list_index
      end
    end
  end
end

struct Matter::InteractionModel::AttributePath
  def to_tlv : TLV::Any
    encode_path(nil)
  end

  def to_tlv(outer_tag : Nil) : TLV::Any
    encode_path(outer_tag)
  end

  def to_tlv(outer_tag : UInt8) : TLV::Any
    encode_path(outer_tag)
  end

  def to_tlv(outer_tag : {UInt16, UInt16}) : TLV::Any
    encode_path(outer_tag)
  end

  def to_tlv(outer_tag : {UInt16, UInt16, UInt16}) : TLV::Any
    encode_path(outer_tag)
  end

  private def encode_path(outer_tag : UInt8? | {UInt16, UInt16} | {UInt16, UInt16, UInt16}) : TLV::Any
    list = TLV::List.new
    list << TLV::Serializable.serialize_value(@enable_tag_compression, 0_u8) unless @enable_tag_compression.nil?
    list << TLV::Serializable.serialize_value(@node_raw, 1_u8, true) unless @node_raw.nil?
    list << TLV::Serializable.serialize_value(@endpoint_raw, 2_u8, true) unless @endpoint_raw.nil?
    list << TLV::Serializable.serialize_value(@cluster_raw, 3_u8, true) unless @cluster_raw.nil?
    list << TLV::Serializable.serialize_value(@attribute_raw, 4_u8, true) unless @attribute_raw.nil?
    if @list_index_null
      list << TLV::Serializable.serialize_value(nil, 5_u8)
    elsif !@list_index_raw.nil?
      list << TLV::Serializable.serialize_value(@list_index_raw, 5_u8, true)
    end
    list << TLV::Serializable.serialize_value(@wildcard_path_flags_raw, 6_u8, true) unless @wildcard_path_flags_raw.nil?
    TLV::Any.new(list, outer_tag)
  end
end
