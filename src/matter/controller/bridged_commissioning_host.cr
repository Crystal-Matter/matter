require "log"

require "../cluster/bridged_administrator_commissioning"
require "../cluster/operational_credentials"
require "./im_client"
require "./pairing/case_pairing"
require "./state_store"

module Matter
  module Controller
    # Forwards a bridged Administrator Commissioning command to a real Matter
    # node. The controller identity and target binding are durable; every call
    # establishes CASE and checks the target's unfiltered Fabrics list before
    # changing its commissioning window.
    class BridgedCommissioningHost
      Log = ::Log.for("matter.controller.bridged_commissioning_host")

      COLLECTION = "bridged_commissioning"
      BINDING_ID = "target"

      struct Binding
        include Storage::Record

        getter fabric_id : UInt64
        getter root_public_key : Bytes
        getter controller_node_id : UInt64
        getter target_node_id : UInt64
        getter target_fabric_index : UInt8
        getter address : String
        getter port : Int32

        def initialize(@fabric_id, @root_public_key, @controller_node_id,
                       @target_node_id, @target_fabric_index, @address, @port)
        end
      end

      alias Consent = Proc(UInt8, UInt64, Symbol, Bool)

      def initialize(@store : StateStore, @cluster : Cluster::BridgedAdministratorCommissioning,
                     @consent : Consent, @timeout : Time::Span = 10.seconds)
      end

      # Provisioning is an explicit host decision. Verify the live target
      # before persisting the binding, so a stale address cannot be trusted on
      # restart merely because it was present in a configuration file.
      def bind!(binding : Binding) : Nil
        unless binding.target_fabric_index == @cluster.target_fabric_index &&
               binding.target_node_id == @cluster.target_node_id
          raise Matter::ConfigurationError.new("Binding does not match bridged endpoint identity")
        end
        with_target(binding) { |_im, _session, _peer| nil }
        backend = @store.backend
        backend.transaction { backend.write(COLLECTION, BINDING_ID, binding.to_document) }
      end

      def bound? : Bool
        backend = @store.backend
        backend.open unless backend.open?
        !backend.read(COLLECTION, BINDING_ID).nil?
      end

      def open(target_fabric_index : UInt8, target_node_id : UInt64, caller_fabric_index : UInt8,
               request : Cluster::AdministratorCommissioning::OpenCommissioningWindowRequest) : InteractionModel::Status
        forward(target_fabric_index, target_node_id, caller_fabric_index, :open) do |im, session, peer|
          status = invoke_status!(im, session, peer, Cluster::AdministratorCommissioning::CMD_OPEN_COMMISSIONING_WINDOW,
            request.to_slice)
          next status unless status.success?
          observe_window!(im, session, peer, Cluster::AdministratorCommissioning::CommissioningWindowStatus::EnhancedWindowOpen)
          status
        end
      end

      def revoke(target_fabric_index : UInt8, target_node_id : UInt64, caller_fabric_index : UInt8) : InteractionModel::Status
        forward(target_fabric_index, target_node_id, caller_fabric_index, :revoke) do |im, session, peer|
          status = invoke_status!(im, session, peer, Cluster::AdministratorCommissioning::CMD_REVOKE_COMMISSIONING)
          next status unless status.success?
          observe_window!(im, session, peer, Cluster::AdministratorCommissioning::CommissioningWindowStatus::WindowNotOpen)
          status
        end
      end

      def refresh : Nil
        with_target(binding!) do |im, session, peer|
          observe_window!(im, session, peer)
        end
      end

      private def forward(target_fabric_index : UInt8, target_node_id : UInt64,
                          caller_fabric_index : UInt8, operation : Symbol, & : ImClient, Session::SecureContext, Socket::IPAddress -> InteractionModel::Status) : InteractionModel::Status
        binding = binding!
        unless binding.target_fabric_index == target_fabric_index && binding.target_node_id == target_node_id &&
               @consent.call(caller_fabric_index, target_node_id, operation)
          return InteractionModel::Status.unsupported_access
        end
        result = InteractionModel::Status.failure
        with_target(binding) { |im, session, peer| result = yield im, session, peer }
        result
      rescue ex
        Log.error(exception: ex) { "Bridged commissioning #{operation} failed for target #{target_node_id}" }
        InteractionModel::Status.failure
      end

      private def binding! : Binding
        backend = @store.backend
        backend.open unless backend.open?
        document = backend.read(COLLECTION, BINDING_ID) ||
                   raise Matter::ConfigurationError.new("No bridged target is bound")
        Binding.from_document(document)
      end

      private def with_target(binding : Binding, & : ImClient, Session::SecureContext, Socket::IPAddress ->) : Nil
        fabric = @store.load.fabric_for(binding.fabric_id, binding.root_public_key, binding.controller_node_id)
        peer = Socket::IPAddress.new(binding.address, binding.port)
        client = Client.new
        begin
          session = Pairing::CasePairing.new.pair(client, peer, fabric,
            peer_node_id: binding.target_node_id, timeout: @timeout)
          im = ImClient.new(client, @timeout)
          report = im.read_attribute(session, peer, Node::ROOT_ENDPOINT_ID,
            Cluster::OperationalCredentials::CLUSTER_ID, Cluster::OperationalCredentials::ATTR_FABRICS,
            fabric_filtered: false)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                 raise Matter::AuthenticationError.new("Target Fabrics read returned no data")
          descriptors = Array(Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(data.to_slice)
          unless descriptors.any? { |item| item.fabric_index == binding.target_fabric_index &&
                 item.fabric_id == binding.fabric_id &&
                 item.root_public_key == binding.root_public_key &&
                 item.node_id == binding.target_node_id }
            raise Matter::AuthenticationError.new("Bridged target fabric identity changed")
          end
          yield im, session, peer
          nil
        ensure
          client.close
        end
      end

      private def invoke_status!(im : ImClient, session : Session::SecureContext, peer : Socket::IPAddress,
                                 command_id : UInt32, fields : Bytes = Bytes.empty) : InteractionModel::Status
        response = im.invoke(session, peer, Node::ROOT_ENDPOINT_ID,
          Cluster::AdministratorCommissioning::CLUSTER_ID, command_id, fields,
          timed_request: true)
        status = ImClient.single_invoke_response!(response, "Bridged commissioning").command_status.try(&.status)
        raise Matter::ProtocolError.new("Remote Administrator Commissioning omitted status") unless status
        return InteractionModel::Status.success if status.status == InteractionModel::StatusCode::Success.value
        return InteractionModel::Status.busy if status.status == InteractionModel::StatusCode::Busy.value
        return InteractionModel::Status.cluster_failure(code) if code = status.cluster_status
        InteractionModel::Status.failure
      end

      private def observe_window!(im : ImClient, session : Session::SecureContext, peer : Socket::IPAddress,
                                  expected : Cluster::AdministratorCommissioning::CommissioningWindowStatus? = nil) : Nil
        status = Cluster::AdministratorCommissioning::CommissioningWindowStatus.from_value(read_value(im, session, peer,
          Cluster::AdministratorCommissioning::ATTR_WINDOW_STATUS).as_u8)
        if expected && status != expected
          raise Matter::ProtocolError.new("Remote commissioning window did not reach expected state")
        end
        fabric = read_value(im, session, peer, Cluster::AdministratorCommissioning::ATTR_ADMIN_FABRIC_INDEX)
        vendor = read_value(im, session, peer, Cluster::AdministratorCommissioning::ATTR_ADMIN_VENDOR_ID)
        @cluster.publish_remote_window_state(status,
          fabric.header.element_type.null? ? nil : fabric.as_u8,
          vendor.header.element_type.null? ? nil : vendor.as_u16)
      end

      private def read_value(im : ImClient, session : Session::SecureContext, peer : Socket::IPAddress,
                             attribute_id : UInt32) : TLV::Any
        report = im.read_attribute(session, peer, Node::ROOT_ENDPOINT_ID,
          Cluster::AdministratorCommissioning::CLUSTER_ID, attribute_id)
        report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
          raise Matter::ProtocolError.new("Remote commissioning state read omitted data")
      end
    end
  end
end
