require "./im_subscription"
require "./scanner"
require "./pairing/case_pairing"
require "../cluster/joint_fabric_datastore"
require "../cluster/descriptor"

module Matter
  module Controller
    # Participant-side Matter 1.6 §12.2.6 step 5(a) subscription. A caller
    # supplies the already installed new Anchor fabric and a verifier that
    # checks the peer's Anchor CAT and jf-anchor-icac certificate after CASE.
    # The subscription uses its own Client so it cannot consume another IM
    # interaction's messages. A lost subscription is an error to reconcile;
    # callers must not resume commissioning on a stale Datastore view.
    class AnchorDatastoreSubscription
      alias Store = Cluster::JointFabricDatastore
      alias VerifyAnchor = Proc(ImClient, Session::SecureContext, Socket::IPAddress, Nil)

      getter peer : Socket::IPAddress
      getter subscription : AttributeSubscription
      getter resubscription_count : UInt32 = 0_u32
      getter last_status : Store::DatastoreStatusEntryStruct
      getter resolved_endpoint_id : UInt16 = 0_u16

      def initialize(@scanner : Scanner, @fabric : FabricInfo,
                     @anchor_node_id : UInt64, @endpoint_id : UInt16?,
                     @verify_anchor : VerifyAnchor,
                     @address_hint : Socket::IPAddress? = nil,
                     @discovery_timeout : Time::Span = 10.seconds,
                     @timeout : Time::Span = 10.seconds)
        raise Matter::ConfigurationError.new("New Anchor Node ID must be nonzero") if @anchor_node_id == 0_u64
        @peer = discover_peer(@address_hint, @discovery_timeout)
        @client = uninitialized Client
        @session = uninitialized Session::SecureContext
        @im = uninitialized ImClient
        @subscription = uninitialized AttributeSubscription
        @last_status = uninitialized Store::DatastoreStatusEntryStruct
        connect!
      end

      private def connect! : Nil
        @client = Client.new(unsecured_source_node_id: @fabric.controller_node_id)
        begin
          @session = Pairing::CasePairing.new.pair(@client, @peer, @fabric,
            peer_node_id: @anchor_node_id, timeout: @timeout)
          @im = ImClient.new(@client, @timeout)
          @verify_anchor.call(@im, @session, @peer)
          @resolved_endpoint_id = @endpoint_id || discover_datastore_endpoint
          paths = [Store::ATTR_STATUS, Store::ATTR_ANCHOR_ROOT_CA,
                   Store::ATTR_ANCHOR_NODE_ID].map do |attribute_id|
            InteractionModel::AttributePath.new(endpoint: @resolved_endpoint_id,
              cluster: Store::CLUSTER_ID, attribute: attribute_id)
          end
          @subscription = @im.subscribe_attributes(@session, @peer, paths)
          # A priming report is mandatory. Its state gates participant
          # follow-up and subsequent commissioning decisions.
          @last_status = self.class.status_from_reports(@subscription.initial_reports, @resolved_endpoint_id)
          self.class.verify_identity!(@subscription.initial_reports, @resolved_endpoint_id,
            @fabric.root_public_key, @anchor_node_id)
        rescue ex
          @client.close
          raise ex
        end
      end

      def initial_status : Store::DatastoreStatusEntryStruct
        @last_status
      end

      def next_status(timeout_span : Time::Span? = nil) : Store::DatastoreStatusEntryStruct
        reports = timeout_span ? @subscription.next_report(timeout_span) : @subscription.next_report
        self.class.verify_identity_updates!(reports, @resolved_endpoint_id,
          @fabric.root_public_key, @anchor_node_id)
        @last_status = self.class.updated_status(@last_status, reports, @resolved_endpoint_id)
      rescue Matter::TimeoutError | Matter::TransportError
        reconnect!
        initial_status
      end

      # Returns nil when a healthy subscription has no update in this poll.
      # A stream that exceeds its negotiated MaxInterval is reauthenticated
      # and resubscribed before its Datastore status is trusted again.
      def poll_status(timeout_span : Time::Span) : Store::DatastoreStatusEntryStruct?
        reports = @subscription.poll_report(timeout_span)
        if reports
          self.class.verify_identity_updates!(reports, @resolved_endpoint_id,
            @fabric.root_public_key, @anchor_node_id)
        end
        @last_status = self.class.updated_status(@last_status, reports, @resolved_endpoint_id)
        return unless reports
        @last_status
      rescue Matter::TimeoutError | Matter::TransportError
        reconnect!
        initial_status
      end

      def close : Nil
        @client.close
      end

      # Discover under the already authenticated CASE session. A joining JFA
      # can expose its old-fabric Datastore and promoted Anchor Datastore on
      # different endpoints; only one must be readable on the new fabric and
      # attest the CASE root and Anchor Node ID.
      private def discover_datastore_endpoint : UInt16
        endpoints = descriptor_list(UInt16, 0_u16, Cluster::Descriptor::ATTR_PARTS_LIST)
        candidates = endpoints.select do |endpoint_id|
          descriptor_list(UInt32, endpoint_id, Cluster::Descriptor::ATTR_SERVER_LIST)
            .includes?(Store::CLUSTER_ID)
        end
        matching = candidates.select do |endpoint_id|
          reports = [Store::ATTR_STATUS, Store::ATTR_ANCHOR_ROOT_CA,
                     Store::ATTR_ANCHOR_NODE_ID].map do |attribute_id|
            @im.read_attribute(session: @session, peer: @peer, endpoint_id: endpoint_id,
              cluster_id: Store::CLUSTER_ID, attribute_id: attribute_id)
          end
          next false unless reports.all? do |report|
                              report.attribute_reports.try(&.any?(&.attribute_data)) == true
                            end
          self.class.status_from_reports(reports, endpoint_id)
          self.class.verify_identity!(reports, endpoint_id,
            @fabric.root_public_key, @anchor_node_id)
          true
        end
        unless matching.size == 1
          raise Matter::AuthenticationError.new("Expected one authenticated new Anchor Datastore endpoint, found #{matching.size}")
        end
        matching.first
      end

      private def descriptor_list(type : T.class, endpoint_id : UInt16,
                                  attribute_id : UInt32) : Array(T) forall T
        report = @im.read_attribute(session: @session, peer: @peer,
          endpoint_id: endpoint_id, cluster_id: Cluster::Descriptor::CLUSTER_ID,
          attribute_id: attribute_id)
        data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        raise Matter::ProtocolError.new("New Anchor Descriptor omitted attribute #{attribute_id}") unless data
        Array(T).from_tlv(data.to_slice)
      end

      # A bounded reconnect always redoes discovery, CASE, Anchor identity
      # verification, and a fresh priming subscription. On failure, callers
      # receive an error and must keep commissioning suspended.
      def reconnect! : Nil
        @client.close
        last_error : Exception? = nil
        3.times do |attempt|
          sleep attempt.seconds if attempt > 0
          begin
            @peer = discover_peer(@address_hint, @discovery_timeout)
            connect!
            @resubscription_count &+= 1_u32
            return
          rescue ex : Matter::TimeoutError | Matter::TransportError
            last_error = ex
          end
        end
        raise(last_error || Matter::TimeoutError.new("New Anchor subscription reconnect failed"))
      end

      def self.status_from_reports(reports : Array(InteractionModel::ReportDataMessage),
                                   endpoint_id : UInt16) : Store::DatastoreStatusEntryStruct
        status_from_reports?(reports, endpoint_id) ||
          raise Matter::ProtocolError.new("Anchor Datastore subscription omitted unique Status attribute")
      end

      def self.status_from_reports?(reports : Array(InteractionModel::ReportDataMessage),
                                    endpoint_id : UInt16) : Store::DatastoreStatusEntryStruct?
        matching = reports.flat_map { |report| report.attribute_reports || [] of InteractionModel::AttributeReportIB }
          .compact_map(&.attribute_data).select do |entry|
          path = entry.path
          path.endpoint == endpoint_id && path.cluster == Store::CLUSTER_ID &&
            path.attribute == Store::ATTR_STATUS
        end
        return if matching.empty?
        raise Matter::ProtocolError.new("Anchor Datastore subscription duplicated Status attribute") unless matching.size == 1
        Store::DatastoreStatusEntryStruct.from_slice(matching.first.data.to_slice)
      end

      def self.updated_status(current : Store::DatastoreStatusEntryStruct,
                              reports : Array(InteractionModel::ReportDataMessage)?,
                              endpoint_id : UInt16) : Store::DatastoreStatusEntryStruct
        return current unless reports
        status_from_reports?(reports, endpoint_id) || current
      end

      private def discover_peer(address_hint : Socket::IPAddress?, timeout_span : Time::Span) : Socket::IPAddress
        @scanner.query_operational
        deadline = Time.instant + timeout_span
        loop do
          if device = @scanner.operational_devices.find do |entry|
               entry.fabric_id == @fabric.compressed_fabric_id && entry.node_id == @anchor_node_id
             end
            if address = device.addresses.find(&.family.inet?) || device.addresses.first?
              return Socket::IPAddress.new(address.address, device.port)
            end
          end
          break if Time.instant >= deadline
          sleep 100.milliseconds
        end
        # The hint is only a route. CASE and the required verifier establish
        # identity before any Datastore value is accepted.
        address_hint || raise Matter::TransportError.new("Could not discover new Anchor operational address")
      end

      def self.verify_identity!(reports : Array(InteractionModel::ReportDataMessage),
                                endpoint_id : UInt16, root_public_key : Bytes,
                                anchor_node_id : UInt64) : Nil
        root = attribute_bytes(reports, endpoint_id, Store::ATTR_ANCHOR_ROOT_CA)
        unless Crypto::MatterCertificate.public_key_from_tlv(Bytes.from_tlv(root)) == root_public_key
          raise Matter::AuthenticationError.new("New Anchor Datastore root differs from CASE fabric")
        end
        node_id = UInt64.from_tlv(attribute_bytes(reports, endpoint_id, Store::ATTR_ANCHOR_NODE_ID))
        unless node_id == anchor_node_id
          raise Matter::AuthenticationError.new("New Anchor Datastore Node ID differs from CASE peer")
        end
      end

      def self.verify_identity_updates!(reports : Array(InteractionModel::ReportDataMessage),
                                        endpoint_id : UInt16, root_public_key : Bytes,
                                        anchor_node_id : UInt64) : Nil
        if root = attribute_bytes?(reports, endpoint_id, Store::ATTR_ANCHOR_ROOT_CA)
          unless Crypto::MatterCertificate.public_key_from_tlv(Bytes.from_tlv(root)) == root_public_key
            raise Matter::AuthenticationError.new("New Anchor Datastore root changed")
          end
        end
        if node = attribute_bytes?(reports, endpoint_id, Store::ATTR_ANCHOR_NODE_ID)
          unless UInt64.from_tlv(node) == anchor_node_id
            raise Matter::AuthenticationError.new("New Anchor Datastore Node ID changed")
          end
        end
      end

      def self.attribute_bytes(reports : Array(InteractionModel::ReportDataMessage),
                               endpoint_id : UInt16, attribute_id : UInt32) : Bytes
        attribute_bytes?(reports, endpoint_id, attribute_id) ||
          raise Matter::ProtocolError.new("Anchor Datastore attribute #{attribute_id} omitted")
      end

      def self.attribute_bytes?(reports : Array(InteractionModel::ReportDataMessage),
                                endpoint_id : UInt16, attribute_id : UInt32) : Bytes?
        matching = reports.flat_map { |report| report.attribute_reports || [] of InteractionModel::AttributeReportIB }
          .compact_map(&.attribute_data).select do |entry|
          path = entry.path
          path.endpoint == endpoint_id && path.cluster == Store::CLUSTER_ID && path.attribute == attribute_id
        end
        return if matching.empty?
        raise Matter::ProtocolError.new("Anchor Datastore attribute #{attribute_id} duplicated") unless matching.size == 1
        matching.first.data.to_slice
      end
    end
  end
end
