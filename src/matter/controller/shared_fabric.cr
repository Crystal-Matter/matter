require "../node"
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

      # Persist this receipt until `joint_group_revocation_status` reports
      # Effective. UpdateGroup itself only queues target ACL delivery.
      struct JointGroupACLTarget
        include Storage::Record

        getter node_id : UInt64
        getter list_id : UInt16

        def initialize(@node_id, @list_id)
        end
      end

      struct JointGroupRevocation
        include Storage::Record

        enum Status
          Pending
          Effective
        end

        getter group_id : UInt16
        getter group_cat : UInt16
        getter previous_version : UInt16
        getter current_version : UInt16
        getter target_node_ids : Array(UInt64)
        getter target_acls : Array(JointGroupACLTarget)
        getter anchor_root_cert : Bytes
        getter anchor_node_id : UInt64

        def initialize(@group_id, @group_cat, @previous_version, @current_version,
                       @target_node_ids, @target_acls, @anchor_root_cert, @anchor_node_id)
        end
      end

      def self.delegate(
        authority : FabricInfo,
        controller_node_id : UInt64,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : FabricInfo
        if controller_node_id == DataType::NodeId::UNSPECIFIED || controller_node_id == authority.controller_node_id
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
          admin_vendor_id: authority.admin_vendor_id,
          ipk_epoch_keys: authority.ipk_epoch_keys
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
        if group_cat == Datastore::UNSPECIFIED_GROUP_CAT || group_cat.in?(Datastore::ANCHOR_CAT, Datastore::ADMINISTRATOR_CAT) ||
           group_cat_version.in?(Datastore::UNSPECIFIED_GROUP_CAT_VERSION, Datastore::RESERVED_GROUP_CAT_VERSION)
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
          admin_vendor_id: authority.admin_vendor_id, intermediate_cert: icac.dup,
          ipk_epoch_keys: authority.ipk_epoch_keys)
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
        if group_id == Datastore::RESERVED_GROUP_ID || device_node_id == DataType::NodeId::UNSPECIFIED || group_name.empty?
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

      # Stage removal of one controller from a shared Joint Fabric group.
      # Every survivor store must be supplied; its existing operational key is
      # kept while its NOC is reissued with the next group CAT version. The
      # Anchor then rotates target ACLs without deleting group membership.
      # This returns a pending receipt, never proof that devices deny the old
      # CAT. Save the receipt and poll `joint_group_revocation_status` after
      # the Anchor synchronizer has delivered the ACLs.
      def self.stage_joint_group_revocation(im : ImClient, session : Session::SecureContext,
                                            peer : Socket::IPAddress, datastore_endpoint : UInt16,
                                            group_id : UInt16, revoked : FabricInfo,
                                            survivors : Array({StateStore, UInt64}), authority : FabricInfo,
                                            anchor_node_id : UInt64,
                                            crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : JointGroupRevocation
        verify_joint_anchor!(im, session, peer, datastore_endpoint, anchor_node_id, authority.root_cert)
        icac = authority.intermediate_cert || raise Matter::ConfigurationError.new("Joint Fabric authority requires an ICAC")
        issuer = authority.intermediate_authority_key
        icac_id = Crypto::MatterCertificate.from_slice(icac).subject.icac_id ||
                  raise Matter::CertificateError.new("Joint Fabric ICAC has no ICAC ID")
        Crypto::MatterCertificate::Validation.verify_chain(authority.controller_noc, icac,
          authority.root_public_key, authority.root_cert)
        groups = read_datastore_list(Datastore::DatastoreGroupInformationEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_GROUP_LIST)
        group = groups.find(&.group_id.==(group_id.to_u64)) ||
                raise Matter::ConfigurationError.new("Joint Fabric group does not exist")
        cat = group.group_cat || raise Matter::ConfigurationError.new("Joint Fabric group has no CAT")
        version = group.group_cat_version || raise Matter::ConfigurationError.new("Joint Fabric group has no CAT version")
        unless group.group_permission == Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer &&
               group.group_key_set_id.nil? && version < Datastore::RESERVED_GROUP_CAT_VERSION
          raise Matter::ConfigurationError.new("Joint Fabric group cannot rotate its CAT version")
        end
        recovered = false
        previous_version = if version < Datastore::RESERVED_GROUP_CAT_VERSION - 1 &&
                              joint_controller_cat?(revoked, authority, cat, version)
                             version
                           elsif version > Datastore::FIRST_GROUP_CAT_VERSION &&
                                 joint_controller_cat?(revoked, authority, cat, version - 1_u16)
                             recovered = true
                             version - 1_u16
                           else
                             raise Matter::ConfigurationError.new("Revoked controller CAT does not match the current or preceding group version")
                           end
        next_version = previous_version + 1_u16
        target_acls = read_datastore_list(Datastore::DatastoreACLEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_NODE_ACL_LIST)
        new_subject = DataType::NodeId.from_case_authenticated_tag(
          DataType::CaseAuthenticatedTag.create(cat, next_version)).id
        selected_acls = target_acls.select do |entry|
          next false if entry.status_entry.state == Datastore::DatastoreStateEnum::DeletePending
          if recovered
            entry.acl_entry.auth_mode == Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE &&
              entry.acl_entry.privilege == Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer &&
              entry.acl_entry.subjects == [new_subject]
          else
            acl_grants_cat_version?(entry.acl_entry, cat, previous_version)
          end
        end
        raise Matter::ConfigurationError.new("Joint Fabric group has no target ACLs") if selected_acls.empty?
        target_ids = selected_acls.map(&.node_id).uniq!
        target_refs = selected_acls.map { |entry| JointGroupACLTarget.new(entry.node_id, entry.list_id) }

        seen = [revoked.controller_node_id]
        replacements = [] of {StateStore, FabricInfo}
        survivors.each do |store, controller_node_id|
          state = store.load
          fabric = state.fabric_for(authority.fabric_id, authority.root_public_key, controller_node_id)
          if seen.includes?(fabric.controller_node_id) ||
             !(joint_controller_cat?(fabric, authority, cat, previous_version) ||
             joint_controller_cat?(fabric, authority, cat, next_version)) ||
             (recovered && !joint_controller_cat?(fabric, authority, cat, next_version))
            raise Matter::ConfigurationError.new("Survivor identity is duplicated or lacks the current or next group CAT")
          end
          seen << fabric.controller_node_id
          # A prior attempt may have saved some NOCs before UpdateGroup failed.
          # Reuse those credentials so retrying the stage is safe.
          next if joint_controller_cat?(fabric, authority, cat, next_version)
          old_noc = Crypto::MatterCertificate.from_slice(fabric.controller_noc)
          key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
          key.private_bits = fabric.controller_private_key
          key.public_bits = old_noc.ec_public_key
          crypto.verify_ecdsa(key, KEY_PROOF_MESSAGE, crypto.sign_ecdsa(key, KEY_PROOF_MESSAGE))
          noc = Crypto::MatterCertificate::Builder.node(
            public_key: old_noc.ec_public_key, fabric_id: fabric.fabric_id,
            node_id: fabric.controller_node_id, issuer_key: issuer,
            issuer_rcac_id: root_certificate_id(authority), issuer_icac_id: icac_id,
            issuer_certificate: icac, serial: crypto.random_bytes(CERTIFICATE_SERIAL_BYTES),
            crypto: crypto, case_authenticated_tag: DataType::CaseAuthenticatedTag.create(cat, next_version).value)
          Crypto::MatterCertificate::Validation.verify_chain(noc, icac,
            authority.root_public_key, authority.root_cert)
          replacement = FabricInfo.new(fabric.fabric_id, fabric.controller_node_id, fabric.ipk_value.dup,
            fabric.root_cert.dup, fabric.root_public_key.dup, noc, fabric.controller_private_key.dup,
            fabric.root_private_key, fabric.admin_vendor_id, icac.dup,
            fabric.intermediate_private_key, fabric.ipk_epoch_keys)
          replacements << {store, replacement}
        end
        replacements.each do |store, replacement|
          state = store.load
          state.replace_fabric(replacement)
          store.save(state)
        end
        unless recovered
          request = Datastore::UpdateGroupRequest.new(group_id, nil, nil, nil, next_version, nil)
          invoke_datastore!(im, session, peer, datastore_endpoint, Datastore::CMD_UPDATE_GROUP, request.to_slice)
        end
        JointGroupRevocation.new(group_id, cat, previous_version, next_version, target_ids, target_refs,
          authority.root_cert.dup, anchor_node_id)
      end

      # A pending receipt becomes effective only after every target ACL is
      # committed at the new CAT version and no old CAT ACL remains.
      def self.joint_group_revocation_status(im : ImClient, session : Session::SecureContext,
                                             peer : Socket::IPAddress, datastore_endpoint : UInt16,
                                             receipt : JointGroupRevocation) : JointGroupRevocation::Status
        verify_joint_anchor!(im, session, peer, datastore_endpoint,
          receipt.anchor_node_id, receipt.anchor_root_cert)
        groups = read_datastore_list(Datastore::DatastoreGroupInformationEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_GROUP_LIST)
        group = groups.find(&.group_id.==(receipt.group_id.to_u64))
        return JointGroupRevocation::Status::Pending unless group &&
                                                            group.group_cat == receipt.group_cat &&
                                                            group.group_cat_version == receipt.current_version &&
                                                            group.group_permission == Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer &&
                                                            group.group_key_set_id.nil?
        entries = read_datastore_list(Datastore::DatastoreACLEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_NODE_ACL_LIST)
        new_subject = DataType::NodeId.from_case_authenticated_tag(
          DataType::CaseAuthenticatedTag.create(receipt.group_cat, receipt.current_version)).id
        previous_version_acl = entries.any? do |entry|
          acl_grants_cat_version?(entry.acl_entry, receipt.group_cat, receipt.previous_version)
        end
        return JointGroupRevocation::Status::Pending if previous_version_acl
        receipt.target_acls.each do |target|
          entry = entries.find { |candidate| candidate.node_id == target.node_id && candidate.list_id == target.list_id }
          return JointGroupRevocation::Status::Pending unless entry &&
                                                              entry.acl_entry.subjects == [new_subject] &&
                                                              entry.acl_entry.auth_mode == Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE &&
                                                              entry.acl_entry.privilege == Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer &&
                                                              entry.status_entry.state == Datastore::DatastoreStateEnum::Committed
        end
        JointGroupRevocation::Status::Effective
      end

      # Ask the Anchor to retry target ACLs that reported CommitFailed. The
      # receipt remains Pending until the subsequent delivery is committed.
      def self.retry_failed_joint_group_revocation(im : ImClient, session : Session::SecureContext,
                                                   peer : Socket::IPAddress, datastore_endpoint : UInt16,
                                                   receipt : JointGroupRevocation) : Nil
        verify_joint_anchor!(im, session, peer, datastore_endpoint,
          receipt.anchor_node_id, receipt.anchor_root_cert)
        entries = read_datastore_list(Datastore::DatastoreACLEntryStruct, im, session, peer,
          datastore_endpoint, Datastore::ATTR_NODE_ACL_LIST)
        new_subject = DataType::NodeId.from_case_authenticated_tag(
          DataType::CaseAuthenticatedTag.create(receipt.group_cat, receipt.current_version)).id
        receipt.target_node_ids.each do |node_id|
          next unless entries.any? do |entry|
                        entry.node_id == node_id && entry.acl_entry.subjects == [new_subject] &&
                        entry.status_entry.state == Datastore::DatastoreStateEnum::CommitFailed
                      end
          request = Datastore::RefreshNodeRequest.new(node_id)
          invoke_datastore!(im, session, peer, datastore_endpoint, Datastore::CMD_REFRESH_NODE, request.to_slice)
        end
      end

      private def self.joint_controller_cat?(fabric : FabricInfo, authority : FabricInfo,
                                             cat : UInt16, version : UInt16) : Bool
        return false unless fabric.fabric_id == authority.fabric_id &&
                            fabric.root_public_key == authority.root_public_key &&
                            fabric.intermediate_cert == authority.intermediate_cert
        Crypto::MatterCertificate::Validation.verify_chain(fabric.controller_noc, fabric.intermediate_cert,
          fabric.root_public_key, fabric.root_cert)
        noc = Crypto::MatterCertificate.from_slice(fabric.controller_noc)
        return false unless noc.fabric_id == fabric.fabric_id && noc.node_id == fabric.controller_node_id
        subject = DataType::NodeId.from_case_authenticated_tag(
          DataType::CaseAuthenticatedTag.create(cat, version)).id
        subjects = Crypto::MatterCertificate.subject_ids_from_tlv(fabric.controller_noc)
        cat_subject_count = subjects.count do |id|
          DataType::NodeId.case_authenticated_tag_from_subject?(id) != nil
        end
        subjects.includes?(subject) && cat_subject_count == 1
      end

      private def self.acl_grants_cat_version?(acl : Datastore::DatastoreAccessControlEntryStruct,
                                               cat : UInt16, max_version : UInt16) : Bool
        return false unless acl.auth_mode == Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE
        subjects = acl.subjects
        return false unless subjects
        subjects.any? do |subject|
          tag = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
          !tag.nil? && tag.identity_value == cat && tag.version <= max_version
        end
      end

      private def self.verify_joint_anchor!(im : ImClient, session : Session::SecureContext,
                                            peer : Socket::IPAddress, endpoint : UInt16,
                                            anchor_node_id : UInt64, root_cert : Bytes) : Nil
        unless session.case_session? && session.peer_node_id.try(&.id) == anchor_node_id
          raise Matter::AuthenticationError.new("Joint Fabric Datastore requires CASE with the expected Anchor")
        end
        root_report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Datastore::CLUSTER_ID, attribute_id: Datastore::ATTR_ANCHOR_ROOT_CA)
        root_data = root_report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                    raise Matter::ProtocolError.new("Joint Fabric Datastore AnchorRootCA returned no data")
        unless Bytes.from_tlv(root_data.to_slice) == root_cert
          raise Matter::AuthenticationError.new("Joint Fabric Datastore root differs from controller fabric")
        end
        node_report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Datastore::CLUSTER_ID, attribute_id: Datastore::ATTR_ANCHOR_NODE_ID)
        node_data = node_report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                    raise Matter::ProtocolError.new("Joint Fabric Datastore AnchorNodeID returned no data")
        unless UInt64.from_tlv(node_data.to_slice) == anchor_node_id
          raise Matter::AuthenticationError.new("Joint Fabric Datastore node differs from CASE peer")
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
          unless fabric_id == authority.fabric_id && node_id != DataType::NodeId::UNSPECIFIED
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
        unless fabric.ipk_value.size == Fabric::IPK_SIZE && fabric.controller_node_id != DataType::NodeId::UNSPECIFIED &&
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

      # Learn an Anchor's rotated IPK epochs while an authenticated CASE
      # session still exists, then durably update this controller identity.
      # Call after UpdateKeySet(0) or on an authenticated Datastore change.
      def self.refresh_ipk_from_anchor(store : StateStore, fabric : FabricInfo,
                                       im : ImClient, session : Session::SecureContext,
                                       peer : Socket::IPAddress, endpoint : UInt16,
                                       anchor_node_id : UInt64) : Nil
        unless session.case_session? && session.peer_node_id.try(&.id) == anchor_node_id
          raise Matter::AuthenticationError.new("IPK refresh requires CASE with the expected Anchor")
        end
        root_report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Datastore::CLUSTER_ID, attribute_id: Datastore::ATTR_ANCHOR_ROOT_CA)
        root = root_report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
               raise Matter::ProtocolError.new("AnchorRootCA read returned no data")
        unless Bytes.from_tlv(root.to_slice) == fabric.root_cert
          raise Matter::AuthenticationError.new("Anchor Datastore root differs from controller fabric")
        end
        node_report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Datastore::CLUSTER_ID, attribute_id: Datastore::ATTR_ANCHOR_NODE_ID)
        node = node_report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
               raise Matter::ProtocolError.new("AnchorNodeID read returned no data")
        unless UInt64.from_tlv(node.to_slice) == anchor_node_id
          raise Matter::AuthenticationError.new("Anchor Datastore node differs from CASE peer")
        end
        entries = read_datastore_list(Datastore::DatastoreGroupKeySetStruct,
          im, session, peer, endpoint, Datastore::ATTR_GROUP_KEY_SET_LIST)
        ipk = entries.find(&.group_key_set_id.==(Datastore::IPK_KEY_SET_ID)) ||
              raise Matter::ProtocolError.new("Anchor Datastore has no IPK key set")
        unless ipk.group_key_security_policy == Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst &&
               ipk.epoch_key0 && ipk.epoch_start_time0
          raise Matter::ProtocolError.new("Anchor Datastore IPK key set has no valid first epoch")
        end
        pairs = { {ipk.epoch_key0, ipk.epoch_start_time0},
                 {ipk.epoch_key1, ipk.epoch_start_time1},
                 {ipk.epoch_key2, ipk.epoch_start_time2} }
        keys = [] of Bytes
        previous_time : UInt64? = nil
        pairs.each do |key, time|
          if key.nil? != time.nil? || (key && key.size != Fabric::IPK_SIZE)
            raise Matter::ProtocolError.new("Anchor IPK epoch has invalid key or start time")
          end
          next unless key && time
          if previous_time && time <= previous_time
            raise Matter::ProtocolError.new("Anchor IPK epoch times are unordered")
          end
          keys << key
          previous_time = time
        end
        if keys.empty? || (ipk.epoch_key2 && ipk.epoch_key1.nil?)
          raise Matter::ProtocolError.new("Anchor IPK epochs are incomplete")
        end

        state = store.load
        stored = state.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
        stored.ipk_epoch_keys = keys
        state.replace_fabric(stored)
        store.save(state)
        fabric.ipk_epoch_keys = keys
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
        if controller_node_id == DataType::NodeId::UNSPECIFIED
          raise Matter::ConfigurationError.new("Administrator Node ID must be non-zero")
        end

        report = im.read_attribute(
          session: session,
          peer: peer,
          endpoint_id: Node::ROOT_ENDPOINT_ID,
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
          endpoint_id: Node::ROOT_ENDPOINT_ID,
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
