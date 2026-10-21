require "../crypto/certificate_builder"
require "../crypto/certificate_validation"
require "../crypto/crypto"
require "../crypto/key"
require "../cluster/access_control"
require "./im_client"
require "./state_store"

module Matter
  module Controller
    # Provisions another controller identity under a fabric's existing root.
    # Each controller gets its own Node ID and operational key. The authority
    # retains the signing key; only the new identity is stored in `store`.
    module SharedFabric
      CERTIFICATE_SERIAL_BYTES = 8
      KEY_PROOF_MESSAGE        = "Matter shared fabric controller key".to_slice

      def self.delegate(
        authority : FabricInfo,
        controller_node_id : UInt64,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : FabricInfo
        if controller_node_id == 0_u64 || controller_node_id == authority.controller_node_id
          raise Matter::ConfigurationError.new("Delegated controller requires a distinct non-zero Node ID")
        end
        if authority.intermediate_cert
          raise Matter::ConfigurationError.new("Local delegation requires a root-issued controller identity")
        end

        root_key = authority.certificate_authority_key
        unless root_key.public_key == authority.root_public_key &&
               Crypto::MatterCertificate.public_key_from_tlv(authority.root_cert) == authority.root_public_key
          raise Matter::ConfigurationError.new("Fabric root certificate and signing key do not match")
        end

        Crypto::MatterCertificate::Validation.verify_signature(authority.root_cert, authority.root_public_key)
        unless Crypto::MatterCertificate::Validation.certificate_authority?(authority.root_cert)
          raise Matter::ConfigurationError.new("Fabric root certificate is not a certificate authority")
        end
        root_id = root_certificate_id(authority)

        controller_key = crypto.create_key_pair
        noc = Crypto::MatterCertificate::Builder.node(
          public_key: controller_key.public_key,
          fabric_id: authority.fabric_id,
          node_id: controller_node_id,
          issuer_key: root_key,
          issuer_rcac_id: root_id,
          issuer_certificate: authority.root_cert,
          serial: crypto.random_bytes(CERTIFICATE_SERIAL_BYTES),
          crypto: crypto
        )

        FabricInfo.new(
          fabric_id: authority.fabric_id,
          controller_node_id: controller_node_id,
          ipk_value: authority.ipk_value.dup,
          root_cert: authority.root_cert.dup,
          root_public_key: authority.root_public_key.dup,
          controller_noc: noc,
          controller_private_key: controller_key.private_key,
          admin_vendor_id: authority.admin_vendor_id
        )
      end

      # A local signing callback for Commissioner when the controller identity
      # has no CA key. Keep the authority in a separate protected store.
      def self.issuer(
        authority : FabricInfo,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : Proc(UInt64, UInt64, Bytes, Bytes)
        if authority.intermediate_cert
          raise Matter::ConfigurationError.new("Local issuer requires a root-issued fabric")
        end
        root_key = authority.certificate_authority_key
        unless root_key.public_key == authority.root_public_key
          raise Matter::ConfigurationError.new("Fabric signing key does not match its root")
        end
        root_id = root_certificate_id(authority)

        ->(fabric_id : UInt64, node_id : UInt64, public_key : Bytes) do
          unless fabric_id == authority.fabric_id && node_id != 0_u64
            raise Matter::CertificateError.new("Certificate request does not match the shared fabric")
          end

          Crypto::MatterCertificate::Builder.node(
            public_key: public_key,
            fabric_id: fabric_id,
            node_id: node_id,
            issuer_key: root_key,
            issuer_rcac_id: root_id,
            issuer_certificate: authority.root_cert,
            serial: crypto.random_bytes(CERTIFICATE_SERIAL_BYTES),
            crypto: crypto
          )
        end
      end

      # Install an issued identity into a controller store. Each fabric keeps
      # its own operational identity and peer map. To commission more devices
      # with a delegated identity, provide a separate certificate issuer.
      def self.install(store : StateStore, fabric : FabricInfo) : Nil
        unless fabric.ipk_value.size == Fabric::IPK_SIZE && fabric.controller_node_id != 0_u64 &&
               Crypto::MatterCertificate.public_key_from_tlv(fabric.root_cert) == fabric.root_public_key
          raise Matter::ConfigurationError.new("Invalid shared fabric root or controller identity")
        end
        Crypto::MatterCertificate::Validation.verify_signature(fabric.root_cert, fabric.root_public_key)
        unless Crypto::MatterCertificate::Validation.certificate_authority?(fabric.root_cert)
          raise Matter::ConfigurationError.new("Shared fabric root is not a certificate authority")
        end
        Crypto::MatterCertificate::Validation.verify_chain(
          fabric.controller_noc, fabric.intermediate_cert, fabric.root_public_key, fabric.root_cert
        )
        noc = Crypto::MatterCertificate.from_slice(fabric.controller_noc)
        unless noc.fabric_id == fabric.fabric_id && noc.node_id == fabric.controller_node_id
          raise Matter::ConfigurationError.new("Controller NOC does not match the shared fabric")
        end
        key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        key.private_bits = fabric.controller_private_key
        key.public_bits = noc.ec_public_key
        crypto = Crypto::StandardCrypto.new
        crypto.verify_ecdsa(key, KEY_PROOF_MESSAGE, crypto.sign_ecdsa(key, KEY_PROOF_MESSAGE))

        state = store.load
        if state.fabric.nil? && !state.nodes.empty?
          raise Matter::ConfigurationError.new("Controller store contains peers without a fabric")
        end

        state.install_fabric(fabric)
        store.save(state)
      end

      # Grant another controller on this fabric administrator access to a
      # device. Call over an existing administrator CASE session. The ACL is
      # fabric-scoped, so the accessing fabric's entries alone are replaced.
      def self.grant_admin(
        im : ImClient,
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        controller_node_id : UInt64,
      ) : Nil
        if controller_node_id == 0_u64
          raise Matter::ConfigurationError.new("Administrator Node ID must be non-zero")
        end

        report = im.read_attribute(
          session: session,
          peer: peer,
          endpoint_id: 0_u16,
          cluster_id: Cluster::AccessControl::CLUSTER_ID,
          attribute_id: Cluster::AccessControl::ATTR_ACL
        )
        data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        unless data
          raise Matter::ProtocolError.new("Access Control ACL read returned no data")
        end

        entries = Array(Cluster::AccessControl::AccessControlEntry).from_tlv(data.to_slice)
        return if entries.any? do |entry|
                    entry.auth_mode == Cluster::AccessControl::AccessControlEntryAuthMode::CASE &&
                    entry.privilege == Cluster::AccessControl::AccessControlEntryPrivilege::Administer &&
                    entry.targets.nil? && entry.subjects.includes?(controller_node_id)
                  end

        entries << Cluster::AccessControl::AccessControlEntry.new(
          privilege: Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
          auth_mode: Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
          subjects: [controller_node_id],
          targets: nil
        )
        response = im.write_attribute(
          session: session,
          peer: peer,
          endpoint_id: 0_u16,
          cluster_id: Cluster::AccessControl::CLUSTER_ID,
          attribute_id: Cluster::AccessControl::ATTR_ACL,
          value: entries.to_tlv
        )
        unless response.write_responses.any? { |entry| entry.status.status == InteractionModel::StatusCode::Success.value }
          raise Matter::CommissioningError.new("Access Control ACL rejected the shared controller")
        end
      end

      private def self.root_certificate_id(authority : FabricInfo) : UInt64
        id = Crypto::MatterCertificate.from_slice(authority.root_cert).subject.rcac_id
        id || raise Matter::CertificateError.new("Fabric root certificate has no RCAC ID")
      end
    end
  end
end
