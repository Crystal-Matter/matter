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

      enum ChangeReason : UInt8
        Unknown         = 0
        Success         = 1
        Failure         = 2
        TimeOut         = 3
        DelayByProvider = 4
      end

      enum AnnouncementReason : UInt8
        SimpleAnnouncement    = 0
        UpdateAvailable       = 1
        UrgentUpdateAvailable = 2
      end

      struct StateTransitionEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property previous_state : UpdateState

        @[TLV::Field(tag: 1)]
        property new_state : UpdateState

        @[TLV::Field(tag: 2)]
        property reason : ChangeReason

        @[TLV::Field(tag: 3, optional: false)]
        property target_software_version : UInt32?

        def initialize(@previous_state : UpdateState, @new_state : UpdateState,
                       @reason : ChangeReason, @target_software_version : UInt32? = nil)
        end
      end

      struct VersionAppliedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property software_version : UInt32

        @[TLV::Field(tag: 1)]
        property product_id : UInt16

        def initialize(@software_version : UInt32, @product_id : UInt16)
        end
      end

      struct DownloadErrorEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property software_version : UInt32

        @[TLV::Field(tag: 1)]
        property bytes_downloaded : UInt64

        @[TLV::Field(tag: 2, optional: false)]
        property progress_percent : UInt8?

        @[TLV::Field(tag: 3, optional: false)]
        property platform_code : Int64?

        def initialize(@software_version : UInt32, @bytes_downloaded : UInt64,
                       @progress_percent : UInt8? = nil, @platform_code : Int64? = nil)
        end
      end

      struct AnnounceProviderRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property provider_node_id : UInt64

        @[TLV::Field(tag: 1)]
        property vendor_id : UInt16

        @[TLV::Field(tag: 2)]
        property announcement_reason : AnnouncementReason

        @[TLV::Field(tag: 3, optional: true)]
        property metadata_for_node : Bytes?

        @[TLV::Field(tag: 4)]
        property endpoint : UInt16

        def initialize(@provider_node_id : UInt64, @vendor_id : UInt16,
                       @announcement_reason : AnnouncementReason, @endpoint : UInt16,
                       @metadata_for_node : Bytes? = nil)
        end
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

      event 0x00, :state_transition, priority: :info, payload: StateTransitionEvent
      event 0x01, :version_applied, priority: :critical, payload: VersionAppliedEvent
      event 0x02, :download_error, priority: :info, payload: DownloadErrorEvent

      command 0x00, :announce_ota_provider, request: AnnounceProviderRequest,
        access: :administer

      property on_announce_provider : Proc(UInt8, UInt64, AnnounceProviderRequest, Nil)?

      before_write :default_ota_providers do |entries|
        if request_fabric_index.nil?
          InteractionModel::Status.unsupported_access
        elsif entries.size > 1
          InteractionModel::Status.constraint_error
        end
      end

      @default_ota_providers = [] of ProviderLocation

      def initialize(
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber::ROOT,
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

      def announce_ota_provider(request : AnnounceProviderRequest) : InteractionModel::Status
        fabric = request_fabric_index
        peer = request_peer_node_id
        return InteractionModel::Status.unsupported_access unless request_is_case_session? && fabric && peer
        if (metadata = request.metadata_for_node) && metadata.size > 512
          return InteractionModel::Status.constraint_error
        end
        @on_announce_provider.try(&.call(fabric, peer, request))
        InteractionModel::Status.success
      end

      def transition_to(new_state : UpdateState, reason : ChangeReason,
                        target_version : UInt32? = nil) : Nil
        previous = @update_state
        return if previous == new_state
        self.update_state = new_state
        emit_event(EVENT_STATE_TRANSITION,
          StateTransitionEvent.new(previous, new_state, reason, target_version))
      end

      def emit_version_applied(software_version : UInt32, product_id : UInt16) : Nil
        emit_event(EVENT_VERSION_APPLIED, VersionAppliedEvent.new(software_version, product_id))
      end

      def emit_download_error(software_version : UInt32, bytes_downloaded : UInt64,
                              progress_percent : UInt8? = nil,
                              platform_code : Int64? = nil) : Nil
        if progress_percent && progress_percent > 100_u8
          raise Matter::ConfigurationError.new("OTA download progress must be 0..100")
        end
        emit_event(EVENT_DOWNLOAD_ERROR,
          DownloadErrorEvent.new(software_version, bytes_downloaded,
            progress_percent, platform_code))
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
