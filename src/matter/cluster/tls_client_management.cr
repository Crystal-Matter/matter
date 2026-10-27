require "./cluster"
require "./tls_client_management/types"
require "./tls_certificate_management"
require "../storage/record"

module Matter
  module Cluster
    # Matter 1.6 TLS Client Management, revision 1. An endpoint is a per-fabric
    # TLS destination and its references to certificates in 0x0801. Creating
    # an endpoint never starts a network connection; the host owns that work.
    class TlsClientManagement < Base
      cluster 0x0802, revision: 1, persist_state: false

      MIN_PROVISIONED    =      5_u8
      MAX_PROVISIONED    =    254_u8
      MIN_ENDPOINT_ID    =     0_u16
      MAX_ENDPOINT_ID    = 65534_u16
      MIN_HOSTNAME_BYTES =         4
      MAX_HOSTNAME_BYTES =       253
      MAX_CERTIFICATE_ID = 65534_u16

      class EndpointRecord
        include Storage::Record

        property endpoint_id : UInt16
        property hostname : Bytes
        property port : UInt16
        property caid : UInt16
        property ccdid : UInt16?
        property reference_count : UInt8
        property fabric_index : UInt8

        def initialize(@endpoint_id : UInt16, @hostname : Bytes, @port : UInt16,
                       @caid : UInt16, @ccdid : UInt16?, @reference_count : UInt8,
                       @fabric_index : UInt8); end
      end

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter endpoints : Array(EndpointRecord)
        getter next_endpoint_id : Hash(UInt8, UInt16)

        def initialize(@data_version, @endpoints, @next_endpoint_id); end
      end

      attribute 0x0000, :max_provisioned, UInt8, computed: true, fixed: true
      attribute 0x0001, :provisioned_endpoints, Array(Tlv::Endpoint), computed: true, fabric_scoped: true

      command 0x00, :provision_endpoint, request: Tlv::ProvisionEndpointRequest, response_id: 0x01, access: :administer
      command 0x02, :find_endpoint, request: Tlv::FindEndpointRequest, response_id: 0x03, access: :operate
      command 0x04, :remove_endpoint, request: Tlv::RemoveEndpointRequest, access: :administer

      @endpoints = [] of EndpointRecord
      @next_endpoint_id = {} of UInt8 => UInt16

      property certificate_management : TlsCertificateManagement?
      property fabric_installed : Proc(UInt8, Bool)?
      property on_persist : Proc(Nil)?
      property time_valid : Proc(Bool)?

      getter max_provisioned : UInt8

      def initialize(endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber::ROOT,
                     @max_provisioned : UInt8 = MIN_PROVISIONED)
        raise ConfigurationError.new("TLS Client Management is node-scoped and requires endpoint 0") unless endpoint_id == DataType::EndpointNumber::ROOT
        unless @max_provisioned.in?(MIN_PROVISIONED..MAX_PROVISIONED)
          raise ConfigurationError.new("TLS endpoint capacity must be in 5..254")
        end
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def provisioned_endpoints(fabric_index : UInt8?) : Array(Tlv::Endpoint) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        endpoints_for(fabric_index).map { |entry| wire(entry) }
      end

      def provision_endpoint(request : Tlv::ProvisionEndpointRequest) : Tlv::ProvisionEndpointResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error unless valid_request?(request)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidTime) if @time_valid.try(&.call) == false
        certificates = @certificate_management
        return InteractionModel::Status.cluster_failure(StatusCode::RootCertificateNotFound) unless certificates && certificates.has_root?(fabric, request.caid)
        if ccdid = request.ccdid
          return InteractionModel::Status.cluster_failure(StatusCode::ClientCertificateNotFound) unless certificates.has_provisioned_client?(fabric, ccdid)
        end

        id = request.endpoint_id
        if @endpoints.any? { |entry| entry.fabric_index == fabric && entry.hostname == request.hostname && entry.port == request.port && entry.endpoint_id != id }
          return InteractionModel::Status.cluster_failure(StatusCode::EndpointAlreadyInstalled)
        end
        if id
          entry = endpoint(fabric, id)
          return InteractionModel::Status.not_found unless entry
          return InteractionModel::Status.invalid_in_state unless entry.reference_count.zero?
          entry.hostname = request.hostname.dup
          entry.port = request.port
          entry.caid = request.caid
          entry.ccdid = request.ccdid
        else
          return InteractionModel::Status.resource_exhausted if endpoints_for(fabric).size >= @max_provisioned
          id = next_id(fabric)
          return InteractionModel::Status.resource_exhausted unless id
          @endpoints << EndpointRecord.new(id, request.hostname.dup, request.port, request.caid, request.ccdid, 0_u8, fabric)
        end
        changed
        Tlv::ProvisionEndpointResponse.new(id)
      end

      def find_endpoint(request : Tlv::FindEndpointRequest) : Tlv::FindEndpointResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.endpoint_id > MAX_ENDPOINT_ID
        entry = endpoint(fabric, request.endpoint_id)
        return InteractionModel::Status.not_found unless entry
        Tlv::FindEndpointResponse.new(wire(entry))
      end

      def remove_endpoint(request : Tlv::RemoveEndpointRequest) : InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.endpoint_id > MAX_ENDPOINT_ID
        entry = endpoint(fabric, request.endpoint_id)
        return InteractionModel::Status.not_found unless entry
        return InteractionModel::Status.cluster_failure(StatusCode::EndpointInUse) unless entry.reference_count.zero?
        @endpoints.delete(entry)
        changed
        InteractionModel::Status.success
      end

      # Host-owned consumers pin an endpoint while it is used. This count is
      # exposed on wire but cannot be changed by a Matter command.
      def change_reference_count(fabric : UInt8, id : UInt16, delta : Int8) : Bool
        entry = endpoint(fabric, id)
        return false unless entry
        updated = entry.reference_count.to_i + delta.to_i
        return false unless updated.in?(0..UInt8::MAX)
        entry.reference_count = updated.to_u8
        changed
        true
      end

      def root_in_use?(fabric : UInt8, caid : UInt16) : Bool
        @endpoints.any? { |entry| entry.fabric_index == fabric && entry.caid == caid }
      end

      def has_endpoint?(fabric : UInt8, id : UInt16) : Bool
        !endpoint(fabric, id).nil?
      end

      def client_in_use?(fabric : UInt8, ccdid : UInt16) : Bool
        @endpoints.any? { |entry| entry.fabric_index == fabric && entry.ccdid == ccdid }
      end

      def remove_fabric(fabric : UInt8) : Nil
        old_count = @endpoints.size
        @endpoints.reject!(&.fabric_index.==(fabric))
        had_counter = !@next_endpoint_id.delete(fabric).nil?
        changed if old_count != @endpoints.size || had_counter
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @endpoints, @next_endpoint_id).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        @endpoints = state.endpoints.select { |entry| installed?(entry.fabric_index) }
        @next_endpoint_id = state.next_endpoint_id.select { |fabric, _| installed?(fabric) }
        @data_version = state.data_version
      end

      private def accessing_fabric : UInt8 | InteractionModel::Status
        fabric = request_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric && request_is_case_session?
        return InteractionModel::Status.unsupported_access unless installed?(fabric)
        fabric
      end

      private def installed?(fabric : UInt8) : Bool
        @fabric_installed.try(&.call(fabric)) != false
      end

      private def valid_request?(request : Tlv::ProvisionEndpointRequest) : Bool
        return false unless request.hostname.size.in?(MIN_HOSTNAME_BYTES..MAX_HOSTNAME_BYTES)
        return false if request.port.zero? || request.caid > MAX_CERTIFICATE_ID
        return false if request.ccdid.try { |id| id > MAX_CERTIFICATE_ID }
        return false if request.endpoint_id.try { |id| id > MAX_ENDPOINT_ID }
        true
      end

      private def endpoints_for(fabric : UInt8) : Array(EndpointRecord)
        @endpoints.select(&.fabric_index.==(fabric))
      end

      private def endpoint(fabric : UInt8, id : UInt16) : EndpointRecord?
        @endpoints.find { |entry| entry.fabric_index == fabric && entry.endpoint_id == id }
      end

      private def next_id(fabric : UInt8) : UInt16?
        start = @next_endpoint_id[fabric]? || MIN_ENDPOINT_ID
        candidate = start
        loop do
          unless endpoint(fabric, candidate)
            @next_endpoint_id[fabric] = candidate == MAX_ENDPOINT_ID ? MIN_ENDPOINT_ID : candidate + 1_u16
            return candidate
          end
          candidate = candidate == MAX_ENDPOINT_ID ? MIN_ENDPOINT_ID : candidate + 1_u16
          return if candidate == start
        end
      end

      private def wire(entry : EndpointRecord) : Tlv::Endpoint
        Tlv::Endpoint.new(entry.endpoint_id, entry.hostname.dup, entry.port,
          entry.caid, entry.ccdid, entry.reference_count)
      end

      private def changed : Nil
        increment_version_and_notify(ATTR_PROVISIONED_ENDPOINTS)
        @on_persist.try(&.call)
      end
    end
  end
end
