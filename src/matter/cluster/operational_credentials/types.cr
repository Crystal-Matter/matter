require "../cluster"

module Matter
  module Cluster
    class OperationalCredentials < Base
      # Wire-format (TLV) types of the commands and attributes. The hand-written
      # types of the same names above are the cluster's domain API.
      module Tlv
        # This enumeration is used by the CertificateChainRequest command to convey which certificate from the device
        # attestation certificate chain to transmit back to the client.
        enum CertificateChainType : UInt8
          # Request the DER- encoded DAC certificate

          DacCertificate = 1

          # Request the DER- encoded PAI certificate

          PaiCertificate = 2
        end

        # This enumeration is used by the NOCResponse common response command to convey detailed out
        #
        # come of several of this cluster’s operations.
        enum NodeOperationalCertificateStatus : UInt8
          # OK, no error
          Ok = 0

          # Public Key in the NOC does not match the public key in the NOCSR
          InvalidPublicKey = 1

          # The Node Operational ID in the NOC is not formatted correctly.
          InvalidNodeOpId = 2

          # Any other validation error in NOC chain
          InvalidNoc = 3

          # No record of prior CSR for which this NOC could match
          MissingCsr = 4

          # NOCs table full, cannot add another one
          TableFull = 5

          # Invalid CaseAdminSubject field for an AddNOC command.
          InvalidAdminSubject = 6

          # Trying to AddNOC instead of UpdateNOC against an existing Fabric.
          FabricConflict = 9

          # Label already exists on another Fabric.
          LabelConflict = 10

          # FabricIndex argument is invalid.
          InvalidFabricIndex = 11
        end

        # This encodes a fabric sensitive NOC chain, underpinning a commissioned Operational Identity for a given Node.
        #
        # Note that the Trusted Root CA Certificate is not included in this structure. The roots are available in the
        # TrustedRootCertificates attribute of the Node Operational Credentials cluster.
        struct NOC
          include TLV::Serializable

          # This field shall contain the NOC for the struct's associated fabric, encoded using Matter Certificate
          # Encoding.
          @[TLV::Field(tag: 1)]
          property noc : Slice(UInt8)

          # This field shall contain the ICAC or the struct's associated fabric, encoded using Matter Certificate
          # Encoding. If no ICAC is present in the chain, this field shall be set to null.
          @[TLV::Field(tag: 2)]
          property icac : Slice(UInt8)?

          @[TLV::Field(tag: 3, optional: true)]
          property vvsc : Bytes?

          @[TLV::Field(tag: 254)]
          property fabric_index : UInt8

          def initialize(@noc : Slice(UInt8), @icac : Slice(UInt8)?, @fabric_index : UInt8, @vvsc : Bytes? = nil)
          end
        end

        # This structure encodes a Fabric Reference for a fabric within which a given Node is currently commissioned.
        struct FabricDescriptor
          include TLV::Serializable

          # This field shall contain the public key for the trusted root that scopes the fabric referenced by
          # FabricIndex and its associated operational credential (see Section 6.4.5.3, "Trusted Root CA Certificates").
          # The format for the key shall be the same as that used in the ec-pub-key field of the Matter Certificate
          # Encoding for the root in the operational certificate chain.
          @[TLV::Field(tag: 1)]
          property root_public_key : Slice(UInt8)

          # This field shall contain the value of AdminVendorID provided in the AddNOC command that led to the creation
          # of this FabricDescriptorStruct.
          @[TLV::Field(tag: 2)]
          property vendor_id : UInt16

          # This field shall contain the FabricID allocated to the fabric referenced by FabricIndex.
          @[TLV::Field(tag: 3)]
          property fabric_id : UInt64

          # This field shall contain the NodeID in use within the fabric referenced by FabricIndex.
          @[TLV::Field(tag: 4)]
          property node_id : UInt64

          # This field shall contain a commissioner-set label for the fabric referenced by FabricIndex. This label is
          # set by the UpdateFabricLabel command.
          @[TLV::Field(tag: 5)]
          property label : String

          @[TLV::Field(tag: 6, optional: true)]
          property vid_verification_statement : Bytes?

          @[TLV::Field(tag: 254)]
          property fabric_index : UInt8

          def initialize(
            @root_public_key : Slice(UInt8),
            @vendor_id : UInt16,
            @fabric_id : UInt64,
            @node_id : UInt64,
            @label : String,
            @fabric_index : UInt8,
            @vid_verification_statement : Bytes? = nil,
          )
          end
        end

        struct SetVIDVerificationStatementRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0, optional: true)]
          property vendor_id : UInt16?

          @[TLV::Field(tag: 1, optional: true)]
          property vid_verification_statement : Bytes?

          @[TLV::Field(tag: 2, optional: true)]
          property vvsc : Bytes?

          def initialize(@vendor_id : UInt16? = nil, @vid_verification_statement : Bytes? = nil, @vvsc : Bytes? = nil)
          end
        end

        struct SignVIDVerificationRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property fabric_index : UInt8

          @[TLV::Field(tag: 1)]
          property client_challenge : Bytes

          def initialize(@fabric_index : UInt8, @client_challenge : Bytes)
          end
        end

        struct SignVIDVerificationResponse
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property fabric_index : UInt8

          @[TLV::Field(tag: 1)]
          property fabric_binding_version : UInt8

          @[TLV::Field(tag: 2)]
          property signature : Bytes

          def initialize(@fabric_index : UInt8, @fabric_binding_version : UInt8, @signature : Bytes)
          end
        end

        # Input to the OperationalCredentials attestationRequest command
        struct AttestationRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property attestation_nonce : Slice(UInt8)

          def initialize(@attestation_nonce : Slice(UInt8))
          end
        end

        # This command shall be generated in response to an Attestation Request command.
        #
        # See Section 11.17.4.7, “Attestation Information” for details about the generation of the fields within this
        # response command.
        #
        # See Section F.2, “Device Attestation Response test vector” for an example computation of an AttestationResponse.
        struct AttestationResponse
          include TLV::Serializable

          # This field shall contain the octet string of the serialized attestation_elements_message.
          @[TLV::Field(tag: 0)]
          property attestation_elements : Slice(UInt8)

          # This field shall contain the octet string of the necessary attestation_signature as described in Section
          # 11.17.4.7, "Attestation Information".
          @[TLV::Field(tag: 1)]
          property attestation_signature : Slice(UInt8)

          def initialize(@attestation_elements : Slice(UInt8), @attestation_signature : Slice(UInt8))
          end
        end

        # Input to the OperationalCredentials certificateChainRequest command
        struct CertificateChainRequest
          include TLV::Serializable
          @[TLV::Field(tag: 0)]
          property certificate_type : CertificateChainType

          def initialize(@certificate_type : CertificateChainType)
          end
        end

        # This command shall be generated in response to a CertificateChainRequest command.
        struct CertificateChainResponse
          include TLV::Serializable

          # This field shall be the DER encoded certificate corresponding to the CertificateType field in the
          # CertificateChainRequest command.
          @[TLV::Field(tag: 0)]
          property certificate : Slice(UInt8)

          def initialize(@certificate : Slice(UInt8))
          end
        end

        # Input to the OperationalCredentials csrRequest command
        struct CsrRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property csr_nonce : Slice(UInt8)

          @[TLV::Field(tag: 1)]
          property is_for_update_noc : Bool?

          def initialize(@csr_nonce : Slice(UInt8), @is_for_update_noc : Bool? = nil)
          end
        end

        # This command shall be generated in response to a CSRRequest Command.
        #
        # See Section 11.17.4.9, “NOCSR Information” for details about the generation of the fields within this response
        # command.
        #
        # See Section F.3, “Node Operational CSR Response test vector” for an example computation of a CSRResponse.
        struct CsrResponse
          include TLV::Serializable

          # This field shall contain the octet string of the serialized nocsr_elements_message.
          #
          # This field shall contain the octet string of the necessary attestation_signature as described in Section
          # 11.17.4.9, "NOCSR Information".
          @[TLV::Field(tag: 0)]
          property nocsr_elements : Slice(UInt8)

          @[TLV::Field(tag: 1)]
          property attestation_signature : Slice(UInt8)

          def initialize(@nocsr_elements : Slice(UInt8), @attestation_signature : Slice(UInt8))
          end
        end

        # Input to the OperationalCredentials addNoc command
        struct AddNocRequest
          include TLV::Serializable
          @[TLV::Field(tag: 0)]
          property noc_value : Slice(UInt8)

          @[TLV::Field(tag: 1)]
          property icac_value : Slice(UInt8)?

          # This field shall contain the value of the Epoch Key for the Identity Protection Key (IPK) to set for the
          # Fabric which is to be added. This is needed to bootstrap a necessary configuration value for subsequent CASE
          # to succeed. See Section 4.13.2.6.1, “Identity Protection Key (IPK)” for details.
          #
          # The IPK shall be provided as an octet string of length CRYPTO_SYMMETRIC_KEY_LENGTH_BYTES.
          #
          # On successful execution of the AddNOC command, the side-effect of having provided this field shall be
          # equivalent to having done a GroupKeyManagement cluster KeySetWrite command invocation using the newly joined
          # fabric as the accessing fabric and with the following argument fields (assuming KeySetWrite allowed a
          # GroupKeySetID set to 0):
          @[TLV::Field(tag: 2)]
          property ipk_value : Slice(UInt8)

          # If the AddNOC command succeeds according to the semantics of the following subsections, then the
          #
          # Access Control SubjectID shall be used to atomically add an Access Control Entry enabling that Subject to
          # subsequently administer the Node whose operational identity is being added by this command.
          #
          # The format of the new Access Control Entry, created from this, shall be:
          #
          # NOTE
          #
          # Unless such an Access Control Entry is added atomically as described here, there would be no way for the
          # caller on its given Fabric to eventually add another Access Control Entry for CASE authentication mode, to
          # enable the new Administrator to administer the device, since the Fabric Scoping of the Access Control List
          # prevents the current Node from being able to write new entries scoped to that Fabric, if the session is
          # established from CASE. While a session established from PASE does gain Fabric Scope of a newly-joined
          # Fabric, this argument is made mandatory to provide symmetry between both types of session establishment,
          # both of which need to eventually add an "Administer Node over CASE" Access Control Entry to finalize new
          # Fabric configuration and subsequently be able to call the CommissioningComplete command.
          @[TLV::Field(tag: 3)]
          property case_admin_subject : UInt64

          # This field shall be set to the Vendor ID of the entity issuing the AddNOC command. This value shall NOT be
          # one of the reserved Vendor ID values defined in Table 1, “Vendor ID Allocations”.
          #
          # ### Effect When Received
          #
          # If this command is received without an armed fail-safe context (see Section 11.9.6.2, “ArmFailSafe
          # Command”), then this command shall fail with a FAILSAFE_REQUIRED status code sent back to the initiator.
          #
          # If a prior UpdateNOC or AddNOC command was successfully executed within the fail-safe timer period, then
          # this command shall fail with a CONSTRAINT_ERROR status code sent back to the initiator.
          #
          # If the prior CSRRequest state that preceded AddNOC had the IsForUpdateNOC field indicated as true, then this
          # command shall fail with a CONSTRAINT_ERROR status code sent back to the initiator.
          #
          # If no prior AddTrustedRootCertificate command was successfully executed within the fail-safe timer period,
          # then this command shall process an error by responding with a NOCResponse with a StatusCode of InvalidNOC as
          # described in Section 11.17.6.7.2, “Handling Errors”. In other words,
          #
          # AddNOC always requires that the client provides the root of trust certificate within the same Fail- Safe
          # context as the rest of the new fabric’s operational credentials, even if some other fabric already uses the
          # exact same root of trust certificate.
          #
          # If the NOC provided in the NOCValue encodes an Operational Identifier for a <Root Public Key, FabricID> pair
          # already present on the device, then the device shall process the error by responding with a StatusCode of
          # FabricConflict as described in Section 11.17.6.7.2, “Handling Errors”.
          #
          # If the device already has the CommissionedFabrics attribute equal to the SupportedFabrics attribute, then
          # the device’s operational credentials table is considered full and the device shall process the error by
          # responding with a StatusCode of TableFull as described in Section 11.17.6.7.2, “Handling Errors”.
          #
          # If the CaseAdminSubject field is not a valid ACL subject in the context of AuthMode set to CASE, such as not
          # being in either the Operational or CASE Authenticated Tag range, then the device shall process the error by
          # responding with a StatusCode of InvalidAdminSubject as described in Section 11.17.6.7.2, “Handling Errors”.
          #
          # Otherwise, the command is considered an addition of credentials, also known as "joining a fabric", and the
          # following shall apply:
          #
          #   1. A new FabricIndex shall be allocated, taking the next valid fabric-index value in monotonically
          #       incrementing order, wrapping around from 254 (0xFE) to 1, since value 0 is reserved and using 255
          #       (0xFF) would prevent cluster specifications from using nullable fabric-idx fields.
          #
          #   2. An entry within the Fabrics attribute table shall be added, reflecting the matter-fabric-id RDN within
          #       the NOC’s subject, along with the public key of the trusted root of the chain and the AdminVendorID
          #       field.
          #
          #   3. The operational key pair associated with the incoming NOC from the NOCValue, and generated by the prior
          #       CSRRequest command, shall be recorded for subsequent use during CASE within the fail-safe timer period
          #       (see Section 5.5, “Commissioning Flows”).
          #
          #   4. The incoming NOCValue and ICACValue (if present) shall be stored under the FabricIndex associated with
          #       the new Fabric Scope, along with the RootCACertificate provided with the prior successful
          #       AddTrustedRootCertificate command invoked in the same fail-safe period.
          #
          #     a. Implementation of certificate chain storage may separate or otherwise encode the components of the
          #        array in implementation-specific ways, as long as they follow the correct format when being read from
          #        the NOCs list or used within other protocols such as CASE.
          #
          #   5. The NOCs list shall reflect the incoming NOC from the NOCValue field and ICAC from the ICACValue field
          #       (if present).
          #
          #   6. The operational discovery service record shall immediately reflect the new Operational Identifier, such
          #       that the Node immediately begins to exist within the Fabric and becomes reachable over CASE under the
          #       new operational identity.
          #
          #   7. The receiver shall create and add a new Access Control Entry using the CaseAdminSubject field to grant
          #       subsequent Administer access to an Administrator member of the new Fabric. It is RECOMMENDED that the
          #       Administrator presented in CaseAdminSubject exist within the same entity that is currently invoking
          #       the AddNOC command, within another of the Fabrics of which it is a member.
          #
          #   8. The incoming IPKValue shall be stored in the Fabric-scoped slot within the Group Key Management cluster
          #       (see KeySetWrite), for subsequent use during CASE.
          #
          #   9. The Fabric Index associated with the armed fail-safe context (see Section 11.9.6.2, “ArmFailSafe
          #       Command”) shall be updated to match the Fabric Index just allocated.
          #
          #   10. If the current secure session was established with PASE, the receiver shall:
          #
          #     a. Augment the secure session context with the FabricIndex generated above, such that subsequent
          #        interactions have the proper accessing fabric.
          #
          #   11. If the current secure session was established with CASE, subsequent configuration of the newly
          #       installed Fabric requires the opening of a new CASE session from the Administrator from the Fabric
          #       just installed. This Administrator is the one listed in the CaseAdminSubject argument.
          #
          # Thereafter, the Node shall respond with an NOCResponse with a StatusCode of OK and a FabricIndex field
          # matching the FabricIndex under which the new Node Operational Certificate (NOC) is scoped.
          @[TLV::Field(tag: 4)]
          property admin_vendor_id : UInt16

          def initialize(@noc_value : Slice(UInt8), @icac_value : Slice(UInt8)?, @ipk_value : Slice(UInt8), @case_admin_subject : UInt64, @admin_vendor_id : UInt16)
          end
        end

        # This command shall be generated in response to the following commands:
        #
        #   • AddNOC
        #
        #   • UpdateNOC
        #
        #   • UpdateFabricLabel
        #
        #   • RemoveFabric
        #
        # It provides status information about the success or failure of those commands.
        struct TlvNocResponse
          include TLV::Serializable

          # This field shall contain an NOCStatus value representing the status of an operation involving a NOC.
          @[TLV::Field(tag: 0)]
          property status_code : NodeOperationalCertificateStatus

          # This field shall be present whenever StatusCode has a value of OK. If present, it shall contain the Fabric
          # Index of the Fabric last added, removed or updated.
          @[TLV::Field(tag: 1)]
          property fabric_index : UInt8?

          # This field may contain debugging textual information from the cluster implementation, which SHOULD NOT be
          # presented to user interfaces in any way. Its purpose is to help developers in troubleshooting errors and the
          # contents may go into logs or crash reports.
          @[TLV::Field(tag: 2)]
          property debug_text : String?

          def initialize(
            @status_code : NodeOperationalCertificateStatus,
            @fabric_index : UInt8? = nil,
            @debug_text : String? = nil,
          )
          end
        end

        # Input to the OperationalCredentials updateNoc command
        struct UpdateNocRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property noc_value : Slice(UInt8)

          @[TLV::Field(tag: 1)]
          property icac_value : Slice(UInt8)?

          @[TLV::Field(tag: 254)]
          property fabric_index : UInt8

          def initialize(@noc_value : Slice(UInt8), @fabric_index : UInt8, @icac_value : Slice(UInt8)? = nil)
          end
        end

        # Input to the OperationalCredentials updateFabricLabel command
        # Note: fabric_index is optional - if not provided, it should be taken from the session context
        struct UpdateFabricLabelRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property label : String

          @[TLV::Field(tag: 254)]
          property fabric_index : UInt8?

          def initialize(@label : String, @fabric_index : UInt8? = nil)
          end
        end

        # Input to the OperationalCredentials removeFabric command
        struct RemoveFabricRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property fabric_index : UInt8

          def initialize(@fabric_index : UInt8)
          end
        end

        # Input to the OperationalCredentials addTrustedRootCertificate command
        struct AddTrustedRootCertificateRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property root_certificate : Slice(UInt8)

          def initialize(@root_certificate : Slice(UInt8))
          end
        end
      end
    end
  end
end
