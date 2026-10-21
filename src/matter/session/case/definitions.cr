require "tlv"

module Matter
  module Session
    module Case
      module Definitions
        # Session parameter structure (used in Sigma1 and Sigma2)
        # Contains session idle/active interval parameters
        struct SessionParameter
          include TLV::Serializable

          # Session idle interval in milliseconds (tag 1)
          @[TLV::Field(tag: 1, optional: true)]
          property session_idle_interval : UInt32?

          # Session active interval in milliseconds (tag 2)
          @[TLV::Field(tag: 2, optional: true)]
          property session_active_interval : UInt32?

          # Session active threshold in milliseconds (tag 3)
          @[TLV::Field(tag: 3, optional: true)]
          property session_active_threshold : UInt16?

          # Data model revision (tag 4)
          @[TLV::Field(tag: 4, optional: true)]
          property data_model_revision : UInt16?

          # Interaction model revision (tag 5)
          @[TLV::Field(tag: 5, optional: true)]
          property interaction_model_revision : UInt16?

          # Specification version (tag 6)
          @[TLV::Field(tag: 6, optional: true)]
          property specification_version : UInt32?

          # Max paths per invoke (tag 7)
          @[TLV::Field(tag: 7, optional: true)]
          property max_paths_per_invoke : UInt16?

          def initialize(
            @session_idle_interval : UInt32? = nil,
            @session_active_interval : UInt32? = nil,
            @session_active_threshold : UInt16? = nil,
            @data_model_revision : UInt16? = nil,
            @interaction_model_revision : UInt16? = nil,
            @specification_version : UInt32? = nil,
            @max_paths_per_invoke : UInt16? = nil,
          )
          end
        end

        # CASE Sigma1 message
        # Sent by initiator (chip-tool) to begin CASE session establishment
        struct Sigma1
          include TLV::Serializable

          # Initiator's random value (32 bytes, tag 1)
          @[TLV::Field(tag: 1)]
          property initiator_random : Bytes

          # Initiator's session ID (tag 2)
          @[TLV::Field(tag: 2)]
          property initiator_session_id : UInt16

          # Destination ID - compressed fabric ID + node ID (tag 3)
          @[TLV::Field(tag: 3)]
          property destination_id : Bytes

          # Initiator's ephemeral public key (65 bytes EC point, tag 4)
          @[TLV::Field(tag: 4)]
          property initiator_eph_pub_key : Bytes

          # Optional initiator session params (tag 5) - Structure containing session parameters
          @[TLV::Field(tag: 5, optional: true)]
          property initiator_session_params : SessionParameter?

          # Optional resumption ID (tag 6)
          @[TLV::Field(tag: 6, optional: true)]
          property resumption_id : Bytes?

          # Optional initiator resume MIC (tag 7)
          @[TLV::Field(tag: 7, optional: true)]
          property initiator_resume_mic : Bytes?

          def initialize(
            @initiator_random : Bytes,
            @initiator_session_id : UInt16,
            @destination_id : Bytes,
            @initiator_eph_pub_key : Bytes,
            @initiator_session_params : SessionParameter? = nil,
            @resumption_id : Bytes? = nil,
            @initiator_resume_mic : Bytes? = nil,
          )
          end
        end

        # CASE Sigma2 message
        # Sent by responder (device) in response to Sigma1
        struct Sigma2
          include TLV::Serializable

          # Responder's random value (32 bytes, tag 1)
          @[TLV::Field(tag: 1)]
          property responder_random : Bytes

          # Responder's session ID (tag 2)
          @[TLV::Field(tag: 2)]
          property responder_session_id : UInt16

          # Responder's ephemeral public key (65 bytes EC point, tag 3)
          @[TLV::Field(tag: 3)]
          property responder_eph_pub_key : Bytes

          # Encrypted responder certificate (tag 4)
          @[TLV::Field(tag: 4)]
          property encrypted2 : Bytes

          # Optional responder session params (tag 5) - Structure containing session parameters
          @[TLV::Field(tag: 5, optional: true)]
          property responder_session_params : SessionParameter?

          # Optional resumption ID (tag 6)
          @[TLV::Field(tag: 6, optional: true)]
          property resumption_id : Bytes?

          # Optional responder resume MIC (tag 7)
          @[TLV::Field(tag: 7, optional: true)]
          property responder_resume_mic : Bytes?

          def initialize(
            @responder_random : Bytes,
            @responder_session_id : UInt16,
            @responder_eph_pub_key : Bytes,
            @encrypted2 : Bytes,
            @responder_session_params : SessionParameter? = nil,
            @resumption_id : Bytes? = nil,
            @responder_resume_mic : Bytes? = nil,
          )
          end
        end

        # Short responder handshake when both peers retained CASE resumption
        # state. Context tags follow Matter 1.6 Core 4.14.2.3.
        struct Sigma2Resume
          include TLV::Serializable

          @[TLV::Field(tag: 1)]
          property resumption_id : Bytes

          @[TLV::Field(tag: 2)]
          property resume_mic : Bytes

          @[TLV::Field(tag: 3)]
          property responder_session_id : UInt16

          @[TLV::Field(tag: 4, optional: true)]
          property responder_session_params : SessionParameter?

          def initialize(
            @resumption_id : Bytes,
            @resume_mic : Bytes,
            @responder_session_id : UInt16,
            @responder_session_params : SessionParameter? = nil,
          )
          end
        end

        # CASE Sigma3 message
        # Sent by initiator (chip-tool) to complete CASE session establishment
        struct Sigma3
          include TLV::Serializable

          # Encrypted initiator certificate (tag 1)
          @[TLV::Field(tag: 1)]
          property encrypted3 : Bytes

          def initialize(@encrypted3 : Bytes)
          end
        end

        # TLV structure for signed data in Sigma2
        # Used as input for signature generation
        struct SignedData
          include TLV::Serializable

          # Responder NOC (tag 1)
          @[TLV::Field(tag: 1)]
          property responder_noc : Bytes

          # Responder ICAC - optional (tag 2)
          @[TLV::Field(tag: 2, optional: true)]
          property responder_icac : Bytes?

          # Responder public key (tag 3)
          @[TLV::Field(tag: 3)]
          property responder_public_key : Bytes

          # Initiator public key (tag 4)
          @[TLV::Field(tag: 4)]
          property initiator_public_key : Bytes

          def initialize(
            @responder_noc : Bytes,
            @responder_icac : Bytes?,
            @responder_public_key : Bytes,
            @initiator_public_key : Bytes,
          )
          end
        end

        # TLV structure for encrypted data in Sigma2
        # This structure is TLV-encoded, then encrypted
        struct EncryptedDataSigma2
          include TLV::Serializable

          # Responder NOC (tag 1)
          @[TLV::Field(tag: 1)]
          property responder_noc : Bytes

          # Responder ICAC - optional (tag 2)
          @[TLV::Field(tag: 2, optional: true)]
          property responder_icac : Bytes?

          # Signature (tag 3)
          @[TLV::Field(tag: 3)]
          property signature : Bytes

          # Resumption ID (tag 4)
          @[TLV::Field(tag: 4)]
          property resumption_id : Bytes

          def initialize(
            @responder_noc : Bytes,
            @responder_icac : Bytes?,
            @signature : Bytes,
            @resumption_id : Bytes,
          )
          end
        end

        # TLV structure for encrypted data in Sigma3 (TBE_Data3)
        # This structure is decrypted from Sigma3.encrypted3
        struct EncryptedDataSigma3
          include TLV::Serializable

          # Initiator's NOC (named responder_noc for consistency) (tag 1)
          @[TLV::Field(tag: 1)]
          property responder_noc : Bytes

          # Initiator's ICAC - optional (tag 2)
          @[TLV::Field(tag: 2, optional: true)]
          property responder_icac : Bytes?

          # Signature (tag 3)
          @[TLV::Field(tag: 3)]
          property signature : Bytes

          def initialize(
            @responder_noc : Bytes,
            @responder_icac : Bytes?,
            @signature : Bytes,
          )
          end
        end
      end
    end
  end
end
