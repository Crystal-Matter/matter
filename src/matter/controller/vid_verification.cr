require "../node"
require "../cluster/operational_credentials"
require "../crypto/certificate_validation"
require "./im_client"

module Matter
  module Controller
    # Matter Core 1.6 §6.4.10. The DCL trust database is deliberately an
    # explicit dependency: a matching self-reported VendorID is not evidence.
    module VidVerification
      extend self

      VERSION           =    1_u8
      STATEMENT_VERSION = 0x21_u8
      CHALLENGE_SIZE    =      32
      STATEMENT_SIZE    =      85
      SKID_SIZE         =      20

      struct VerifiedFabric
        getter descriptor : Cluster::OperationalCredentials::Tlv::FabricDescriptor
        getter noc : Cluster::OperationalCredentials::Tlv::NOC
        getter root_certificate : Bytes

        def initialize(@descriptor, @noc, @root_certificate)
        end
      end

      # An implementation must consult authenticated Operational Trust Anchors
      # for the claimed Vendor ID. Return false when trust data is unavailable.
      abstract class OperationalTrustAnchors
        abstract def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
        abstract def verify_statement?(
          vendor_id : UInt16,
          signer_skid : Bytes,
          statement_tbs : Bytes,
          signature : Bytes,
          vvsc : Bytes?,
        ) : Bool
      end

      # Explicitly provisioned trust for deployments without a DCL client.
      # Each Vendor ID is bound to exact, self-signed RCAC bytes. A missing
      # binding fails closed; VVS signatures require a separate trusted signer.
      class StaticOperationalTrustAnchors < OperationalTrustAnchors
        def initialize(@roots_by_vendor : Hash(UInt16, Array(Bytes)))
          @roots_by_vendor.each_value do |roots|
            roots.each do |root|
              certificate = Crypto::MatterCertificate.from_slice(root)
              unless Crypto::MatterCertificate::Validation.certificate_authority?(root)
                raise Matter::ConfigurationError.new("Operational trust root is not a CA")
              end
              Crypto::MatterCertificate::Validation.verify_signature(root, certificate.ec_public_key)
            end
          end
        end

        def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
          (@roots_by_vendor[vendor_id]? || [] of Bytes).any?(&.==(root_certificate))
        end

        def verify_statement?(vendor_id : UInt16, signer_skid : Bytes,
                              statement_tbs : Bytes, signature : Bytes,
                              vvsc : Bytes?) : Bool
          false
        end
      end

      # Compose an explicitly provisioned root policy with a separate VVS
      # signer policy. VidVerification invokes only one path for each fabric:
      # a present VVS never falls back to trusted_root? after signer rejection.
      class CompositeOperationalTrustAnchors < OperationalTrustAnchors
        def initialize(@root_trust : OperationalTrustAnchors,
                       @statement_trust : OperationalTrustAnchors)
        end

        def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
          @root_trust.trusted_root?(vendor_id, root_certificate)
        end

        def verify_statement?(vendor_id : UInt16, signer_skid : Bytes,
                              statement_tbs : Bytes, signature : Bytes,
                              vvsc : Bytes?) : Bool
          @statement_trust.verify_statement?(vendor_id, signer_skid, statement_tbs, signature, vvsc)
        end
      end

      def verify(
        im : ImClient,
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        fabric_index : UInt8,
        trust : OperationalTrustAnchors,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : VerifiedFabric
        attestation_challenge = session.attestation_challenge
        raise Matter::AuthenticationError.new("Missing session attestation challenge") unless attestation_challenge
        nocs = read_list(Cluster::OperationalCredentials::Tlv::NOC, im, session, peer,
          Cluster::OperationalCredentials::ATTR_NOCS)
        fabrics = read_list(Cluster::OperationalCredentials::Tlv::FabricDescriptor, im, session, peer,
          Cluster::OperationalCredentials::ATTR_FABRICS)
        roots = read_list(Bytes, im, session, peer,
          Cluster::OperationalCredentials::ATTR_TRUSTED_ROOT_CERTIFICATES)

        descriptor = fabrics.find { |entry| entry.fabric_index == fabric_index } ||
                     raise Matter::AuthenticationError.new("Requested fabric is absent")
        noc = nocs.find { |entry| entry.fabric_index == fabric_index } ||
              raise Matter::AuthenticationError.new("Requested fabric has no NOC")
        if noc.icac && noc.vvsc
          raise Matter::AuthenticationError.new("NOC entry cannot contain both ICAC and VVSC")
        end
        root = roots.find { |entry| Crypto::MatterCertificate.public_key_from_tlv(entry) == descriptor.root_public_key } ||
               raise Matter::AuthenticationError.new("Requested fabric has no matching root")

        Crypto::MatterCertificate::Validation.verify_signature(root, descriptor.root_public_key)
        Crypto::MatterCertificate::Validation.verify_chain(noc.noc, noc.icac, descriptor.root_public_key, root)
        certificate = Crypto::MatterCertificate.from_slice(noc.noc)
        unless certificate.fabric_id == descriptor.fabric_id && certificate.node_id == descriptor.node_id
          raise Matter::AuthenticationError.new("Fabric descriptor differs from NOC identity")
        end

        client_challenge = crypto.random_bytes(CHALLENGE_SIZE)
        request = Cluster::OperationalCredentials::Tlv::SignVIDVerificationRequest.new(fabric_index, client_challenge)
        invocation = im.invoke(session: session, peer: peer, endpoint_id: Node::ROOT_ENDPOINT_ID,
          cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
          command_id: Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST,
          fields: request.to_slice)
        response = Cluster::OperationalCredentials::Tlv::SignVIDVerificationResponse.from_slice(
          response_fields(invocation)
        )
        unless response.fabric_index == fabric_index && response.fabric_binding_version == VERSION
          raise Matter::AuthenticationError.new("VID verification response identifies another fabric or version")
        end

        binding = binding_message(descriptor)
        tbs = IO::Memory.new
        tbs.write_byte VERSION
        tbs.write client_challenge
        tbs.write attestation_challenge
        tbs.write_byte fabric_index
        tbs.write binding
        if statement = descriptor.vid_verification_statement
          tbs.write statement
        end
        noc_key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        noc_key.public_bits = certificate.ec_public_key
        crypto.verify_ecdsa(noc_key, tbs.to_slice, response.signature)

        if statement = descriptor.vid_verification_statement
          unless statement.size == STATEMENT_SIZE && statement[0] == STATEMENT_VERSION
            raise Matter::AuthenticationError.new("Invalid VID verification statement")
          end
          skid = statement[1, SKID_SIZE]
          statement_tbs = IO::Memory.new
          statement_tbs.write_byte STATEMENT_VERSION
          statement_tbs.write binding
          statement_tbs.write skid
          unless trust.verify_statement?(descriptor.vendor_id, skid, statement_tbs.to_slice,
                   statement[SKID_SIZE + 1, statement.size - SKID_SIZE - 1], noc.vvsc)
            raise Matter::AuthenticationError.new("Vendor statement has no trusted signer")
          end
        else
          trusted = trust.trusted_root?(descriptor.vendor_id, root)
          raise Matter::AuthenticationError.new("Fabric root has no trusted Vendor ID binding") unless trusted
        end

        VerifiedFabric.new(descriptor, noc, root)
      end

      def binding_message(descriptor : Cluster::OperationalCredentials::Tlv::FabricDescriptor) : Bytes
        io = IO::Memory.new
        io.write_byte VERSION
        io.write descriptor.root_public_key
        io.write_bytes descriptor.fabric_id, IO::ByteFormat::BigEndian
        io.write_bytes descriptor.vendor_id, IO::ByteFormat::BigEndian
        io.to_slice
      end

      private def read_list(type : T.class, im : ImClient, session : Session::SecureContext,
                            peer : Socket::IPAddress, attribute_id : UInt32) : Array(T) forall T
        report = im.read_attribute(session: session, peer: peer, endpoint_id: Node::ROOT_ENDPOINT_ID,
          cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
          attribute_id: attribute_id, fabric_filtered: false)
        data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        raise Matter::ProtocolError.new("VID verification read omitted attribute #{attribute_id}") unless data
        Array(T).from_tlv(data.to_slice)
      end

      private def response_fields(invocation : InteractionModel::InvokeResponseMessage) : Bytes
        ImClient.single_invoke_response!(invocation, "SignVIDVerificationRequest")
        invocation.invoke_responses.each do |item|
          if command = item.command_data
            if command.command_path.command == Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST_RESPONSE
              return command.command_fields.try(&.to_slice) || Bytes.empty
            end
          end
          if status = item.command_status
            raise Matter::CommissioningError.new("SignVIDVerificationRequest failed: #{status.status.status}")
          end
        end
        raise Matter::ProtocolError.new("SignVIDVerificationResponse missing")
      end
    end
  end
end
