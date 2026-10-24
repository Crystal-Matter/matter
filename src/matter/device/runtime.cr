require "../fabric_table"
require "../node"
require "../transport/udp_transport"
require "../transport/tcp_enabled_transport"
require "../protocol/message_handler"
require "./dsl"
require "./persistence"
require "./lifecycle_manager"

require "../mdns/responder"
require "../mdns/service_type"
require "../datatype/endpoint_number"
require "../network/local_addresses"

require "../cluster/descriptor"
require "../cluster/basic_information"
require "../cluster/access_control"
require "../cluster/general_commissioning"
require "../cluster/operational_credentials"
require "../cluster/administrator_commissioning"
require "../cluster/general_diagnostics"
require "../cluster/network_commissioning"
require "../cluster/group_key_management"
require "../cluster/groupcast"
require "./groupcast_sender"
require "../cluster/ota_requestor"
require "../cluster/tls_certificate_management"
require "../cluster/tls_client_management"
require "../cluster/icd_management"
require "../cluster/diagnostic_logs"
require "../cluster/ethernet_network_diagnostics"
require "../cluster/thread_network_diagnostics"
require "../cluster/time_synchronization"

module Matter
  # A Matter device application.
  #
  # Provides:
  # - Persistence (fabrics, sessions, cluster state, identity) on a `Storage::Backend`
  # - UDP transport (with opt-in TCP listener) + Protocol MessageHandler
  # - Default Root Node clusters (including OperationalCredentials)
  # - Descriptor injection and auto-population
  # - mDNS responder + lifecycle management (commissioning <-> operational)
  # - Endpoints added at runtime from an `endpoint_template`, persisted so they
  #   come back after a restart
  #
  # Subclasses declare themselves with the DSL (`identity`, `storage`,
  # `network`, `endpoint`, `endpoint_template`, `on`; see `DSL`) or implement
  # the identity methods and `device_clusters` by hand. Lifecycle hooks
  # (`before_start`, `on_started`, `started_commissioning_mode`, ...) are
  # overridable either way.
  abstract class Device
    include DSL

    macro inherited
      # DSL declarations accumulate here (see `dsl.cr`); `dsl_generate`
      # turns them into code once the class body is complete.
      IDENTITY_DECLS = [] of Nil
      ENDPOINT_DECLS = [] of Nil
      CLUSTER_DECLS  = [] of Nil
      CALLBACK_DECLS = [] of Nil

      macro finished
        dsl_generate
      end
    end

    getter hostname : String
    getter ip_addresses : Array(Socket::IPAddress)

    # Default Matter operational UDP port.
    DEFAULT_PORT = 5540

    # Application document holding the endpoints added at runtime from an
    # `endpoint_template`, and the keys of one of its entries.
    DYNAMIC_ENDPOINTS_ID    = "endpoints"
    TIME_ZONE_POLL_INTERVAL = 1.second
    ENDPOINTS_KEY           = "endpoints"
    ENDPOINT_ID_KEY         = "endpoint_id"
    TEMPLATE_KEY            = "template"
    PARAMETERS_KEY          = "parameters"

    getter persistence : Persistence
    getter fabric_table : FabricTable

    # The device's data model: its endpoints and their clusters.
    getter node : Node

    getter transport : Transport::UDPTransport
    getter message_handler : Protocol::MessageHandler
    getter responder : MDNS::Responder
    getter lifecycle : LifecycleManager

    # The application supplies a current operational address for a registered
    # Check-In client. No stale CASE peer address is reused after sleep.
    property icd_peer_resolver : Proc(UInt8, UInt64, Socket::IPAddress?)? = nil

    @shutdown_channel : Channel(Nil) = Channel(Nil).new
    @basic_info : Cluster::BasicInformation? = nil
    @general_commissioning : Cluster::GeneralCommissioning? = nil
    @access_control : Cluster::AccessControl? = nil
    @operational_credentials : Cluster::OperationalCredentials? = nil
    @administrator_commissioning : Cluster::AdministratorCommissioning? = nil
    @groupcast_outbound : GroupcastSender? = nil
    @groupcast_sender_enabled : Bool = false

    # Endpoints added from a template, by endpoint number: the template name
    # and the parameters it was built from.
    @dynamic_endpoints : Hash(UInt16, Tuple(String, Storage::Document)) = {} of UInt16 => Tuple(String, Storage::Document)
    @restoring_endpoints : Bool = false
    @started : Bool = false
    @time_zone_polling : Bool = false
    @time_zone_poll_done : Channel(Nil)? = nil
    @time_zone_poll_fiber : Fiber? = nil

    def basic_info : Cluster::BasicInformation
      @basic_info.as(Cluster::BasicInformation)
    end

    def general_commissioning : Cluster::GeneralCommissioning
      @general_commissioning.as(Cluster::GeneralCommissioning)
    end

    def access_control : Cluster::AccessControl
      @access_control.as(Cluster::AccessControl)
    end

    def operational_credentials : Cluster::OperationalCredentials
      @operational_credentials.as(Cluster::OperationalCredentials)
    end

    def administrator_commissioning : Cluster::AdministratorCommissioning
      @administrator_commissioning.as(Cluster::AdministratorCommissioning)
    end

    # Send an untimed, one-way group command from this device's fabric. The
    # Groupcast SD feature and a joined Sender membership are required.
    def send_groupcast_invoke(fabric_index : UInt8, group_id : UInt16,
                              cluster_id : UInt32, command_id : UInt32,
                              fields : Bytes = Bytes.empty) : Nil
      groupcast_outbound.invoke(fabric_index, group_id, cluster_id, command_id, fields)
    end

    # Forward from a synchronous CASE command callback to all joined Sender
    # groups on that command's authenticated fabric.
    def send_groupcast_invoke_for_request(source : Cluster::Base, cluster_id : UInt32,
                                          command_id : UInt32, fields : Bytes = Bytes.empty) : Nil
      groupcast_outbound.invoke_joined_for_request(source, cluster_id, command_id, fields)
    end

    def send_groupcast_write(fabric_index : UInt8, group_id : UInt16,
                             cluster_id : UInt32, attribute_id : UInt32,
                             value : TLV::Any) : Nil
      groupcast_outbound.write(fabric_index, group_id, cluster_id, attribute_id, value)
    end

    private def groupcast_outbound : GroupcastSender
      @groupcast_outbound || raise ConfigurationError.new("Groupcast Sender feature is disabled")
    end

    def port : Int32
      @transport.port
    end

    def initialize(
      storage : Storage::Backend,
      ip_addresses : Array(Socket::IPAddress)? = nil,
      port : Int32 = DEFAULT_PORT,
      hostname : String? = nil,
      max_fabrics : UInt8 = FabricTable::DEFAULT_MAX_FABRICS,
      @network_backend : Network::Backend? = nil,
      @tc_min_required_version : UInt16? = nil,
      @tc_required_acknowledgements : UInt16 = 0_u16,
      @icd_configuration : Cluster::IcdManagement::Configuration? = nil,
      @regulatory_location_capability : Cluster::GeneralCommissioning::RegulatoryLocationType = Cluster::GeneralCommissioning::RegulatoryLocationType::IndoorOutdoor,
      @tcp_enabled : Bool = false,
      @groupcast_listener : Bool = false,
      groupcast_sender : Bool = false,
      groupcast_per_group : Bool = false,
      groupcast_max_mcast_addr_count : UInt16? = nil,
    )
      @groupcast_sender_enabled = groupcast_sender
      @groupcast_per_group_enabled = groupcast_per_group
      @groupcast_max_mcast_addr_count = groupcast_max_mcast_addr_count ||
                                        (groupcast_per_group ? Cluster::Groupcast::DEFAULT_MAX_MEMBERSHIP_COUNT : Cluster::Groupcast::DEFAULT_MAX_MCAST_ADDR_COUNT)
      if @groupcast_per_group_enabled && !(@groupcast_listener || @groupcast_sender_enabled)
        raise ConfigurationError.new("Groupcast PerGroup requires Listener or Sender")
      end
      if @groupcast_sender_enabled && storage.path.nil?
        raise ConfigurationError.new("Groupcast Sender requires durable storage")
      end
      # Matter Core 1.6 §11.10.6.4 requires IndoorOutdoor for nodes without
      # radio network interfaces. This device API currently models one network.
      if commissioning_network_type.ethernet? && !@regulatory_location_capability.indoor_outdoor?
        raise ConfigurationError.new("Ethernet-only devices require IndoorOutdoor regulatory capability")
      end
      @ip_addresses = ip_addresses || default_ip_addresses

      @persistence = Persistence.new(storage, max_fabrics: max_fabrics)
      @fabric_table = @persistence.fabric_table
      @hostname = hostname || @persistence.commissioning_hostname

      @transport = if @tcp_enabled
                     Transport::TcpEnabledTransport.new(port: port)
                   else
                     Transport::UDPTransport.new(port: port)
                   end
      @message_handler = Protocol::MessageHandler.new(
        transport: @transport,
        setup_pin: setup_pin,
        discriminator: discriminator,
        fabric_table: @fabric_table,
        vendor_id: vendor_id,
        product_id: product_id,
        persistence: @persistence.protocol_persistence
      )

      @responder = MDNS::Responder.new(hostname: @hostname, ip_addresses: @ip_addresses)

      # One place where every cluster, however late it joins the node, gets
      # its state written on change.
      @node = @message_handler.node
      @node.on_version_changed = ->(cluster : Cluster::Base) { @persistence.mark_dirty(cluster) }

      build_and_wire_clusters
      @message_handler.clusters.values.each do |cluster|
        wire_ecosystem_information(cluster)
        wire_tls_certificate_management(cluster)
        wire_tls_client_management(cluster)
        wire_push_av_stream_transport(cluster)
        validate_thread_network_directory(cluster)
      end
      @message_handler.setup_cluster_notifications

      # Restore cluster state (scenes, groups, etc.) and track changes
      @persistence.restore_clusters(@message_handler.clusters.values)
      # Remove ACLs whose fabric document is absent. This also repairs an
      # interrupted ordinary RemoveFabric, where the fabric delete succeeded
      # but the ACL write did not. Do this before CASE can use a recycled index.
      orphan_acl_indices = access_control.acl.compact_map(&.fabric_index).uniq!.reject do |index|
        @fabric_table.get_fabric(index)
      end
      orphan_acl_indices.each do |index|
        access_control.remove_fabric_acl(index)
      end
      if !orphan_acl_indices.empty? || @persistence.recovered_added_fabric_index
        unless @persistence.save_cluster(access_control)
          raise StorageError.new("Could not persist recovered fabric ACL cleanup")
        end
        @persistence.complete_credential_recovery
      end
      @message_handler.refresh_group_memberships
      if @groupcast_sender_enabled
        groupcast = @node.get_cluster(Cluster::Groupcast).as(Cluster::Groupcast)
        group_keys = @node.get_cluster(Cluster::GroupKeyManagement).as(Cluster::GroupKeyManagement)
        sender = Protocol::GroupMessageSender.new(@transport,
          Session::GroupOutgoingCounters.new(@persistence.backend))
        @groupcast_outbound = GroupcastSender.new(@fabric_table, groupcast, group_keys, sender)
      end
      if icd = icd_management
        icd.retain_fabrics(@fabric_table.all_fabrics.map(&.fabric_index))
        # restore_state advances the counter by 1000; commit that advancement
        # before any outbound Check-In can reuse a prior AES-CCM nonce.
        @persistence.save_cluster(icd)
        icd.on_persist_counter = -> { @persistence.save_cluster(icd) }
        icd.on_persist_registration = -> { @persistence.save_cluster(icd) }
        icd.on_monitored_subject_covered = ->(fabric_index : UInt8, subject : UInt64) do
          @message_handler.active_subscriptions.each_value.any? do |subscription|
            session = subscription.session
            session.case_session? && session.fabric_index == fabric_index &&
              (session.peer_subject_ids.includes?(subject) || session.peer_node_id.try(&.id) == subject)
          end
        end
        icd.on_check_in = ->(fabric_index : UInt8, node_id : UInt64, key : Bytes, counter : UInt32, threshold : UInt16) do
          if peer = @icd_peer_resolver.try(&.call(fabric_index, node_id))
            send_icd_check_in(peer, key, counter, threshold)
          end
          nil
        end
      end

      @lifecycle = LifecycleManager.new(
        fabric_table: @fabric_table,
        registry: @message_handler.registry,
        operational_credentials: operational_credentials,
        responder: @responder,
        port: @transport.port,
        commissioning_info: -> { commissioning_info },
        operational_info_factory: ->(fabric : Fabric) { operational_info_for(fabric) }
      )

      @lifecycle.on_fabric_added = ->(fabric : Fabric) { fabric_added(fabric) }
      @lifecycle.on_fabric_removed = ->(fabric_index : UInt8) do
        @message_handler.forget_group_fabric(fabric_index)
        @message_handler.node.get_cluster(Cluster::OtaRequestor).try(&.remove_fabric(fabric_index))
        @message_handler.clusters.values.each do |cluster|
          cluster.as?(Cluster::PushAvStreamTransport).try(&.remove_fabric(fabric_index))
        end
        @message_handler.clusters.values.each do |cluster|
          if ecosystem_information = cluster.as?(Cluster::EcosystemInformation)
            ecosystem_information.remove_fabric(fabric_index)
            unless @persistence.save_cluster(ecosystem_information)
              @persistence.mark_dirty(ecosystem_information)
              raise StorageError.new("Could not persist erased Ecosystem Information for fabric #{fabric_index}")
            end
          end
          if messages = cluster.as?(Cluster::Messages)
            messages.remove_fabric(fabric_index)
            unless @persistence.save_cluster(messages)
              @persistence.mark_dirty(messages)
              raise StorageError.new("Could not persist erased Messages for fabric #{fabric_index}")
            end
          end
          cluster.as?(Cluster::CommissionerControl).try(&.remove_fabric(fabric_index))
          cluster.as?(Cluster::TlsClientManagement).try(&.remove_fabric(fabric_index))
          cluster.as?(Cluster::TlsCertificateManagement).try(&.remove_fabric(fabric_index))
        end
        icd_management.try do |fabric_icd|
          fabric_icd.remove_fabric(fabric_index)
          @persistence.save_cluster(fabric_icd)
        end
        fabric_removed(fabric_index)
      end
      @lifecycle.on_commissioned = ->(fabric : Fabric) do
        started_operational_mode
        commissioned(fabric)
      end
      @lifecycle.on_decommissioned = -> do
        started_commissioning_mode
        decommissioned
      end

      restore_dynamic_endpoints
    end

    # Starts mDNS and the configured transport and syncs advertisements for the current fabric set.
    # Returns immediately after starting - use `await_shutdown` to block until shutdown.
    # Pass `ota_restart: true` when resuming after an OTA update so Level
    # Control retains its pre-update CurrentLevel (Matter 1.6 §1.6.6.15).
    def start(ota_restart : Bool = false) : Nil
      @message_handler.clusters.each_value do |cluster|
        cluster.as?(Cluster::LevelControl).try(&.apply_startup_level(ota_restart: ota_restart))
      end
      @message_handler.clusters.each_value do |cluster|
        cluster.as?(Cluster::ColorControl).try(&.apply_startup_color_temperature(ota_restart: ota_restart))
      end
      before_start
      @lifecycle.sync_advertisements
      @fabric_table.empty? ? started_commissioning_mode : started_operational_mode
      # Start the TCP listener before publishing T=4 in operational mDNS.
      @transport.start if @tcp_enabled
      @responder.start
      @transport.start unless @tcp_enabled
      @started = true
      start_time_zone_polling
      @node.get_cluster(Node::ROOT_ENDPOINT_ID, Cluster::GeneralDiagnostics)
        .try(&.emit_boot_reason_event)
      on_started
    rescue error
      Log.error(exception: error) { "error during startup" }
      shutdown!
    end

    # Blocks until `shutdown!` is called. Optional - use when you need the main
    # fiber to wait for shutdown (e.g., in a daemon or CLI application).
    # Multiple fibers can safely wait on this.
    def await_shutdown : Nil
      @shutdown_channel.receive?
    end

    # Signals shutdown, stops all services, and unblocks all `await_shutdown` waiters.
    # Safe to call from signal handlers or other fibers.
    def shutdown! : Nil
      # An application event callback may request shutdown from the polling
      # fiber. Let that callback unwind before a separate fiber joins it and
      # closes the event journal; joining here would deadlock.
      if Fiber.current == @time_zone_poll_fiber
        @time_zone_polling = false
        spawn { shutdown! }
        return
      end
      @started = false
      @time_zone_polling = false
      @time_zone_poll_done.try(&.receive?)
      # Persist all session state before shutdown to ensure message counters
      # and other session data are saved for clean reconnection after restart
      @message_handler.persist_all_sessions

      # Stop the session sweep before the store closes under it.
      @message_handler.close

      @persistence.flush
      @persistence.close
      @transport.close
      @responder.stop
      on_shutdown
    rescue error
      Log.error(exception: error) { "error performing shutdown" }
    ensure
      # The poll-fiber callback only schedules shutdown; its replacement fiber
      # closes the channel after services have actually stopped.
      @shutdown_channel.close unless Fiber.current == @time_zone_poll_fiber
    end

    # Only a root node advertising the optional TimeZone feature needs this
    # poll. Shutdown joins the fiber before closing the persistence journal.
    private def start_time_zone_polling : Nil
      return if @time_zone_polling
      time_zones = [] of Cluster::TimeSynchronization
      @message_handler.clusters.each_value do |cluster|
        if time_zone = cluster.as?(Cluster::TimeSynchronization)
          time_zones << time_zone if time_zone.feature_map.time_zone?
        end
      end
      return if time_zones.empty?

      @time_zone_polling = true
      done = Channel(Nil).new
      @time_zone_poll_done = done
      @time_zone_poll_fiber = spawn do
        while @time_zone_polling
          sleep TIME_ZONE_POLL_INTERVAL
          break unless @time_zone_polling
          begin
            time_zones.each(&.advance_time_state)
          rescue error
            Log.error(exception: error) { "TimeZone polling stopped after a cluster error" }
            @time_zone_polling = false
          end
        end
      ensure
        done.close
      end
    end

    # ------------------------------------------------------------------------
    # Required device identity
    # ------------------------------------------------------------------------
    abstract def device_name : String
    abstract def vendor_id : UInt16
    abstract def product_id : UInt16
    abstract def discriminator : UInt16
    abstract def setup_pin : UInt32
    abstract def primary_device_type_id : UInt32

    # ------------------------------------------------------------------------
    # Optional identity / BasicInformation fields
    # ------------------------------------------------------------------------
    def vendor_name : String
      "Crystal Matter"
    end

    def product_name : String
      device_name
    end

    def hardware_version : UInt16
      1_u16
    end

    def hardware_version_string : String
      "1.0"
    end

    def software_version : UInt32
      1_u32
    end

    def software_version_string : String
      "1.0.0"
    end

    def serial_number : String?
      nil
    end

    def unique_id : String?
      nil
    end

    def product_appearance : Cluster::BasicInformation::ProductAppearanceStruct?
      nil
    end

    # ------------------------------------------------------------------------
    # Device clusters / endpoints
    # ------------------------------------------------------------------------
    # The device-specific clusters (typically for endpoint(s) > 0). Generated
    # from the `endpoint` declarations; a device with none holds only the Root
    # Node clusters.
    protected def device_clusters : Array(Cluster::Base)
      [] of Cluster::Base
    end

    # Map endpoint -> device type ID for Descriptor population.
    protected def endpoint_device_types : Hash(UInt16, UInt32)
      {1_u16 => primary_device_type_id} of UInt16 => UInt32
    end

    # ------------------------------------------------------------------------
    # Networking / diagnostics defaults
    # ------------------------------------------------------------------------
    protected def commissioning_network_type : Cluster::NetworkCommissioning::NetworkType
      Cluster::NetworkCommissioning::NetworkType::Ethernet
    end

    protected def commissioning_network_feature_map : Cluster::NetworkCommissioning::Feature
      Cluster::NetworkCommissioning::Feature::EthernetNetworkInterface
    end

    protected def include_ethernet_diagnostics? : Bool
      commissioning_network_type.ethernet?
    end

    # ------------------------------------------------------------------------
    # Hooks (override as needed)
    # ------------------------------------------------------------------------
    protected def before_start : Nil
    end

    # Called after the device is fully started. Use this to spawn background
    # fibers (e.g., interactive CLI loop). Non-blocking - returns immediately.
    protected def on_started : Nil
    end

    # Called after `stop` completes during `shutdown!`. Use for final cleanup.
    protected def on_shutdown : Nil
    end

    protected def started_commissioning_mode : Nil
    end

    protected def started_operational_mode : Nil
    end

    protected def fabric_added(fabric : Fabric) : Nil
    end

    protected def fabric_removed(fabric_index : UInt8) : Nil
    end

    protected def commissioned(fabric : Fabric) : Nil
    end

    protected def decommissioned : Nil
    end

    # ------------------------------------------------------------------------
    # mDNS info factories (override for ICD, TCP, etc)
    # ------------------------------------------------------------------------
    protected def commissioning_info_for(mode : MDNS::CommissioningMode) : MDNS::CommissioningInfo
      MDNS::CommissioningInfo.new(
        device_name: device_name,
        vendor_id: vendor_id,
        product_id: product_id,
        discriminator: discriminator,
        device_type: primary_device_type_id,
        commissioning_mode: mode
      )
    end

    protected def commissioning_info : MDNS::CommissioningInfo
      commissioning_info_for(MDNS::CommissioningMode::Basic)
    end

    protected def operational_info_for(fabric : Fabric) : MDNS::OperationalInfo
      icd = icd_management
      MDNS::OperationalInfo.new(
        compressed_fabric_id: fabric.compressed_fabric_id,
        node_id: fabric.node_id,
        session_idle_interval: icd && icd.operating_mode.sit? ? icd.idle_mode_duration * 1000_u32 : nil,
        session_active_interval: icd.try(&.active_mode_duration),
        tcp_supported: @tcp_enabled
      )
    end

    def icd_management : Cluster::IcdManagement?
      @node.get_cluster(Cluster::IcdManagement)
    end

    def icd_enter_idle_mode : Nil
      icd_management.try(&.enter_idle_mode)
    end

    def icd_request_active_mode : Nil
      icd_management.try(&.request_active_mode)
    end

    def icd_trigger_user_active_mode : Nil
      icd_management.try(&.trigger_user_active_mode)
    end

    private def send_icd_check_in(peer : Socket::IPAddress, key : Bytes,
                                  counter : UInt32, threshold : UInt16) : Nil
      payload = Protocol::Icd::CheckInMessage.encode_icd(key, counter, threshold)
      packet = Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16,
        session_type: Codec::MessageCodec::SessionType::Unicast,
        message_id: 0_u32)
      header = Codec::MessageCodec::PayloadHeader.new(
        exchange_id: Random::Secure.rand(UInt16),
        protocol_id: Protocol::ProtocolId::SecureChannel.value,
        message_type: Protocol::SecureChannelMessageType::IcdCheckIn.value,
        initiator_message: true,
        requires_acknowledge: false)
      @transport.send_message(Codec::MessageCodec::Message.new(packet, header, payload), peer)
    end

    # ------------------------------------------------------------------------
    # Internal wiring
    # ------------------------------------------------------------------------
    private def restore_stored_document(collection : String, id : String,
                                        previous : Storage::Document?) : Nil
      if previous
        @persistence.backend.write(collection, id, previous)
      else
        @persistence.backend.delete(collection, id)
      end
    end

    private def build_and_wire_clusters : Nil
      endpoint_0 = DataType::EndpointNumber.new(0_u16)

      # Root Node clusters
      basic_info = Cluster::BasicInformation.new(
        endpoint_0,
        data_model_revision: 1_u16,
        vendor_name: vendor_name,
        vendor_id: vendor_id,
        product_name: product_name,
        product_id: product_id,
        hardware_version: hardware_version,
        hardware_version_string: hardware_version_string,
        software_version: software_version,
        software_version_string: software_version_string,
        serial_number: serial_number || @persistence.serial_number,
        unique_id: unique_id || @persistence.unique_id,
        product_appearance: product_appearance
      )
      @basic_info = basic_info

      general_commissioning = if tc_version = @tc_min_required_version
                                Cluster::GeneralCommissioning.new(endpoint_0,
                                  feature_map: Cluster::GeneralCommissioning::Feature::TermsAndConditions,
                                  tc_min_required_version: tc_version,
                                  tc_required_acknowledgements: @tc_required_acknowledgements,
                                  location_capability: @regulatory_location_capability)
                              else
                                Cluster::GeneralCommissioning.new(endpoint_0,
                                  location_capability: @regulatory_location_capability)
                              end
      access_control = Cluster::AccessControl.new(endpoint_0,
        feature_map: @groupcast_listener ? Cluster::AccessControl::Feature::Extension | Cluster::AccessControl::Feature::Auxiliary : Cluster::AccessControl::Feature::Extension)
      @general_commissioning = general_commissioning
      @access_control = access_control
      general_commissioning.on_tc_acceptance_write = ->(document : Storage::Document) do
        backend = @persistence.backend
        key = general_commissioning.persistence_key
        previous = backend.read(Storage::Collections::CLUSTERS, key)
        begin
          backend.write(Storage::Collections::CLUSTERS, key, document)
        rescue ex
          restore_stored_document(Storage::Collections::CLUSTERS, key, previous)
          raise ex
        end
      end
      operational_credentials = Cluster::OperationalCredentials.new(
        @fabric_table,
        endpoint_0,
        access_control_cluster: access_control,
        general_commissioning_cluster: general_commissioning
      )
      @operational_credentials = operational_credentials
      configure_attestation(operational_credentials)

      # Ensure OperationalCredentials resets its internal per-failsafe state when a
      # new failsafe context is armed (required for follow-up CSR/UpdateNOC flows).
      general_commissioning.on_failsafe_armed = -> { operational_credentials.on_failsafe_armed }
      general_commissioning.on_failsafe_expired = -> { operational_credentials.on_failsafe_expired }
      general_commissioning.on_failsafe_success = -> do
        if tc_state = general_commissioning.pending_tc_commit_state
          # A successful CommissioningComplete must not durably retain the NOC
          # while losing the user's acknowledged terms in the debounce window.
          # File backends flush this transaction with one atomic rename.
          key = general_commissioning.persistence_key
          backend = @persistence.backend
          previous_tc = backend.read(Storage::Collections::CLUSTERS, key)
          previous_journal = backend.read(Commissioning::CredentialJournal::COLLECTION,
            Commissioning::CredentialJournal::ID)
          general_commissioning.with_pending_tc_commit do
            begin
              backend.transaction do
                backend.write(Storage::Collections::CLUSTERS, key, tc_state)
                Commissioning::CredentialJournal.clear(backend)
              end
            rescue ex
              # TreeBackend coalesces writes but does not roll back its tree
              # when the file flush fails. Restore both documents before a
              # later write could accidentally persist an unacknowledged TC.
              backend.transaction do
                restore_stored_document(Storage::Collections::CLUSTERS, key, previous_tc)
                restore_stored_document(Commissioning::CredentialJournal::COLLECTION,
                  Commissioning::CredentialJournal::ID, previous_journal)
              end
              raise ex
            end

            # Only after the file flush succeeded do the two services drop
            # their provisional in-memory state. A debounced writer sees the
            # pending document until this transition is complete.
            general_commissioning.commit_tc_acceptance(publish: false)
            operational_credentials.on_failsafe_success
          end
          general_commissioning.publish_tc_commit
        else
          operational_credentials.on_failsafe_success
        end
      end

      # Ensure attestation signatures can access the PASE session's attestation_challenge.
      sessions = @message_handler.sessions
      operational_credentials.session_lookup = ->(session_id : UInt64) : Bytes? do
        sessions[session_id.to_u16]?.try(&.attestation_challenge)
      end

      administrator_commissioning = Cluster::AdministratorCommissioning.new(endpoint_0)
      @administrator_commissioning = administrator_commissioning
      general_commissioning.on_close_commissioning_window = -> do
        administrator_commissioning.close_window if administrator_commissioning.window_open?
      end

      general_diagnostics = Cluster::GeneralDiagnostics.new(endpoint_0)
      general_diagnostics.on_device_load_status = ->(fabric_index : UInt8?) do
        @message_handler.device_load_status(fabric_index)
      end
      network_commissioning = Cluster::NetworkCommissioning.new(
        endpoint_0,
        network_type: commissioning_network_type,
        feature_map: commissioning_network_feature_map,
        backend: @network_backend
      )
      network_commissioning.on_breadcrumb_success = ->(value : UInt64) do
        general_commissioning.breadcrumb = value
        nil
      end
      group_key_management = if @groupcast_listener || @groupcast_sender_enabled
                               Cluster::GroupKeyManagement.new(endpoint_0,
                                 feature_map: Cluster::GroupKeyManagement::Feature::Groupcast,
                                 max_groups_per_fabric: 0_u16)
                             else
                               Cluster::GroupKeyManagement.new(endpoint_0)
                             end
      groupcast_features = Cluster::Groupcast::Feature::None
      groupcast_features |= Cluster::Groupcast::Feature::Listener if @groupcast_listener
      groupcast_features |= Cluster::Groupcast::Feature::Sender if @groupcast_sender_enabled
      groupcast_features |= Cluster::Groupcast::Feature::PerGroup if @groupcast_per_group_enabled
      groupcast = if @groupcast_listener || @groupcast_sender_enabled
                    Cluster::Groupcast.new(endpoint_0, group_key_management, access_control,
                      feature_map: groupcast_features,
                      max_mcast_addr_count: @groupcast_max_mcast_addr_count)
                  end
      ota_requestor = Cluster::OtaRequestor.new(endpoint_0)
      icd_management = @icd_configuration.try { |config| Cluster::IcdManagement.new(endpoint_0, configuration: config) }
      diagnostic_logs = Cluster::DiagnosticLogs.new(endpoint_0)
      diagnostic_logs.on_bdx_transfer = ->(session_id : UInt16, fabric_index : UInt8, peer_node_id : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
        @message_handler.queue_bdx_transfer(session_id, fabric_index,
          peer_node_id, peer, designator, content)
      end
      ethernet_diagnostics = include_ethernet_diagnostics? ? Cluster::EthernetNetworkDiagnostics.new(endpoint_0) : nil
      wifi_diagnostics = commissioning_network_type.wi_fi? ? Cluster::WiFiNetworkDiagnostics.new(endpoint_0) : nil
      thread_diagnostics = commissioning_network_type.thread? ? Cluster::ThreadNetworkDiagnostics.new(endpoint_0) : nil

      # Wire commissioning-window mDNS advertisement via the Responder.
      # This enables multi-admin flows (chip-tool/iOS) that require _matterc advertising
      # while the commissioning window is open, even when already operational.
      # A basic window (nil discriminator) advertises the device's own discriminator.
      administrator_commissioning.on_start_commissioning_advertising = ->(disc : UInt16?, mode : MDNS::CommissioningMode) do
        @responder.stop_commissioning
        info = commissioning_info_for(mode)
        info.discriminator = disc if disc
        @responder.advertise_commissioning(info, port: port)
      end
      administrator_commissioning.on_stop_commissioning_advertising = -> do
        @responder.stop_commissioning
      end

      # Wire commissioning-window PASE configuration into the protocol layer.
      # Enhanced windows provide a pre-computed SPAKE2+ verifier (w0||L).
      administrator_commissioning.on_configure_pase_server = ->(verifier : Bytes, iterations : UInt32, salt : Bytes) do
        @message_handler.configure_pase_server(verifier, iterations, salt)
      end
      administrator_commissioning.on_configure_pase_pin = ->(_pin : UInt32, iterations : UInt32, salt : Bytes) do
        # OpenBasicCommissioningWindow uses the device's default passcode; ignore any
        # test pin passed by the cluster implementation.
        @message_handler.configure_pase_pin(setup_pin, iterations, salt)
      end
      administrator_commissioning.on_stop_pase_server = -> do
        @message_handler.reset_pase_server
      end

      # The subclass's clusters, split by the endpoint each was built for.
      declared_types = endpoint_device_types
      device_endpoints = device_clusters.group_by(&.endpoint_id.number)

      # Root endpoint: replaces the MessageHandler defaults wholesale.
      root = Endpoint.new(endpoint_0, device_types_for(Node::ROOT_ENDPOINT_ID, declared_types))
      [
        basic_info,
        general_commissioning,
        access_control,
        operational_credentials,
        administrator_commissioning,
        general_diagnostics,
        network_commissioning,
        group_key_management,
        ota_requestor,
        diagnostic_logs,
      ].each { |cluster| root.add_cluster(cluster) }
      root.add_cluster(groupcast.as(Cluster::Groupcast)) if groupcast
      root.add_cluster(icd_management.as(Cluster::IcdManagement)) if icd_management
      root.add_cluster(ethernet_diagnostics.as(Cluster::EthernetNetworkDiagnostics)) if ethernet_diagnostics
      root.add_cluster(wifi_diagnostics.as(Cluster::WiFiNetworkDiagnostics)) if wifi_diagnostics
      root.add_cluster(thread_diagnostics.as(Cluster::ThreadNetworkDiagnostics)) if thread_diagnostics
      device_endpoints.delete(Node::ROOT_ENDPOINT_ID).try(&.each { |cluster| root.add_cluster(cluster) })
      @node.add_endpoint(root)

      device_endpoints.each do |endpoint_id, clusters|
        endpoint = Endpoint.new(
          DataType::EndpointNumber.new(endpoint_id),
          device_types_for(endpoint_id, declared_types)
        )
        clusters.each { |cluster| endpoint.add_cluster(cluster) }
        @node.add_endpoint(endpoint)
      end

      if listener = groupcast
        listener.endpoint_exists = ->(endpoint_id : UInt16) { !@node.endpoint(endpoint_id).nil? }
        listener.on_membership_changed = -> { @message_handler.refresh_group_memberships }
      end

      refresh_root_parts_list
      topology_errors = @node.validate
      unless topology_errors.empty?
        raise ConfigurationError.new("Incomplete device-type topology: #{topology_errors}")
      end
    end

    # The device types of *endpoint_id*: every endpoint 0 is a Root Node, on
    # top of whatever the subclass declared for it.
    private def device_types_for(endpoint_id : UInt16, declared_types : Hash(UInt16, UInt32)) : Array(DeviceType)
      device_types = [] of DeviceType
      device_types << DeviceType.root_node if endpoint_id == Node::ROOT_ENDPOINT_ID
      if declared = declared_types[endpoint_id]?
        device_types << DeviceType.for(declared)
      end
      device_types
    end

    # The root endpoint's PartsList is the list of every other endpoint.
    private def refresh_root_parts_list : Nil
      descriptor = root_descriptor
      descriptor.parts_list.clear
      @node.endpoint_ids.each do |endpoint_id|
        next if endpoint_id == Node::ROOT_ENDPOINT_ID
        descriptor.add_part(endpoint_id)
      end
    end

    private def root_descriptor : Cluster::Descriptor
      @node.endpoint!(Node::ROOT_ENDPOINT_ID).descriptor
    end

    private def notify_root_parts_list : Nil
      @message_handler.notify_subscriptions(
        Node::ROOT_ENDPOINT_ID,
        Cluster::Descriptor::CLUSTER_ID,
        Cluster::Descriptor::ATTR_PARTS_LIST
      )
    end

    # Default to ephemeral test credentials unless the device overrides.
    protected def configure_attestation(operational_credentials : Cluster::OperationalCredentials) : Nil
      operational_credentials.set_attestation_from_manager(vendor_id: vendor_id, product_id: product_id)
    end

    # The addresses the device advertises when the caller names none: the
    # routable interface's addresses, or loopback when there is none.
    protected def default_ip_addresses : Array(Socket::IPAddress)
      Network.local_ip_addresses
    end

    # Updates the default commissioning target hostname used for mDNS advertisements.
    # This is useful for platforms that rotate link-layer identifiers or for hosting
    # multiple virtual devices in one executable.
    def update_hostname(hostname : String) : Nil
      normalized = hostname.strip
      raise ArgumentError.new("hostname must be non-empty") if normalized.empty?

      @hostname = normalized
      @persistence.update_hostname(normalized)
      @responder.update_commissioning_hostname(normalized)
    end

    # ------------------------------------------------------------------------
    # Dynamic Endpoint Management (for bridges)
    # ------------------------------------------------------------------------

    # Adds an endpoint built from the `endpoint_template` named *template*,
    # taking the next free endpoint number unless *endpoint_id* names one.
    # The parameters are persisted, so the endpoint is rebuilt on the next
    # start. Returns the endpoint.
    def add_endpoint(template : Symbol, endpoint_id : UInt16? = nil, **parameters) : Endpoint
      document = Storage::Document.new
      parameters.each { |key, value| document[key.to_s] = storage_value(key, value) }
      add_endpoint(template, document, endpoint_id: endpoint_id)
    end

    # :ditto:
    def add_endpoint(
      template : Symbol | String,
      parameters : Storage::Document,
      endpoint_id : UInt16? = nil,
      notify_subscribers : Bool = true,
    ) : Endpoint
      name = template.to_s
      number = endpoint_id || next_endpoint_id
      clusters, device_types = template_endpoint(name, number, parameters)

      unless add_endpoint(number, device_types, clusters, notify_subscribers: notify_subscribers)
        raise ConfigurationError.new("Endpoint #{number} already exists")
      end

      @dynamic_endpoints[number] = {name, parameters}
      save_dynamic_endpoints
      @node.endpoint!(number)
    end

    # Adds a new endpoint with the given clusters at runtime.
    # This is primarily used by bridge devices to add bridged endpoints dynamically.
    #
    # The clusters should already be configured with the correct endpoint_id.
    # A Descriptor is injected and populated by the node, and the endpoint is
    # held to its device type: a missing mandatory cluster raises
    # `ConfigurationError`.
    #
    # *device_type_revision* defaults to the revision of the device type
    # definition. Set `notify_subscribers` to false when restoring endpoints
    # from storage to avoid sending spurious subscription updates on startup.
    #
    # Returns true if the endpoint was added successfully, false if it already exists.
    def add_endpoint(
      endpoint_id : UInt16,
      device_type : UInt32,
      clusters : Array(Cluster::Base),
      device_type_revision : UInt16? = nil,
      notify_subscribers : Bool = true,
    ) : Bool
      install_endpoint(
        endpoint_id,
        [dynamic_device_type(device_type, device_type_revision)],
        clusters,
        notify_subscribers
      )
    end

    # :ditto:
    def add_endpoint(
      endpoint_id : UInt16,
      device_types : Array(UInt32),
      clusters : Array(Cluster::Base),
      notify_subscribers : Bool = true,
    ) : Bool
      install_endpoint(endpoint_id, device_types.map { |id| DeviceType.for(id) }, clusters, notify_subscribers)
    end

    private def install_endpoint(
      endpoint_id : UInt16,
      device_types : Array(DeviceType),
      clusters : Array(Cluster::Base),
      notify_subscribers : Bool,
    ) : Bool
      # Don't allow adding endpoint 0 (root node)
      return false if endpoint_id == Node::ROOT_ENDPOINT_ID
      return false if @node.has_endpoint?(endpoint_id)

      endpoint = Endpoint.new(DataType::EndpointNumber.new(endpoint_id), device_types)
      clusters.each do |cluster|
        wire_ecosystem_information(cluster)
        wire_tls_certificate_management(cluster)
        wire_tls_client_management(cluster)
        wire_push_av_stream_transport(cluster)
        validate_thread_network_directory(cluster)
        endpoint.add_cluster(cluster)
      end
      @node.add_endpoint(endpoint)
      basic_info.increase_configuration_version if @started

      # Tell controllers a new endpoint exists - they read its attributes on
      # their own (same pattern as remove_endpoint).
      descriptor = root_descriptor
      return true if descriptor.has_part?(endpoint_id)

      descriptor.add_part(endpoint_id)
      notify_root_parts_list if notify_subscribers
      true
    end

    private def wire_ecosystem_information(cluster : Cluster::Base) : Nil
      if ecosystem_information = cluster.as?(Cluster::EcosystemInformation)
        ecosystem_information.fabric_installed = ->(index : UInt8) { !@fabric_table.get_fabric(index).nil? }
      end
    end

    private def wire_tls_certificate_management(cluster : Cluster::Base) : Nil
      if tls = cluster.as?(Cluster::TlsCertificateManagement)
        tls.fabric_installed = ->(index : UInt8) { !@fabric_table.get_fabric(index).nil? }
        tls.managed_root_in_use = ->(fabric : UInt8, caid : UInt16) do
          @node.get_cluster(Cluster::TlsClientManagement).try(&.root_in_use?(fabric, caid)) || false
        end
        tls.managed_client_in_use = ->(fabric : UInt8, ccdid : UInt16) do
          @node.get_cluster(Cluster::TlsClientManagement).try(&.client_in_use?(fabric, ccdid)) || false
        end
        tls.on_persist = -> do
          raise StorageError.new("Could not persist TLS certificates") unless @persistence.save_cluster(tls)
          nil
        end
      end
    end

    private def wire_tls_client_management(cluster : Cluster::Base) : Nil
      if tls = cluster.as?(Cluster::TlsClientManagement)
        tls.certificate_management = @node.get_cluster(Cluster::TlsCertificateManagement)
        raise ConfigurationError.new("TLS Client Management requires TLS Certificate Management") unless tls.certificate_management
        tls.fabric_installed = ->(index : UInt8) { !@fabric_table.get_fabric(index).nil? }
        tls.on_persist = -> do
          raise StorageError.new("Could not persist TLS endpoints") unless @persistence.save_cluster(tls)
          nil
        end
      end
    end

    private def wire_push_av_stream_transport(cluster : Cluster::Base) : Nil
      if push = cluster.as?(Cluster::PushAvStreamTransport)
        tls = @node.get_cluster(Cluster::TlsClientManagement)
        raise ConfigurationError.new("Push AV Stream Transport requires TLS Client Management") unless tls
        push.fabric_installed = ->(index : UInt8) { !@fabric_table.get_fabric(index).nil? }
        push.tls_endpoint_exists = ->(fabric : UInt8, id : UInt16) { tls.has_endpoint?(fabric, id) }
        push.on_reference_change = ->(fabric : UInt8, id : UInt16, delta : Int8) { tls.change_reference_count(fabric, id, delta) }
        push.on_persist = -> do
          raise StorageError.new("Could not persist Push AV transport") unless @persistence.save_cluster(push)
          nil
        end
      end
    end

    private def validate_thread_network_directory(cluster : Cluster::Base) : Nil
      if directory = cluster.as?(Cluster::ThreadNetworkDirectory)
        directory.validate_supported_fabrics!(@fabric_table.max_fabrics)
      end
    end

    # Removes an endpoint, its clusters and their persisted state at runtime.
    # This is primarily used by bridge devices to remove bridged endpoints dynamically.
    #
    # Returns true if the endpoint was removed, false if it didn't exist.
    def remove_endpoint(endpoint_id : UInt16, notify_subscribers : Bool = true) : Bool
      # Don't allow removing endpoint 0 (root node)
      return false if endpoint_id == Node::ROOT_ENDPOINT_ID

      endpoint = @node.remove_endpoint(endpoint_id)
      return false unless endpoint
      basic_info.increase_configuration_version if @started

      endpoint.clusters.each_value { |cluster| @persistence.forget_cluster(cluster) }
      save_dynamic_endpoints if @dynamic_endpoints.delete(endpoint_id)

      descriptor = root_descriptor
      return true unless descriptor.has_part?(endpoint_id)

      descriptor.parts_list.reject! { |part| part == endpoint_id }
      notify_root_parts_list if notify_subscribers
      true
    end

    # Call after the application detects a configuration change on one
    # bridged device. The bridge version changes alongside the bridged one.
    def increase_bridged_configuration_version(endpoint_id : UInt16) : Nil
      increase_bridged_configuration_version([endpoint_id])
    end

    # Coalesce one logical change spanning several bridged devices into a
    # single increment of the bridge root version. Validate all endpoints
    # before changing any version, since ConfigurationVersion is optional on
    # a bridged device.
    def increase_bridged_configuration_version(endpoint_ids : Array(UInt16)) : Nil
      unique_ids = endpoint_ids.uniq
      return if unique_ids.empty?

      bridged_clusters = unique_ids.map do |endpoint_id|
        cluster = @node.get_cluster(endpoint_id, Cluster::BridgedDeviceBasicInformation)
        raise ConfigurationError.new("Endpoint #{endpoint_id} has no BridgedDeviceBasicInformation") unless cluster
        raise ConfigurationError.new("Endpoint #{endpoint_id} has no ConfigurationVersion") unless cluster.configuration_version
        cluster
      end

      bridged_clusters.each(&.increase_configuration_version)
      basic_info.increase_configuration_version
    end

    # Returns all endpoint IDs currently registered (excluding endpoint 0)
    def endpoint_ids : Array(UInt16)
      @node.endpoint_ids.reject { |endpoint_id| endpoint_id == Node::ROOT_ENDPOINT_ID }
    end

    # Returns the next available endpoint ID for dynamic endpoints
    # Starts from 1 and finds the first unused ID
    def next_endpoint_id : UInt16
      @node.next_endpoint_id
    end

    # The clusters and device type ids of the `endpoint_template` named
    # *template*; generated by the DSL from the template's declarations.
    protected def template_endpoint(
      template : String,
      endpoint_id : UInt16,
      parameters : Storage::Document,
    ) : Tuple(Array(Cluster::Base), Array(UInt32))
      raise ArgumentError.new("#{self.class} declares no endpoint template #{template.inspect}")
    end

    # The value of the template parameter *key*, which must be a *type*.
    protected def template_parameter(parameters : Storage::Document, key : String, type : T.class) : T forall T
      value = parameters[key]?
      unless value.is_a?(T)
        raise ArgumentError.new("endpoint template parameter #{key.inspect} must be a #{T}, got #{value.class}")
      end
      value
    end

    # Rebuilds the endpoints added from a template in an earlier run. They are
    # added without notifying subscribers: a controller that knew them before
    # the restart still does.
    private def restore_dynamic_endpoints : Nil
      document = @persistence.app_document(DYNAMIC_ENDPOINTS_ID)
      return unless document

      entries = document[ENDPOINTS_KEY]?
      return unless entries.is_a?(Array(Storage::Type))

      @restoring_endpoints = true
      entries.each { |entry| restore_dynamic_endpoint(entry) }
    ensure
      @restoring_endpoints = false
    end

    private def restore_dynamic_endpoint(entry : Storage::Type) : Nil
      return unless entry.is_a?(Hash(String, Storage::Type))

      number = entry[ENDPOINT_ID_KEY]?
      template = entry[TEMPLATE_KEY]?
      parameters = entry[PARAMETERS_KEY]?
      return unless number.is_a?(Int64) && template.is_a?(String) && parameters.is_a?(Hash(String, Storage::Type))

      endpoint = add_endpoint(
        template,
        parameters,
        endpoint_id: number.to_u16,
        notify_subscribers: false
      )
      @persistence.restore_clusters(endpoint.clusters.values)
    rescue error
      Log.error(exception: error) { "failed to restore a dynamic endpoint" }
    end

    private def save_dynamic_endpoints : Nil
      return if @restoring_endpoints

      entries = @dynamic_endpoints.map do |number, (template, parameters)|
        Storage::Document{
          ENDPOINT_ID_KEY => number.to_i64,
          TEMPLATE_KEY    => template,
          PARAMETERS_KEY  => parameters,
        }.as(Storage::Type)
      end

      @persistence.write_app_document(DYNAMIC_ENDPOINTS_ID, Storage::Document{ENDPOINTS_KEY => entries})
    end

    # Template parameters are persisted, so they are storage values: the
    # narrow number types are widened on the way in.
    private def storage_value(key : Symbol, value) : Storage::Type
      case value
      when Int           then value.to_i64
      when Float         then value.to_f64
      when Storage::Type then value
      else                    raise ArgumentError.new("endpoint parameter #{key} cannot be stored (#{value.class})")
      end
    end

    # The definition for *device_type*, at *revision* when the caller pinned one.
    private def dynamic_device_type(device_type : UInt32, revision : UInt16?) : DeviceType
      definition = DeviceType.for(device_type)
      return definition unless revision

      DeviceType.new(
        definition.device_type_id,
        definition.name,
        revision,
        definition.required_server_clusters,
        definition.optional_server_clusters,
        definition.required_server_attributes,
        definition.required_node_device_types
      )
    end
  end
end
