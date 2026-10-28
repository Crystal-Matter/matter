require "../cluster/joint_fabric_datastore"
require "../crypto/certificate_validation"
require "../datatype/node_id"
require "../session/context"

module Matter
  module Controller
    # CASE pairing has already verified the peer NOC through its presented
    # ICAC. These role checks use the authenticated NOC subjects and issuer
    # retained on the session, including sessions resumed from verified CASE.
    module JointFabricPeerAuthentication
      extend self

      def verify_administrator!(session : Session::SecureContext) : Nil
        require_cat!(session, Cluster::JointFabricDatastore::ADMINISTRATOR_CAT, "Administrator")
      end

      def verify_anchor!(session : Session::SecureContext,
                         root_certificate : Bytes, fabric_id : UInt64) : Nil
        require_cat!(session, Cluster::JointFabricDatastore::ANCHOR_CAT, "Anchor")
        verify_administrator!(session)
        icac = session.peer_icac
        unless icac && Crypto::MatterCertificate.anchor_icac?(icac)
          raise Matter::AuthenticationError.new("Outbound Anchor CASE peer lacks an Anchor ICAC")
        end
        Crypto::MatterCertificate::Validation.verify_intermediate_profile(icac, fabric_id)
        Crypto::MatterCertificate::Validation.verify_issued_by(icac, root_certificate)
        Crypto::MatterCertificate::Validation.verify_signature(icac,
          Crypto::MatterCertificate.public_key_from_tlv(root_certificate))
      end

      private def require_cat!(session : Session::SecureContext,
                               identity : UInt16, role : String) : Nil
        present = session.peer_subject_ids.any? do |subject|
          cat = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
          cat && cat.identity_value == identity
        end
        unless session.case_session? && present
          raise Matter::AuthenticationError.new("Outbound CASE peer lacks the #{role} CAT")
        end
      end
    end
  end
end
