require "../cluster/joint_fabric_datastore"
require "../crypto/certificate_validation"
require "../datatype/node_id"
require "./credential_service"

module Matter
  module Commissioning
    # Matter Core §12.2.5 step 5: an Administrator joining a Joint Fabric
    # accepts only a NOC with its current Administrator CAT and an Anchor CAT
    # as CaseAdminSubject. This is applied only to the JCM fail-safe session.
    module JointFabricAddNocPolicy
      extend self

      alias Datastore = Cluster::JointFabricDatastore

      def current_versions(datastore : Datastore) : {UInt16, UInt16}?
        admin_version = current_version(datastore, Datastore::ADMINISTRATOR_CAT)
        anchor_version = current_version(datastore, Datastore::ANCHOR_CAT)
        {admin_version, anchor_version} if admin_version && anchor_version
      end

      def validate(noc : Bytes, case_admin_subject : UInt64,
                   datastore : Datastore?) : NocOutcome?
        return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Joint Fabric Datastore is unavailable") unless datastore
        unless versions = current_versions(datastore)
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Joint Fabric CAT versions are unavailable")
        end
        admin_version, anchor_version = versions
        admin_subject = cat_subject(Datastore::ADMINISTRATOR_CAT, admin_version)
        unless Crypto::MatterCertificate.subject_ids_from_tlv(noc).includes?(admin_subject)
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "JCM NOC lacks the current Administrator CAT")
        end
        anchor_subject = cat_subject(Datastore::ANCHOR_CAT, anchor_version)
        unless case_admin_subject == anchor_subject
          return NocOutcome.new(NocStatus::InvalidAdminSubject, debug_text: "JCM CaseAdminSubject lacks the current Anchor CAT")
        end
        nil
      end

      private def current_version(datastore : Datastore, identity : UInt16) : UInt16?
        groups = datastore.group_list.select(&.group_cat.==(identity))
        return unless groups.size == 1
        version = groups.first.group_cat_version
        version unless version == Datastore::UNSPECIFIED_GROUP_CAT_VERSION
      end

      private def cat_subject(identity : UInt16, version : UInt16) : UInt64
        DataType::NodeId.from_case_authenticated_tag(
          DataType::CaseAuthenticatedTag.create(identity, version)).id
      end
    end
  end
end
