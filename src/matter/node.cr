require "./endpoint"
require "./error"
require "./event_journal"

module Matter
  # The data model of one Matter node: its endpoints, and a flat
  # `{endpoint, cluster} => cluster` index over every cluster they hold.
  #
  # The endpoints own the clusters; the index exists so the Interaction Model
  # can resolve a path in one lookup. It is maintained on every add and remove,
  # so the two never drift.
  #
  # Attribute-change and data-version callbacks are node-wide properties rather
  # than per-cluster wiring: they are applied to every cluster already present
  # and to every cluster inserted afterwards, so an endpoint added at runtime
  # can never come up unwired.
  class Node
    # The root endpoint, which every node has and no node may remove.
    ROOT_ENDPOINT_ID = DataType::EndpointNumber::ROOT.number

    # Endpoint numbers handed out to dynamically added endpoints start here.
    FIRST_DYNAMIC_ENDPOINT_ID = 1_u16

    getter endpoints : Hash(UInt16, Endpoint)

    # The flat index the Interaction Model reads.
    getter clusters : Hash(Tuple(UInt16, UInt32), Cluster::Base)

    getter on_attribute_changed : Proc(UInt16, UInt32, UInt32, Nil)?
    getter on_version_changed : Proc(Cluster::Base, Nil)?

    # Called with the journaled record whenever any cluster on the node emits
    # an event. The record is already in `event_journal` by then, so a reader
    # that missed the callback still finds the event.
    getter on_event_emitted : Proc(EventJournal::Record, Nil)?

    # The node's event store. Event numbers are node wide, so every cluster
    # shares this one journal.
    getter event_journal : EventJournal

    def initialize(@event_journal : EventJournal = EventJournal.new)
      @endpoints = {} of UInt16 => Endpoint
      @clusters = {} of Tuple(UInt16, UInt32) => Cluster::Base
    end

    # Get an endpoint by ID
    def endpoint(endpoint_id : UInt16) : Endpoint?
      @endpoints[endpoint_id]?
    end

    # Get an endpoint by ID (raises if not found)
    def endpoint!(endpoint_id : UInt16) : Endpoint
      @endpoints[endpoint_id]? || raise KeyError.new("Endpoint #{endpoint_id} not found")
    end

    # Check if node has an endpoint
    def has_endpoint?(endpoint_id : UInt16) : Bool
      @endpoints.has_key?(endpoint_id)
    end

    # Adds *endpoint*, replacing any endpoint already at its number.
    #
    # The endpoint's Descriptor is populated and its device types are checked
    # first: an endpoint missing a mandatory server cluster is a configuration
    # bug and raises `ConfigurationError` rather than commissioning a device a
    # controller cannot use.
    def add_endpoint(endpoint : Endpoint) : Endpoint
      endpoint.populate_descriptor

      errors = endpoint.validate
      unless errors.empty?
        raise ConfigurationError.new("Endpoint #{endpoint.number} is incomplete: #{errors.join("; ")}")
      end

      remove_endpoint(endpoint.number)
      endpoint.wire_scene_extensions

      @endpoints[endpoint.number] = endpoint
      endpoint.clusters.each do |cluster_id, cluster|
        cluster.as?(Cluster::Identify).try(&.reopen)
        @clusters[{endpoint.number, cluster_id}] = cluster
        apply_callbacks(cluster)
      end

      endpoint
    end

    # Removes the endpoint at *endpoint_id* and unwires its clusters.
    # Returns the endpoint, or `nil` when there was none.
    def remove_endpoint(endpoint_id : UInt16) : Endpoint?
      endpoint = @endpoints.delete(endpoint_id)
      return unless endpoint

      endpoint.clusters.each do |cluster_id, cluster|
        @clusters.delete({endpoint_id, cluster_id})
        cluster.as?(Cluster::Identify).try(&.close)
        cluster.on_attribute_changed = nil
        cluster.on_version_changed = nil
        cluster.on_event_emitted = nil
      end

      endpoint
    end

    # Every cluster on the node, in endpoint insertion order.
    def each_cluster(& : Cluster::Base ->) : Nil
      @clusters.each_value { |cluster| yield cluster }
    end

    # Every endpoint number, ascending.
    def endpoint_ids : Array(UInt16)
      @endpoints.keys.sort!
    end

    # Get the number of endpoints
    def endpoint_count : Int32
      @endpoints.size
    end

    # The lowest unused endpoint number a dynamic endpoint can take.
    def next_endpoint_id : UInt16
      endpoint_id = FIRST_DYNAMIC_ENDPOINT_ID
      while @endpoints.has_key?(endpoint_id)
        endpoint_id += 1
      end
      endpoint_id
    end

    # Get a typed cluster from an endpoint
    # Usage: node.get_cluster(1_u16, OnOff)
    def get_cluster(endpoint_id : UInt16, cluster_type : T.class) : T? forall T
      endpoint(endpoint_id).try(&.get_cluster(cluster_type))
    end

    # Get a typed cluster from an endpoint (raises if not found)
    def get_cluster!(endpoint_id : UInt16, cluster_type : T.class) : T forall T
      get_cluster(endpoint_id, cluster_type) ||
        raise KeyError.new("Cluster #{cluster_type} not found on endpoint #{endpoint_id}")
    end

    # The first cluster of this type anywhere on the node.
    # Usage: node.get_cluster(BasicInformation)
    def get_cluster(cluster_type : T.class) : T? forall T
      found_cluster = @clusters.values.find { |clust| clust.is_a?(T) }
      found_cluster.as(T) if found_cluster
    end

    # The first cluster of this type anywhere on the node (raises if not found)
    def get_cluster!(cluster_type : T.class) : T forall T
      get_cluster(cluster_type) || raise KeyError.new("Cluster #{cluster_type} not found on node")
    end

    # Called with (endpoint, cluster, attribute) whenever any cluster on the
    # node changes an attribute. Applied to every cluster present now and to
    # every cluster added later.
    def on_attribute_changed=(callback : Proc(UInt16, UInt32, UInt32, Nil)?)
      @on_attribute_changed = callback
      each_cluster(&.on_attribute_changed=(callback))
      callback
    end

    # Called with the journaled record whenever any cluster on the node emits
    # an event. Applied to every cluster present now and to every cluster added
    # later, exactly as `on_attribute_changed` is.
    def on_event_emitted=(callback : Proc(EventJournal::Record, Nil)?)
      @on_event_emitted = callback
      each_cluster(&.on_event_emitted=(event_callback))
      callback
    end

    # Called with the cluster whenever any cluster on the node bumps its data
    # version. Applied to every cluster present now and to every cluster added
    # later.
    def on_version_changed=(callback : Proc(Cluster::Base, Nil)?)
      @on_version_changed = callback
      each_cluster { |cluster| apply_version_callback(cluster) }
      callback
    end

    # The validation errors of every endpoint that has any, keyed by endpoint.
    def validate : Hash(UInt16, Array(String))
      errors = {} of UInt16 => Array(String)
      present_device_types = @endpoints.values.flat_map(&.device_types).map(&.device_type_id.id)

      @endpoints.each do |endpoint_id, endpoint|
        endpoint_errors = endpoint.validate
        endpoint.device_types.each do |device_type|
          device_type.required_node_device_types.each do |required_id|
            unless present_device_types.includes?(required_id)
              required_name = DeviceType.name(required_id) || Hex.u32(required_id)
              endpoint_errors << "Missing required #{required_name} device type on node for #{device_type.name}"
            end
          end
          if device_type.device_type_id.id == DeviceType::CAMERA
            endpoint_errors.concat(CameraComposition.validate(self, endpoint_id))
          end
        end
        errors[endpoint_id] = endpoint_errors unless endpoint_errors.empty?
      end

      errors
    end

    # Check if all endpoints are valid
    def valid? : Bool
      validate.empty?
    end

    # Get a human-readable description of this node
    def description : String
      lines = ["Node with #{endpoint_count} endpoint(s):"]
      endpoint_ids.each do |endpoint_id|
        lines << "  #{@endpoints[endpoint_id].description}"
      end
      lines.join("\n")
    end

    private def apply_callbacks(cluster : Cluster::Base) : Nil
      cluster.on_attribute_changed = @on_attribute_changed
      cluster.on_event_emitted = event_callback
      apply_version_callback(cluster)
    end

    # Journals every emitted event, then hands the record to the observer.
    # Wired unconditionally: the journal must see an event even when nothing
    # is subscribed yet.
    private def event_callback : Cluster::EventEmittedCallback
      ->(endpoint_id : UInt16, cluster_id : UInt32, event_id : UInt32, priority : InteractionModel::EventPriority, data : TLV::Any, fabric_index : UInt8?) do
        record = begin
          @event_journal.record(
            endpoint: endpoint_id,
            cluster: cluster_id,
            event: event_id,
            priority: priority,
            data: data,
            fabric_index: fabric_index
          )
        rescue ex
          raise EventJournalError.new("Event was not journaled", ex)
        end
        begin
          @on_event_emitted.try(&.call(record))
        rescue ex
          raise EventObserverError.new("Event observer failed after journaling", ex)
        end
        nil
      end
    end

    private def apply_version_callback(cluster : Cluster::Base) : Nil
      callback = @on_version_changed
      cluster.on_version_changed = callback ? -> { callback.call(cluster) } : nil
    end
  end
end
