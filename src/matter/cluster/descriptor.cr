require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Descriptor Cluster (0x001D)
    #
    # Provides device composition information including device types,
    # server/client clusters, and endpoint hierarchy.
    #
    # Required on all endpoints.
    #
    # Matter Spec: Core 9.5
    class Descriptor < Base
      cluster 0x001D, revision: 3

      feature :tag_list, bit: 0

      # Core SemanticTagStruct, shared by Descriptor.TagList and device
      # composition. A null manufacturer code denotes a standard namespace.
      struct SemanticTag
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter mfg_code : UInt16?
        @[TLV::Field(tag: 1)]
        getter namespace_id : UInt8
        @[TLV::Field(tag: 2)]
        getter tag : UInt8
        @[TLV::Field(tag: 3, optional: true)]
        getter label : String?

        def initialize(@mfg_code : UInt16?, @namespace_id : UInt8, @tag : UInt8,
                       @label : String? = nil)
        end
      end

      # Device Type Structure
      # IMPORTANT: Device type values MUST be encoded with correct widths per Matter spec:
      # - deviceType (tag 0): UInt32
      # - revision (tag 1): UInt16
      # iOS is strict about this - using wrong widths causes "Not Supported"
      struct DeviceTypeStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0, fixed_size: true)]
        property device_type : UInt32 # Device type ID

        @[TLV::Field(tag: 1, fixed_size: true)]
        property revision : UInt16 # Device type revision

        def initialize(@device_type : UInt32, @revision : UInt16)
        end
      end

      # The lists are built by the device while it composes its endpoints
      # (`add_server`, `add_part`, ...); they are fixed once commissioned.
      attribute 0x0000, :device_type_list, Array(DeviceTypeStruct), default: [] of DeviceTypeStruct, fixed: true
      attribute 0x0001, :server_list, Array(UInt32), default: [] of UInt32, fixed: true
      attribute 0x0002, :client_list, Array(UInt32), default: [] of UInt32, fixed: true
      attribute 0x0003, :parts_list, Array(UInt16), default: [] of UInt16, fixed: true
      attribute 0x0004, :tag_list, Array(SemanticTag), default: [] of SemanticTag,
        fixed: true, optional: true, requires: :tag_list

      def initialize(endpoint_id : DataType::EndpointNumber)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        # Descriptor cluster is always a server on every endpoint
        @server_list << CLUSTER_ID
      end

      def configure_tag_list(tags : Array(SemanticTag)) : Nil
        unless tags.empty? || (1..6).includes?(tags.size)
          raise ConfigurationError.new("Descriptor TagList must contain 1 to 6 tags")
        end
        if tags.any? { |tag| tag.label.try(&.bytesize).try { |size| size > 64 } }
          raise ConfigurationError.new("Descriptor tag label exceeds 64 bytes")
        end
        if tags.any? { |tag| tag.mfg_code.nil? && !tag.label.nil? }
          raise ConfigurationError.new("Descriptor standard tags cannot have a label")
        end
        if tags.any?(&.mfg_code) && tags.all?(&.mfg_code)
          raise ConfigurationError.new("Descriptor manufacturer tags require a standard tag")
        end
        @tag_list = tags.dup
        @feature_map = tags.empty? ? Feature::None : Feature::TagList
      end

      # Helper: Check if a cluster is in the server list
      def has_server_cluster?(cluster_id : UInt32) : Bool
        @server_list.includes?(cluster_id)
      end

      # Helper: Check if a cluster is in the server list (by class)
      def has_server_cluster?(cluster_class : Base.class) : Bool
        has_server_cluster?(cluster_class.cluster_id)
      end

      # Helper: Check if a cluster is in the client list
      def has_client_cluster?(cluster_id : UInt32) : Bool
        @client_list.includes?(cluster_id)
      end

      # Helper: Check if a cluster is in the client list (by class)
      def has_client_cluster?(cluster_class : Base.class) : Bool
        has_client_cluster?(cluster_class.cluster_id)
      end

      # Helper: Check if an endpoint is in the parts list
      def has_part?(endpoint_id : UInt16) : Bool
        @parts_list.includes?(endpoint_id)
      end

      # Helper: Get primary device type
      def primary_device_type : DeviceTypeStruct?
        @device_type_list.first?
      end

      # Add a server cluster by class
      #
      # @param cluster_class The cluster class (e.g., OnOff)
      # @return self for chaining
      #
      # Example:
      #   descriptor.add_server(OnOff)
      #             .add_server(LevelControl)
      def add_server(cluster_class : Base.class)
        cluster_id = cluster_class.cluster_id
        @server_list << cluster_id unless @server_list.includes?(cluster_id)
        self
      end

      # Add a client cluster by class
      #
      # @param cluster_class The cluster class (e.g., OnOff)
      # @return self for chaining
      #
      # Example:
      #   descriptor.add_client(OnOff)
      #             .add_client(LevelControl)
      def add_client(cluster_class : Base.class)
        cluster_id = cluster_class.cluster_id
        @client_list << cluster_id unless @client_list.includes?(cluster_id)
        self
      end

      # Add a child endpoint to the parts list
      #
      # @param endpoint_id The endpoint ID
      # @return self for chaining
      #
      # Example:
      #   descriptor.add_part(1_u16)
      #             .add_part(2_u16)
      def add_part(endpoint_id : UInt16)
        @parts_list << endpoint_id unless @parts_list.includes?(endpoint_id)
        self
      end
    end
  end
end
