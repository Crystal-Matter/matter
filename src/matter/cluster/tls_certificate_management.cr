require "./cluster"
require "./tls_certificate_management/types"
require "../crypto/key"
require "../crypto/crypto"
require "../crypto/pkcs10"
require "openssl_ext"
require "log"

module Matter
  module Cluster
    # Matter 1.6 TLS Certificate Management, revision 1. This cluster is
    # opt-in; it stores per-fabric DER certificates and the private keys for
    # device-generated client CSRs. The host's Storage::Backend is the key
    # custody boundary, so applications must protect file-backed stores.
    class TlsCertificateManagement < Base
      Log = ::Log.for("matter.cluster.tls_certificate_management")

      cluster 0x0801, revision: 1, persist_state: false

      MIN_ROOT_CERTIFICATES       =      5_u8
      MIN_CLIENT_CERTIFICATES     =      2_u8
      DEFAULT_CLIENT_CERTIFICATES =      5_u8
      MAX_CERTIFICATES            =    254_u8
      MAX_CERTIFICATE_ID          = 65534_u16
      MAX_CERTIFICATE_BYTES       =      3000
      MAX_INTERMEDIATES           =        10
      MAX_FINGERPRINT_BYTES       =        64
      NONCE_BYTES                 =        32
      MAX_CSR_BYTES               =      3000
      MAX_SIGNATURE_BYTES         =       128

      class RootRecord
        include Storage::Record
        property caid : UInt16
        property certificate : Bytes
        property fabric_index : UInt8

        def initialize(@caid : UInt16, @certificate : Bytes, @fabric_index : UInt8); end
      end

      class ClientRecord
        include Storage::Record
        property ccdid : UInt16
        property certificate : Bytes?
        property intermediate_certificates : Array(Bytes)
        property private_key : Bytes
        property public_key : Bytes
        property fabric_index : UInt8

        def initialize(@ccdid : UInt16, @certificate : Bytes?, @intermediate_certificates : Array(Bytes),
                       @private_key : Bytes, @public_key : Bytes, @fabric_index : UInt8); end
      end

      struct PersistedState
        include Storage::Record
        getter data_version : UInt32
        getter roots : Array(RootRecord)
        getter clients : Array(ClientRecord)
        getter next_caid : Hash(UInt8, UInt16)
        getter next_ccdid : Hash(UInt8, UInt16)

        def initialize(@data_version, @roots, @clients, @next_caid, @next_ccdid); end
      end

      attribute 0x0000, :max_root_certificates, UInt8, computed: true, fixed: true
      attribute 0x0001, :provisioned_root_certificates, Array(Tlv::Cert), computed: true, fabric_scoped: true
      attribute 0x0002, :max_client_certificates, UInt8, computed: true, fixed: true
      attribute 0x0003, :provisioned_client_certificates, Array(Tlv::ClientCertificateDetail), computed: true, fabric_scoped: true

      command 0x00, :provision_root_certificate, request: Tlv::ProvisionRootCertificateRequest, response_id: 0x01, access: :administer
      command 0x02, :find_root_certificate, request: Tlv::FindRootCertificateRequest, response_id: 0x03, access: :operate
      command 0x04, :lookup_root_certificate, request: Tlv::LookupRootCertificateRequest, response_id: 0x05, access: :operate
      command 0x06, :remove_root_certificate, request: Tlv::RemoveRootCertificateRequest, access: :administer
      command 0x07, :client_csr, request: Tlv::ClientCsrRequest, response_id: 0x08, access: :administer
      command 0x09, :provision_client_certificate, request: Tlv::ProvisionClientCertificateRequest, access: :administer
      command 0x0A, :find_client_certificate, request: Tlv::FindClientCertificateRequest, response_id: 0x0B, access: :operate
      command 0x0C, :lookup_client_certificate, request: Tlv::LookupClientCertificateRequest, response_id: 0x0D, access: :operate
      command 0x0E, :remove_client_certificate, request: Tlv::RemoveClientCertificateRequest, access: :administer

      @roots = [] of RootRecord
      @clients = [] of ClientRecord
      @next_caid = {} of UInt8 => UInt16
      @next_ccdid = {} of UInt8 => UInt16

      # Device installs these before restoring state. The persistence callback
      # writes synchronously because an acknowledged CSR must survive restart.
      property fabric_installed : Proc(UInt8, Bool)?
      property on_persist : Proc(Nil)?
      property root_in_use : Proc(UInt8, UInt16, Bool)?
      property client_in_use : Proc(UInt8, UInt16, Bool)?

      getter max_root_certificates : UInt8
      getter max_client_certificates : UInt8

      def initialize(endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
                     @max_root_certificates : UInt8 = MIN_ROOT_CERTIFICATES,
                     @max_client_certificates : UInt8 = DEFAULT_CLIENT_CERTIFICATES)
        unless @max_root_certificates.in?(MIN_ROOT_CERTIFICATES..MAX_CERTIFICATES) &&
               @max_client_certificates.in?(MIN_CLIENT_CERTIFICATES..MAX_CERTIFICATES)
          raise ConfigurationError.new("TLS certificate capacities must be root 5..254 and client 2..254")
        end
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def provisioned_root_certificates(fabric_index : UInt8?) : Array(Tlv::Cert) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        visible(@roots, fabric_index).map { |entry| Tlv::Cert.new(entry.caid, entry.certificate.dup, entry.fabric_index) }
      end

      def provisioned_client_certificates(fabric_index : UInt8?) : Array(Tlv::ClientCertificateDetail) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        visible(@clients, fabric_index).map do |entry|
          Tlv::ClientCertificateDetail.new(entry.ccdid, entry.certificate.try(&.dup),
            entry.intermediate_certificates.map(&.dup), entry.fabric_index)
        end
      end

      def provision_root_certificate(request : Tlv::ProvisionRootCertificateRequest) : Tlv::ProvisionRootCertificateResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.certificate.empty? || request.certificate.size > MAX_CERTIFICATE_BYTES
        return InteractionModel::Status.dynamic_constraint_error unless valid_current_certificate?(request.certificate)
        return InteractionModel::Status.already_exists if @roots.any? { |entry| entry.fabric_index == fabric && entry.certificate == request.certificate }

        id = request.caid
        if id
          return InteractionModel::Status.constraint_error if id > MAX_CERTIFICATE_ID
          entry = root(fabric, id)
          return InteractionModel::Status.not_found unless entry
          entry.certificate = request.certificate.dup
        else
          return InteractionModel::Status.resource_exhausted if roots_for(fabric).size >= @max_root_certificates
          id = next_id(@next_caid, fabric) { |candidate| root(fabric, candidate).nil? }
          return InteractionModel::Status.resource_exhausted unless id
          @roots << RootRecord.new(id, request.certificate.dup, fabric)
        end
        changed(ATTR_PROVISIONED_ROOT_CERTIFICATES)
        Tlv::ProvisionRootCertificateResponse.new(id)
      end

      def find_root_certificate(request : Tlv::FindRootCertificateRequest) : Tlv::FindRootCertificateResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if (id = request.caid) && id > MAX_CERTIFICATE_ID
        entries = id ? roots_for(fabric).select(&.caid.==(id)) : roots_for(fabric)
        return InteractionModel::Status.not_found if entries.empty?
        Tlv::FindRootCertificateResponse.new(entries.map { |entry| Tlv::Cert.new(entry.caid, entry.certificate.dup, fabric) })
      end

      def lookup_root_certificate(request : Tlv::LookupRootCertificateRequest) : Tlv::LookupRootCertificateResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.fingerprint.size > MAX_FINGERPRINT_BYTES
        entry = roots_for(fabric).find { |candidate| fingerprint(candidate.certificate) == request.fingerprint }
        return InteractionModel::Status.not_found unless entry
        Tlv::LookupRootCertificateResponse.new(entry.caid)
      end

      def remove_root_certificate(request : Tlv::RemoveRootCertificateRequest) : InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.caid > MAX_CERTIFICATE_ID
        return InteractionModel::Status.invalid_in_state if @root_in_use.try(&.call(fabric, request.caid))
        before = @roots.size
        @roots.reject! { |entry| entry.fabric_index == fabric && entry.caid == request.caid }
        return InteractionModel::Status.not_found if @roots.size == before
        changed(ATTR_PROVISIONED_ROOT_CERTIFICATES)
        InteractionModel::Status.success
      end

      def client_csr(request : Tlv::ClientCsrRequest) : Tlv::ClientCsrResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error unless request.nonce.size == NONCE_BYTES
        id = request.ccdid
        if id
          return InteractionModel::Status.constraint_error if id > MAX_CERTIFICATE_ID
          entry = client(fabric, id)
          return InteractionModel::Status.not_found unless entry
          key = key_for(entry)
        else
          return InteractionModel::Status.resource_exhausted if clients_for(fabric).size >= @max_client_certificates
          id = next_id(@next_ccdid, fabric) { |candidate| client(fabric, candidate).nil? }
          return InteractionModel::Status.resource_exhausted unless id
          key = Crypto::Key.generate_key_pair
        end
        csr = Crypto::Pkcs10.create(key)
        signature = Crypto.sign_ecdsa(key, request.nonce, "ieee-p1363")
        return InteractionModel::Status.failure if csr.size > MAX_CSR_BYTES || signature.size > MAX_SIGNATURE_BYTES
        unless request.ccdid
          @clients << ClientRecord.new(id, nil, [] of Bytes, key.private_key.dup, key.public_key.dup, fabric)
          changed(ATTR_PROVISIONED_CLIENT_CERTIFICATES)
        end
        Tlv::ClientCsrResponse.new(id, csr, signature)
      end

      def provision_client_certificate(request : Tlv::ProvisionClientCertificateRequest) : InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.ccdid > MAX_CERTIFICATE_ID ||
                                                            request.client_certificate.empty? || request.client_certificate.size > MAX_CERTIFICATE_BYTES ||
                                                            request.intermediate_certificates.size > MAX_INTERMEDIATES ||
                                                            request.intermediate_certificates.any? { |cert| cert.empty? || cert.size > MAX_CERTIFICATE_BYTES }
        entry = client(fabric, request.ccdid)
        return InteractionModel::Status.not_found unless entry
        return InteractionModel::Status.already_exists if clients_for(fabric).any? { |item| item.certificate == request.client_certificate }
        certificate = parse_der_certificate(request.client_certificate)
        return InteractionModel::Status.dynamic_constraint_error unless certificate && current_certificate?(certificate)
        public_key = certificate.public_key
        return InteractionModel::Status.constraint_error unless public_key.is_a?(OpenSSL::PKey::EC) && public_key.public_key_bytes == entry.public_key
        return InteractionModel::Status.dynamic_constraint_error unless request.intermediate_certificates.all? { |cert| valid_current_certificate?(cert) }
        entry.certificate = request.client_certificate.dup
        entry.intermediate_certificates = request.intermediate_certificates.map(&.dup)
        changed(ATTR_PROVISIONED_CLIENT_CERTIFICATES)
        InteractionModel::Status.success
      end

      def find_client_certificate(request : Tlv::FindClientCertificateRequest) : Tlv::FindClientCertificateResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if (id = request.ccdid) && id > MAX_CERTIFICATE_ID
        entries = id ? clients_for(fabric).select(&.ccdid.==(id)) : clients_for(fabric)
        return InteractionModel::Status.not_found if entries.empty?
        Tlv::FindClientCertificateResponse.new(entries.map do |entry|
          Tlv::ClientCertificateDetail.new(entry.ccdid, entry.certificate.try(&.dup), entry.intermediate_certificates.map(&.dup), fabric)
        end)
      end

      def lookup_client_certificate(request : Tlv::LookupClientCertificateRequest) : Tlv::LookupClientCertificateResponse | InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.fingerprint.size > MAX_FINGERPRINT_BYTES
        entry = clients_for(fabric).find { |item| item.certificate.try { |cert| fingerprint(cert) == request.fingerprint } || false }
        return InteractionModel::Status.not_found unless entry
        Tlv::LookupClientCertificateResponse.new(entry.ccdid)
      end

      def remove_client_certificate(request : Tlv::RemoveClientCertificateRequest) : InteractionModel::Status
        fabric = accessing_fabric
        return fabric if fabric.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error if request.ccdid > MAX_CERTIFICATE_ID
        return InteractionModel::Status.invalid_in_state if @client_in_use.try(&.call(fabric, request.ccdid))
        before = @clients.size
        @clients.reject! { |entry| entry.fabric_index == fabric && entry.ccdid == request.ccdid }
        return InteractionModel::Status.not_found if @clients.size == before
        changed(ATTR_PROVISIONED_CLIENT_CERTIFICATES)
        InteractionModel::Status.success
      end

      def has_root?(fabric : UInt8, caid : UInt16) : Bool
        !root(fabric, caid).nil?
      end

      def has_client?(fabric : UInt8, ccdid : UInt16) : Bool
        !client(fabric, ccdid).nil?
      end

      def remove_fabric(fabric : UInt8) : Nil
        root_count = @roots.size
        client_count = @clients.size
        @roots.reject!(&.fabric_index.==(fabric))
        @clients.reject!(&.fabric_index.==(fabric))
        had_root_counter = !@next_caid.delete(fabric).nil?
        had_client_counter = !@next_ccdid.delete(fabric).nil?
        roots_removed = root_count != @roots.size
        clients_removed = client_count != @clients.size
        return unless roots_removed || clients_removed || had_root_counter || had_client_counter
        increment_version_and_notify(ATTR_PROVISIONED_ROOT_CERTIFICATES) if roots_removed
        increment_version_and_notify(ATTR_PROVISIONED_CLIENT_CERTIFICATES) if clients_removed
        @on_persist.try(&.call)
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @roots, @clients, @next_caid, @next_ccdid).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        @roots = state.roots.select { |entry| installed?(entry.fabric_index) }
        @clients = state.clients.select { |entry| installed?(entry.fabric_index) }
        @next_caid = state.next_caid.select { |fabric, _| installed?(fabric) }
        @next_ccdid = state.next_ccdid.select { |fabric, _| installed?(fabric) }
        @data_version = state.data_version
      end

      private def installed?(fabric : UInt8) : Bool
        @fabric_installed.try(&.call(fabric)) != false
      end

      private def accessing_fabric : UInt8 | InteractionModel::Status
        fabric = request_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric && request_is_case_session?
        return InteractionModel::Status.unsupported_access unless installed?(fabric)
        fabric
      end

      private def visible(records : Array(T), fabric : UInt8) : Array(T) forall T
        request_fabric_filtered? ? records.select(&.fabric_index.==(fabric)) : records
      end

      private def roots_for(fabric : UInt8) : Array(RootRecord)
        @roots.select(&.fabric_index.==(fabric))
      end

      private def clients_for(fabric : UInt8) : Array(ClientRecord)
        @clients.select(&.fabric_index.==(fabric))
      end

      private def root(fabric : UInt8, id : UInt16) : RootRecord?
        @roots.find { |entry| entry.fabric_index == fabric && entry.caid == id }
      end

      private def client(fabric : UInt8, id : UInt16) : ClientRecord?
        @clients.find { |entry| entry.fabric_index == fabric && entry.ccdid == id }
      end

      private def next_id(counter : Hash(UInt8, UInt16), fabric : UInt8, & : UInt16 -> Bool) : UInt16?
        start = counter[fabric]? || 0_u16
        candidate = start
        loop do
          if yield candidate
            counter[fabric] = candidate == MAX_CERTIFICATE_ID ? 0_u16 : candidate + 1_u16
            return candidate
          end
          candidate = candidate == MAX_CERTIFICATE_ID ? 0_u16 : candidate + 1_u16
          return if candidate == start
        end
      end

      private def changed(attribute : UInt32) : Nil
        increment_version_and_notify(attribute)
        @on_persist.try(&.call)
      end

      private def fingerprint(certificate : Bytes) : Bytes
        Crypto::StandardCrypto.new.compute_sha256(certificate)
      end

      private def parse_der_certificate(bytes : Bytes) : OpenSSL::X509::Certificate?
        cert, remainder = OpenSSL::X509::Certificate.from_der?(bytes)
        return if cert.nil? || !remainder.empty?
        cert
      rescue ex
        Log.debug(exception: ex) { "TLS certificate DER parse failed" }
        nil
      end

      private def valid_current_certificate?(bytes : Bytes) : Bool
        certificate = parse_der_certificate(bytes)
        !!(certificate && current_certificate?(certificate))
      end

      private def current_certificate?(certificate : OpenSSL::X509::Certificate) : Bool
        now = Time.utc
        certificate.not_before <= now && now <= certificate.not_after
      end

      private def key_for(entry : ClientRecord) : Crypto::Key
        key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        key.public_bits = entry.public_key
        key.private_bits = entry.private_key
        key
      end
    end
  end
end
