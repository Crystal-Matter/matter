require "./cluster"
require "log"

module Matter
  module Cluster
    # OTA Software Update Requestor Cluster (0x002A)
    #
    # Fabric-scoped default OTA provider registry and requestor status. An
    # application can add an update engine separately from this registry.
    # Matter Specification: Core 1.6 § 11.20.7.
    class OtaRequestor < Base
      Log = ::Log.for("matter.cluster.ota_requestor")

      # The class name is shortened from the spec cluster name.
      cluster 0x002A, revision: 1, name: "OtaSoftwareUpdateRequestor", persist_state: false

      # UpdateState enum values
      enum UpdateState : UInt8
        Unknown              = 0
        Idle                 = 1
        Querying             = 2
        DelayedOnQuery       = 3
        Downloading          = 4
        Applying             = 5
        DelayedOnApply       = 6
        RollingBack          = 7
        DelayedOnUserConsent = 8
      end

      # An OTA provider on a fabric (DefaultOTAProviders entries)
      struct ProviderLocation
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 1)]
        property provider_node_id : UInt64

        @[TLV::Field(tag: 2)]
        property endpoint : UInt16

        @[TLV::Field(tag: 254, optional: true)]
        property fabric_index : UInt8?

        def initialize(@provider_node_id : UInt64, @endpoint : UInt16, @fabric_index : UInt8? = nil)
        end
      end

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter default_ota_providers : Array(ProviderLocation)

        def initialize(@data_version, @default_ota_providers)
        end
      end

      attribute 0x0000, :default_ota_providers, Array(ProviderLocation), computed: true,
        writable: true, write_access: :administer, fabric_scoped: true
      attribute 0x0001, :update_possible, Bool, default: false
      attribute 0x0002, :update_state, UpdateState, default: UpdateState::Idle
      attribute 0x0003, :update_state_progress, UInt8, nullable: true

      before_write :default_ota_providers do |entries|
        if request_fabric_index.nil?
          InteractionModel::Status.unsupported_access
        elsif entries.size > 1
          InteractionModel::Status.constraint_error
        end
      end

      @default_ota_providers = [] of ProviderLocation

      def initialize(
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
        @update_possible : Bool = false,
        @update_state : UpdateState = UpdateState::Idle,
        @update_state_progress : UInt8? = nil,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def default_ota_providers(fabric_index : UInt8? = request_fabric_index) : Array(ProviderLocation)
        return [] of ProviderLocation unless fabric_index
        @default_ota_providers.select { |entry| entry.fabric_index == fabric_index }
      end

      def default_ota_providers=(entries : Array(ProviderLocation)) : Nil
        if fabric_index = request_fabric_index
          @default_ota_providers.reject! { |entry| entry.fabric_index == fabric_index }
          @default_ota_providers.concat(entries.map do |entry|
            ProviderLocation.new(entry.provider_node_id, entry.endpoint, fabric_index)
          end)
        else
          @default_ota_providers = entries
        end
        increment_version_and_notify(ATTR_DEFAULT_OTA_PROVIDERS)
      end

      def remove_fabric(fabric_index : UInt8) : Nil
        before = @default_ota_providers.size
        @default_ota_providers.reject! { |entry| entry.fabric_index == fabric_index }
        increment_version_and_notify(ATTR_DEFAULT_OTA_PROVIDERS) if @default_ota_providers.size != before
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @default_ota_providers).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        @data_version = state.data_version
        @default_ota_providers = state.default_ota_providers
      end
    end
  end
end
