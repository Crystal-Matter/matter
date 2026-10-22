require "./device_type"
require "./error"
require "./hex"
require "./cluster/cluster"
require "./cluster/color_control"
require "./cluster/descriptor"
require "./cluster/level_control"
require "./cluster/on_off"
require "./cluster/scenes_management"
require "./datatype/endpoint_number"

module Matter
  # One functional unit of a node: a set of device types and the server
  # clusters that implement them.
  #
  # An endpoint owns its clusters; `Node` indexes them for the Interaction
  # Model. The Descriptor cluster is derived rather than declared -
  # `populate_descriptor` injects it when absent and fills it from the clusters
  # and device types actually present.
  class Endpoint
    getter endpoint_id : DataType::EndpointNumber
    getter device_types : Array(DeviceType)
    getter clusters : Hash(UInt32, Cluster::Base)

    def initialize(
      @endpoint_id : DataType::EndpointNumber,
      @device_types : Array(DeviceType) = [] of DeviceType,
    )
      @clusters = {} of UInt32 => Cluster::Base
    end

    # Convenience constructor for single device type
    def initialize(@endpoint_id : DataType::EndpointNumber, device_type : DeviceType)
      @device_types = [device_type]
      @clusters = {} of UInt32 => Cluster::Base
    end

    # The endpoint number this endpoint answers on.
    def number : UInt16
      @endpoint_id.number
    end

    # Adds *cluster*, replacing any cluster already registered under its id.
    # The cluster must have been built for this endpoint.
    def add_cluster(cluster : Cluster::Base) : Cluster::Base
      unless cluster.endpoint_id.number == number
        raise ConfigurationError.new(
          "Cluster endpoint_id (#{cluster.endpoint_id.number}) does not match endpoint (#{number})"
        )
      end

      @clusters[cluster.cluster_id.id] = cluster
      if level = get_cluster(Cluster::LevelControl)
        level.bind_on_off(get_cluster(Cluster::OnOff))
        level.bind_color_control(get_cluster(Cluster::ColorControl))
      end
      if color = get_cluster(Cluster::ColorControl)
        color.bind_on_off(get_cluster(Cluster::OnOff))
      end
      cluster
    end

    # Get a cluster by ID
    def get_cluster(cluster_id : UInt32) : Cluster::Base?
      @clusters[cluster_id]?
    end

    # Get a cluster by ID (raises if not found)
    def get_cluster!(cluster_id : UInt32) : Cluster::Base
      @clusters[cluster_id]? || raise KeyError.new("Cluster #{cluster_id} not found on endpoint #{number}")
    end

    # Get a typed cluster by class
    # Usage: endpoint.get_cluster(OnOff)
    def get_cluster(cluster_type : T.class) : T? forall T
      found_cluster = @clusters.values.find { |clust| clust.is_a?(T) }
      found_cluster.as(T) if found_cluster
    end

    # Get a typed cluster by class (raises if not found)
    def get_cluster!(cluster_type : T.class) : T forall T
      get_cluster(cluster_type) || raise KeyError.new("Cluster #{cluster_type} not found on endpoint #{number}")
    end

    # Check if endpoint has a cluster
    def has_cluster?(cluster_id : UInt32) : Bool
      @clusters.has_key?(cluster_id)
    end

    # Every cluster id on this endpoint, ascending (the Descriptor ServerList order).
    def cluster_ids : Array(UInt32)
      @clusters.keys.sort!
    end

    # Get the number of clusters
    def cluster_count : Int32
      @clusters.size
    end

    # Get primary device type
    def primary_device_type : DeviceType?
      @device_types.first?
    end

    # The Descriptor cluster of this endpoint, injected if the device did not
    # provide one. Every endpoint has a Descriptor per the Matter spec.
    def descriptor : Cluster::Descriptor
      existing = @clusters[Cluster::Descriptor::CLUSTER_ID]?
      return existing.as(Cluster::Descriptor) if existing

      add_cluster(Cluster::Descriptor.new(@endpoint_id)).as(Cluster::Descriptor)
    end

    # Fills the Descriptor from what this endpoint actually holds: every
    # cluster id in the ServerList, every device type (with its own revision)
    # in the DeviceTypeList. Call after the last `add_cluster`.
    def populate_descriptor : Cluster::Descriptor
      descriptor = self.descriptor

      cluster_ids.each do |id|
        descriptor.server_list << id unless descriptor.server_list.includes?(id)
      end

      descriptor.device_type_list.clear
      @device_types.each do |device_type|
        descriptor.device_type_list << Cluster::Descriptor::DeviceTypeStruct.new(
          device_type: device_type.device_type_id.id,
          revision: device_type.revision
        )
      end

      descriptor
    end

    # Lets this endpoint's Scenes Management cluster store and recall the state
    # of every other cluster on the endpoint, keeping any extension callbacks
    # the device installed itself.
    def wire_scene_extensions : Nil
      scenes = @clusters[Cluster::ScenesManagement::CLUSTER_ID]?.as?(Cluster::ScenesManagement)
      return unless scenes

      existing_get = scenes.get_extension_field_sets
      existing_apply = scenes.apply_extension_field_sets

      scenes.get_extension_field_sets = -> do
        sets = [] of Cluster::ScenesManagement::ExtensionFieldSet
        if callback = existing_get
          sets.concat(callback.call)
        end
        sets.concat(@clusters.values.compact_map(&.store_scene_extension_field_set))
        sets
      end

      scenes.apply_extension_field_sets = ->(field_sets : Array(Cluster::ScenesManagement::ExtensionFieldSet)) do
        if callback = existing_apply
          callback.call(field_sets)
        end

        field_sets.each do |field_set|
          if target = @clusters[field_set.cluster_id]?
            target.apply_scene_extension_field_set(field_set)
          end
        end
      end
    end

    # The mandatory server clusters this endpoint's device types are missing,
    # one message each; empty when the endpoint conforms.
    def validate : Array(String)
      errors = [] of String

      @device_types.each do |device_type|
        device_type.required_server_clusters.each do |cluster_id|
          unless has_cluster?(cluster_id)
            errors << "Missing required cluster #{Hex.u16(cluster_id)} for device type #{device_type.name}"
          end
        end
      end

      errors
    end

    # Check if this endpoint is valid (has all required clusters)
    def valid? : Bool
      validate.empty?
    end

    # Get a human-readable description of this endpoint
    def description : String
      device_type_names = @device_types.map(&.name).join(", ")
      "Endpoint #{number}: #{device_type_names} (#{@clusters.size} clusters)"
    end
  end
end
