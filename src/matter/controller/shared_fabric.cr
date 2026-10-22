require "../crypto/certificate_builder"
require "../crypto/certificate_validation"
require "../crypto/crypto"
require "../crypto/key"
require "../cluster/access_control"
require "../cluster/joint_fabric_datastore"
require "./im_client"
require "./state_store"

module Matter
  module Controller
    # Provisions another controller identity under a fabric's existing root.
    # Each controller gets its own Node ID and operational key. The authority
    # retains the signing key; only the new identity is stored in `store`.
    module SharedFabric
      alias Datastore = Cluster::JointFabricDatastore

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

      # Issue a controller NOC under a locally held Joint Fabric ICAC. Its CAT
      # is the subject that Datastore group ACLs will grant access to.
      def self.delegate_joint(authority : FabricInfo, controller_node_id : UInt64,
                              group_cat : UInt16, group_cat_version : UInt16,
                              crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : FabricInfo
        unless controller_node_id.in?(DataType::NodeId::OPERATIONAL_MINIMUM..DataType::NodeId::OPERATIONAL_MAXIMUM) &&
               controller_node_id != authority.controller_node_id
          raise Matter::ConfigurationError.new("Delegated Joint Fabric controller needs a distinct operational Node ID")
        end
        if group_cat == 0_u16 || group_cat.in?(Datastore::ANCHOR_CAT, Datastore::ADMINISTRATOR_CAT) ||
           group_cat_version.in?(0_u16, UInt16::MAX)
          raise Matter::ConfigurationError.new("Invalid Joint Fabric group CAT or version")
        end
        icac = authority.intermediate_cert || raise Matter::ConfigurationError.new("Joint Fabric delegation requires an ICAC")
        Crypto::MatterCertificate::Validation.verify_chain(authority.controller_noc, icac,
          authority.root_public_key, authority.root_cert)
        icac_id = Crypto::MatterCertificate.from_slice(icac).subject.icac_id ||
                  raise Matter::CertificateError.new("Joint Fabric ICAC has no ICAC ID")
        issuer = authority.intermediate_authority_key
        tag = DataType::CaseAuthenticatedTag.create(group_cat, group_cat_version)
        controller_key = crypto.create_key_pair
        noc = Crypto::MatterCertificate::Builder.node(
          public_key: controller_key.public_key,
          fabric_id: authority.fabric_id,
          node_id: controller_node_id,
          issuer_key: issuer,
          issuer_rcac_id: root_certificate_id(authority),
          issuer_icac_id: icac_id,
          issuer_certificate: icac,
          serial: crypto.random_bytes(CERTIFICATE_SERIAL_BYTES),
          crypto: crypto,
          case_authenticated_tag: tag.value
        )
        Crypto::MatterCertificate::Validation.verify_chain(noc, icac,
          authority.root_public_key, authority.root_cert)
        FabricInfo.new(authority.fabric_id, controller_node_id, authority.ipk_value.dup,
          authority.root_cert.dup, authority.root_public_key.dup, noc, controller_key.private_key,
          admin_vendor_id: authority.admin_vendor_id, intermediate_cert: icac.dup)
      end

      # Route controller access through the Anchor Datastore as required by
      # Matter 1.6 §11.24.4.9. The Anchor propagates pending membership and ACL
      # entries to the target node. The controller NOC must already carry one
      # non-reserved group CAT; `delegate_joint` can issue it when the ICAC key
      # is locally held.
      def self.grant_joint_admin(im : ImClient, session : Session::SecureContext,
                                 peer : Socket::IPAddress, datastore_endpoint : UInt16,
                                 device_node_id : UInt64, device_endpoint : UInt16,
                                 group_id : UInt16, group_name : String,
                                 controller : FabricInfo) : Nil
        if group_id == 0_u16 || device_node_id == 0_u64 || group_name.empty?
          raise Matter::ConfigurationError.new("Invalid Joint Fabric group or target node")
        end
        unless session.case_session?
          raise Matter::AuthenticationError.new("Joint Fabric Datastore grant requires CASE")
        end
        icac = controller.intermediate_cert || raise Matter::ConfigurationError.new("Joint Fabric controller has no ICAC")
        Crypto::MatterCertificate::Validation.verify_chain(controller.controller_noc, icac,
          controller.root_public_key, controller.root_cert)
        noc = Crypto::MatterCertificate.from_slice(controller.controller_noc)
        unless noc.fabric_id == controller.fabric_id && noc.node_id == controller.controller_node_id
          raise Matter::CertificateError.new("Joint Fabric controller NOC does not match its identity")
        end
        root_report = im.read_attribute(session: session, peer: peer, endpoint_id: datastore_endpoint,
          cluster_id: Datastore::CLUSTER_ID, attribute_id: Datastore::ATTR_ANCHOR_ROOT_CA)
        root_data = root_report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        raise Matter::ProtocolError.new("Joint Fabric Datastore AnchorRootCA returned no data") unless root_data
        unless Bytes.from_tlv(root_data.to_slice) == controller.root_cert
          raise Matter::AuthenticationError.new("Joint Fabric Datastore root differs from controller fabric")
        end
        subjects = Crypto::MatterCertificate.subject_ids_from_tlv(controller.controller_noc)
        cats = subjects.select do |subject|
          next false unless (subject & ~DataType::NodeId::CAT_VALUE_MASK) == DataType::NodeId::CAT_PREFIX
          identity = DataType::NodeId.new(subject).extract_as_case_authenticated_tag.identity_value
          !identity.in?(Datastore::ANCHOR_CAT, Datastore::ADMINISTRATOR_CAT)
        end
        unless cats.size == 1 && subjects.includes?(controller.controller_node_id)
          raise Matter::CertificateError.new("Joint Fabric controller NOC needs exactly one non-reserved group CAT")
        end
        cat_subject = cats.first
        cat = DataType::NodeId.new(cat_subject).extract_as_case_authenticated_tag
        groups = read_datastore_list(Datastore::DatastoreGroupInformationEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_GROUP_LIST)
        if group = groups.find(&.group_id.==(group_id.to_u64))
          unless group.group_cat == cat.identity_value && group.group_cat_version == cat.version &&
                 group.group_permission == Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer &&
                 group.group_key_set_id.nil?
            raise Matter::CommissioningError.new("Joint Fabric group already has a different CAT or privilege")
          end
        else
          request = Datastore::AddGroupRequest.new(group_id, group_name, nil, cat.identity_value,
            cat.version, Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer)
          invoke_datastore!(im, session, peer, datastore_endpoint, Datastore::CMD_ADD_GROUP, request.to_slice)
        end

        memberships = read_datastore_list(Datastore::DatastoreEndpointGroupIDEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_ENDPOINT_GROUP_ID_LIST)
        membership = memberships.find do |entry|
          entry.node_id == device_node_id && entry.endpoint_id == device_endpoint &&
            entry.group_id == group_id && entry.status_entry.state != Datastore::DatastoreStateEnum::DeletePending
        end
        unless membership
          request = Datastore::AddGroupIDToEndpointForNodeRequest.new(device_node_id, device_endpoint, group_id)
          invoke_datastore!(im, session, peer, datastore_endpoint,
            Datastore::CMD_ADD_GROUP_ID_TO_ENDPOINT_FOR_NODE, request.to_slice)
        end

        entries = read_datastore_list(Datastore::DatastoreACLEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_NODE_ACL_LIST)
        existing_acl = entries.find do |entry|
          entry.node_id == device_node_id &&
            entry.acl_entry.auth_mode == Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE &&
            entry.acl_entry.privilege == Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer &&
            entry.acl_entry.subjects == [cat_subject] && entry.acl_entry.targets.nil? &&
            entry.status_entry.state != Datastore::DatastoreStateEnum::DeletePending
        end
        unless existing_acl
          acl = Datastore::DatastoreAccessControlEntryStruct.new(
            Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer,
            Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [cat_subject], nil)
          request = Datastore::AddACLToNodeRequest.new(device_node_id, acl)
          invoke_datastore!(im, session, peer, datastore_endpoint, Datastore::CMD_ADD_ACL_TO_NODE, request.to_slice)
        end
        if membership.try(&.status_entry.state.commit_failed?) || existing_acl.try(&.status_entry.state.commit_failed?)
          request = Datastore::RefreshNodeRequest.new(device_node_id)
          invoke_datastore!(im, session, peer, datastore_endpoint, Datastore::CMD_REFRESH_NODE, request.to_slice)
        end
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
                    entry.targets.nil? && (entry.subjects.try(&.includes?(controller_node_id)) || false)
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

      private def self.read_datastore_list(type : T.class, im : ImClient,
                                           session : Session::SecureContext, peer : Socket::IPAddress,
                                           endpoint : UInt16, attribute : UInt32) : Array(T) forall T
        report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Datastore::CLUSTER_ID, attribute_id: attribute)
        data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        raise Matter::ProtocolError.new("Joint Fabric Datastore attribute #{attribute} returned no data") unless data
        Array(T).from_tlv(data.to_slice)
      end

      private def self.invoke_datastore!(im : ImClient, session : Session::SecureContext,
                                         peer : Socket::IPAddress, endpoint : UInt16,
                                         command : UInt32, fields : Bytes) : Nil
        response = im.invoke(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Datastore::CLUSTER_ID, command_id: command, fields: fields)
        status = response.invoke_responses.compact_map(&.command_status).first?.try(&.status)
        unless status && status.status == InteractionModel::StatusCode::Success.value
          raise Matter::CommissioningError.new("Joint Fabric Datastore command #{command} failed (#{status.try(&.status)})")
        end
      end
    end
  end
end
