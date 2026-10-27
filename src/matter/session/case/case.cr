require "log"

require "../../codec/message_codec"
require "../../crypto/crypto"
require "../../crypto/certificate"
require "../../crypto/ecdh"
require "../../crypto/key"
require "../context"
require "openssl_ext"
require "tlv"
require "./definitions"

module Matter
  module Session
    module Case
      Log = ::Log.for("matter.session.case")

      # Matter spec key derivation info strings and nonces (Matter core
      # specification section 4.14.2, "CASE Session Establishment"). Both sides
      # of the handshake derive from the same constants; matter.js keeps the
      # same names in `packages/protocol/src/session/case/CaseMessages.ts`.
      KDFSR2_INFO                  = "Sigma2".to_slice
      KDFSR3_INFO                  = "Sigma3".to_slice
      KDFSR1_RESUME_INFO           = "Sigma1_Resume".to_slice
      KDFSR2_RESUME_INFO           = "Sigma2_Resume".to_slice
      RESUME1_MIC_NONCE            = "NCASE_SigmaS1".to_slice
      RESUME2_MIC_NONCE            = "NCASE_SigmaS2".to_slice
      TBE_DATA2_NONCE              = "NCASE_Sigma2N".to_slice
      TBE_DATA3_NONCE              = "NCASE_Sigma3N".to_slice
      SESSION_KEYS_INFO            = "SessionKeys".to_slice
      SESSION_RESUMPTION_KEYS_INFO = "SessionResumptionKeys".to_slice

      # AES-128-CCM key length: Sigma2/Sigma3 keys and each session key
      SYMMETRIC_KEY_LENGTH = 16
      # Session key material: I2R key ‖ R2I key ‖ attestation challenge
      SESSION_KEYS_LENGTH = SYMMETRIC_KEY_LENGTH * 3
      I2R_KEY_OFFSET      = 0
      R2I_KEY_OFFSET      = SYMMETRIC_KEY_LENGTH
      CHALLENGE_OFFSET    = SYMMETRIC_KEY_LENGTH * 2
      # Sigma1/Sigma2 random values
      RANDOM_LENGTH = 32
      # Resumption ID generated with Sigma2
      RESUMPTION_ID_LENGTH = 16
      RESUME_MIC_LENGTH    = 16
      # Sigma1 destination id: an HMAC-SHA256 tag
      DESTINATION_ID_LENGTH = 32

      # Which end of the handshake a set of session keys belongs to. The key
      # material is identical on both sides; only the encrypt/decrypt roles of
      # the I2R and R2I halves swap.
      enum Role
        Initiator
        Responder
      end

      alias SessionKeys = NamedTuple(encryption: Bytes, decryption: Bytes, attestation_challenge: Bytes)

      def self.resume1_mic(crypto : Crypto::CryptoBase, shared_secret : Bytes,
                           initiator_random : Bytes, resumption_id : Bytes) : Bytes
        resume_mic(crypto, shared_secret, initiator_random, resumption_id,
          KDFSR1_RESUME_INFO, RESUME1_MIC_NONCE)
      end

      def self.resume2_mic(crypto : Crypto::CryptoBase, shared_secret : Bytes,
                           initiator_random : Bytes, resumption_id : Bytes) : Bytes
        resume_mic(crypto, shared_secret, initiator_random, resumption_id,
          KDFSR2_RESUME_INFO, RESUME2_MIC_NONCE)
      end

      def self.valid_resume1_mic?(crypto : Crypto::CryptoBase, shared_secret : Bytes,
                                  initiator_random : Bytes, resumption_id : Bytes, mic : Bytes) : Bool
        valid_resume_mic?(crypto, shared_secret, initiator_random, resumption_id,
          mic, KDFSR1_RESUME_INFO, RESUME1_MIC_NONCE)
      end

      def self.valid_resume2_mic?(crypto : Crypto::CryptoBase, shared_secret : Bytes,
                                  initiator_random : Bytes, resumption_id : Bytes, mic : Bytes) : Bool
        valid_resume_mic?(crypto, shared_secret, initiator_random, resumption_id,
          mic, KDFSR2_RESUME_INFO, RESUME2_MIC_NONCE)
      end

      private def self.resume_mic(crypto : Crypto::CryptoBase, shared_secret : Bytes,
                                  initiator_random : Bytes, resumption_id : Bytes,
                                  info : Bytes, nonce : Bytes) : Bytes
        unless initiator_random.size == RANDOM_LENGTH && resumption_id.size == RESUMPTION_ID_LENGTH
          raise Matter::ProtocolError.new("CASE resumption random or ID has an invalid length")
        end
        key = crypto.create_hkdf_key(shared_secret, initiator_random + resumption_id,
          info, SYMMETRIC_KEY_LENGTH)
        crypto.encrypt(key, Bytes.empty, nonce)
      end

      private def self.valid_resume_mic?(crypto : Crypto::CryptoBase, shared_secret : Bytes,
                                         initiator_random : Bytes, resumption_id : Bytes,
                                         mic : Bytes, info : Bytes, nonce : Bytes) : Bool
        return false unless mic.size == RESUME_MIC_LENGTH &&
                            initiator_random.size == RANDOM_LENGTH && resumption_id.size == RESUMPTION_ID_LENGTH
        key = crypto.create_hkdf_key(shared_secret, initiator_random + resumption_id,
          info, SYMMETRIC_KEY_LENGTH)
        crypto.decrypt(key, mic, nonce).empty?
      rescue Matter::AuthenticationError
        false
      end

      # Operational certificate chain for CASE authentication
      # Note: For CASE Sigma2/Sigma3, these are operational certificates from commissioning,
      # NOT attestation certificates (DAC/PAI/PAA)
      struct OperationalCertChain
        property noc : Bytes   # Node Operational Certificate (from AddNOC)
        property icac : Bytes? # Intermediate CA Certificate (from AddNOC)
        property root : Bytes? # Root CA Certificate (optional, for validation)

        def initialize(@noc : Bytes, @icac : Bytes? = nil, @root : Bytes? = nil)
        end
      end

      # Concatenate the parts of an HKDF salt in order
      def self.build_salt(*parts : Bytes) : Bytes
        salt = IO::Memory.new
        parts.each { |part| salt.write(part) }
        salt.to_slice
      end

      # Derive the session keys both ends share once Sigma3 has been exchanged:
      #
      #     I2R ‖ R2I ‖ AttestationChallenge = HKDF(sharedSecret, salt, "SessionKeys", 48)
      #
      # The salt is `IPK ‖ SHA256(sigma1 ‖ sigma2 ‖ sigma3)`; the initiator
      # encrypts with I2R and decrypts with R2I, the responder the other way
      # round.
      def self.derive_session_keys(
        crypto : Crypto::CryptoBase,
        shared_secret : Bytes,
        salt : Bytes,
        role : Role,
        resumption : Bool = false,
      ) : SessionKeys
        info = resumption ? SESSION_RESUMPTION_KEYS_INFO : SESSION_KEYS_INFO
        keys = crypto.create_hkdf_key(shared_secret, salt, info, SESSION_KEYS_LENGTH)

        i2r_key = keys[I2R_KEY_OFFSET, SYMMETRIC_KEY_LENGTH]
        r2i_key = keys[R2I_KEY_OFFSET, SYMMETRIC_KEY_LENGTH]
        attestation_challenge = keys[CHALLENGE_OFFSET, SYMMETRIC_KEY_LENGTH]

        Log.trace { "Session keys: I2R=#{i2r_key.hexstring} R2I=#{r2i_key.hexstring} challenge=#{attestation_challenge.hexstring}" }

        case role
        in Role::Initiator
          {encryption: i2r_key, decryption: r2i_key, attestation_challenge: attestation_challenge}
        in Role::Responder
          {encryption: r2i_key, decryption: i2r_key, attestation_challenge: attestation_challenge}
        end
      end

      # CASE session establishment (initiator side - controller/commissioner)
      class CaseInitiator
        Log = ::Log.for("matter.session.case.initiator")

        property operational_cert : Bytes
        property operational_icac : Bytes?
        property operational_key : Crypto::Key
        property ephemeral_key : Crypto::Key?
        property peer_cert : Bytes?
        property peer_icac : Bytes?
        property peer_signature : Bytes?
        property peer_resumption_id : Bytes?
        property peer_ephemeral_key : Bytes?
        property peer_session_id : UInt16?
        property shared_secret : Bytes?
        property crypto : Crypto::CryptoBase
        property fabric_id : UInt64
        property node_id : UInt64
        property ipk : Bytes           # Identity Protection Key from fabric
        property session_id : UInt16?  # Session ID we advertised in Sigma1
        property sigma1_bytes : Bytes? # Raw Sigma1 message bytes for the transcript
        property sigma2_bytes : Bytes? # Raw Sigma2 message bytes for the transcript
        property sigma3_bytes : Bytes? # Raw Sigma3 message bytes for the transcript

        def initialize(
          @operational_cert : Bytes,
          @operational_key : Crypto::Key,
          @fabric_id : UInt64,
          @node_id : UInt64,
          @ipk : Bytes,
          @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
          @operational_icac : Bytes? = nil,
        )
          @peer_ephemeral_key = nil
          @shared_secret = nil
        end

        # Step 1: Generate an ephemeral key and the Sigma1 message.
        #
        # `destination_id` is the HMAC over the initiator random, root public
        # key, fabric id and peer node id that identifies the fabric to the
        # responder; the caller computes it because it holds the fabric's root
        # public key.
        def generate_sigma1(destination_id : Bytes) : {ephemeral_public_key: Bytes, random: Bytes, session_id: UInt16, sigma1_bytes: Bytes}
          # Generate ephemeral ECDH key pair
          ephemeral_key = Crypto::ECDH.generate_key_pair
          @ephemeral_key = ephemeral_key

          random = @crypto.random_bytes(RANDOM_LENGTH)
          session_id = @crypto.random_uint16
          @session_id = session_id

          sigma1 = Definitions::Sigma1.new(
            initiator_random: random,
            initiator_session_id: session_id,
            destination_id: destination_id,
            initiator_eph_pub_key: ephemeral_key.public_key
          )
          sigma1_bytes = sigma1.to_slice
          @sigma1_bytes = sigma1_bytes

          {
            ephemeral_public_key: ephemeral_key.public_key,
            random:               random,
            session_id:           session_id,
            sigma1_bytes:         sigma1_bytes,
          }
        end

        # Step 2: Process Sigma2 and produce Sigma3.
        #
        # `sigma2_bytes` is the raw TLV of the received message: the transcript
        # hash has to cover the bytes as they were sent, not a re-encoding.
        def process_sigma2(
          sigma2 : Definitions::Sigma2,
          sigma2_bytes : Bytes,
        ) : {encrypted_cert: Bytes, signature: Bytes, sigma3_bytes: Bytes}
          ephemeral_key = @ephemeral_key
          raise Matter::ProtocolError.new("Ephemeral key not generated") if ephemeral_key.nil?

          sigma1_bytes = @sigma1_bytes
          raise Matter::ProtocolError.new("Sigma1 bytes not available") if sigma1_bytes.nil?

          peer_ephemeral_public_key = sigma2.responder_eph_pub_key
          @peer_ephemeral_key = peer_ephemeral_public_key
          @peer_session_id = sigma2.responder_session_id
          @sigma2_bytes = sigma2_bytes

          # Compute shared secret using ECDH
          shared_secret = Crypto::ECDH.compute_shared_secret(
            ephemeral_key.private_key,
            peer_ephemeral_public_key
          )
          @shared_secret = shared_secret

          # Sigma2 key = HKDF(sharedSecret, IPK ‖ responderRandom ‖ responderEphPubKey ‖ SHA256(sigma1), "Sigma2")
          sigma2_salt = Case.build_salt(
            @ipk,
            sigma2.responder_random,
            peer_ephemeral_public_key,
            @crypto.compute_sha256(sigma1_bytes)
          )
          sigma2_key = @crypto.create_hkdf_key(shared_secret, sigma2_salt, KDFSR2_INFO, SYMMETRIC_KEY_LENGTH)

          # Decrypt TBE_Data2; a MIC failure means the peer does not hold the
          # shared secret and the handshake must fail.
          decrypted = begin
            @crypto.decrypt(sigma2_key, sigma2.encrypted2, TBE_DATA2_NONCE)
          rescue ex : Matter::CryptoError
            raise Matter::AuthenticationError.new("CASE: Sigma2 certificate decryption failed", cause: ex)
          end

          peer_data = begin
            Definitions::EncryptedDataSigma2.from_slice(decrypted)
          rescue ex
            raise Matter::AuthenticationError.new("CASE: Sigma2 encrypted payload is not a TBE_Data2 structure", cause: ex)
          end

          @peer_cert = peer_data.responder_noc
          @peer_icac = peer_data.responder_icac
          @peer_signature = peer_data.signature
          @peer_resumption_id = peer_data.resumption_id
          Log.debug { "CASE Sigma2: peer NOC #{peer_data.responder_noc.size} bytes, ICAC #{peer_data.responder_icac.try(&.size) || 0} bytes" }

          # Sign TBS_Data3 with our operational key: our NOC and ICAC, our
          # ephemeral public key, then the responder's.
          signed_data = Definitions::SignedData.new(
            responder_noc: @operational_cert,
            responder_icac: @operational_icac,
            responder_public_key: ephemeral_key.public_key,
            initiator_public_key: peer_ephemeral_public_key
          )
          signature = @crypto.sign_ecdsa(@operational_key, signed_data.to_slice)

          encrypted_data3 = Definitions::EncryptedDataSigma3.new(
            responder_noc: @operational_cert,
            responder_icac: @operational_icac,
            signature: signature
          )

          # Sigma3 key = HKDF(sharedSecret, IPK ‖ SHA256(sigma1 ‖ sigma2), "Sigma3")
          sigma3_salt = Case.build_salt(@ipk, @crypto.compute_sha256([sigma1_bytes, sigma2_bytes]))
          sigma3_key = @crypto.create_hkdf_key(shared_secret, sigma3_salt, KDFSR3_INFO, SYMMETRIC_KEY_LENGTH)
          encrypted_cert = @crypto.encrypt(sigma3_key, encrypted_data3.to_slice, TBE_DATA3_NONCE)

          sigma3_bytes = Definitions::Sigma3.new(encrypted3: encrypted_cert).to_slice
          @sigma3_bytes = sigma3_bytes

          {encrypted_cert: encrypted_cert, signature: signature, sigma3_bytes: sigma3_bytes}
        end

        # Verify a signature over `transcript` with the peer's certificate.
        # Raises `Matter::AuthenticationError` when the certificate cannot be
        # parsed or the signature does not verify.
        def verify_sigma3(signature : Bytes, transcript : Bytes) : Nil
          peer_cert = @peer_cert
          raise Matter::ProtocolError.new("Peer certificate not received") if peer_cert.nil?

          cert_obj = begin
            OpenSSL::X509::Certificate.from_der(peer_cert)
          rescue ex : OpenSSL::Error
            raise Matter::AuthenticationError.new("CASE: peer certificate cannot be parsed", cause: ex)
          end

          verified = OpenSSL::X509::SignatureVerifier.verify_signature(
            transcript,
            signature,
            cert_obj,
            :SHA256
          )
          raise Matter::AuthenticationError.new("CASE: Sigma3 signature verification failed") unless verified
        end

        # Derive session keys after successful CASE
        def derive_session_keys : SessionKeys
          shared_secret = @shared_secret
          sigma1_bytes = @sigma1_bytes
          sigma2_bytes = @sigma2_bytes
          sigma3_bytes = @sigma3_bytes

          raise Matter::ProtocolError.new("Shared secret not computed") if shared_secret.nil?
          raise Matter::ProtocolError.new("Sigma1 bytes not available") if sigma1_bytes.nil?
          raise Matter::ProtocolError.new("Sigma2 bytes not available") if sigma2_bytes.nil?
          raise Matter::ProtocolError.new("Sigma3 bytes not available") if sigma3_bytes.nil?

          salt = Case.build_salt(@ipk, @crypto.compute_sha256([sigma1_bytes, sigma2_bytes, sigma3_bytes]))
          Case.derive_session_keys(@crypto, shared_secret, salt, Role::Initiator)
        end
      end

      # CASE session establishment (responder side - device)
      class CaseResponder
        Log = ::Log.for("matter.session.case.responder")

        SESSION_ID_ALLOCATION_ATTEMPTS = 32

        property cert_chain : OperationalCertChain
        property operational_key : Crypto::Key
        property ephemeral_key : Crypto::Key?
        property peer_cert : Bytes?
        property peer_ephemeral_key : Bytes?
        property shared_secret : Bytes?
        property our_random : Bytes? # Random value we sent in Sigma2
        property resumption_id : Bytes?
        property our_ephemeral_public : Bytes? # Our ephemeral public key sent in Sigma2
        property crypto : Crypto::CryptoBase
        property fabric_id : UInt64
        property node_id : UInt64
        property ipk : Bytes           # Identity Protection Key from fabric
        property sigma1_bytes : Bytes? # Raw Sigma1 message bytes for hash
        property sigma2_bytes : Bytes? # Raw Sigma2 message bytes for session key derivation
        # Progressive hashing context - matches chip-tool's mCommissioningHash
        # Used to accumulate message bytes: Sigma1, then Sigma2, then Sigma3
        property transcript_hash : OpenSSL::Digest?
        # Peer's node ID extracted from their NOC certificate in Sigma3
        # This is critical for nonce construction in encrypted messages
        property peer_node_id : UInt64?
        # All authenticated Subject IDs for the peer (NodeId + any CATs).
        # Used for ACL evaluation (ACL subjects may be Node IDs or CATs).
        property peer_subject_ids : Array(UInt64) = [] of UInt64
        # Intermediate certificate the peer presented in Sigma3, if any
        property peer_icac : Bytes?
        # Public key of the fabric's root certificate. The peer's node
        # certificate has to chain to it, otherwise any member of the fabric
        # could mint one naming any node id it likes.
        property root_public_key : Bytes?

        def initialize(
          @cert_chain : OperationalCertChain,
          operational_key : Crypto::Key,
          @fabric_id : UInt64,
          @node_id : UInt64,
          @ipk : Bytes,
          @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
          @root_public_key : Bytes? = nil,
          @root_certificate : Bytes? = nil,
        )
          @peer_ephemeral_key = nil
          @shared_secret = nil
          @resumption_id = nil
          @our_random = nil
          @our_ephemeral_public = nil

          # Ensure operational key has public component for signing
          # Derive public key from private key if not already present
          if operational_key.public_bits.nil?
            # Use OpenSSL to derive public key from private key
            # Note: from_private_bytes expects NIST curve names like "P-256", not "prime256v1"
            ec_key = OpenSSL::PKey::EC.from_private_bytes(operational_key.private_key, Crypto::CRYPTO_EC_CURVE_NIST)
            pub_bytes = ec_key.public_key_bytes

            # Create a new Key with both private and public components
            @operational_key = operational_key.dup
            @operational_key.public_bits = pub_bytes
          else
            @operational_key = operational_key
          end
        end

        # Step 1: Process Sigma1 and generate Sigma2 response
        # sigma1_bytes: Raw TLV bytes of Sigma1 message (needed for key derivation)
        def process_sigma1(
          peer_ephemeral_public_key : Bytes,
          peer_random : Bytes,
          peer_session_id : UInt16,
          sigma1_bytes : Bytes,
          responder_session_id : UInt16? = nil,
        ) : {ephemeral_public_key: Bytes, random: Bytes, encrypted_cert: Bytes, session_id: UInt16, sigma2_bytes: Bytes}
          # Store sigma1 bytes for session key derivation
          @sigma1_bytes = sigma1_bytes

          # Initialize progressive hashing context (like chip-tool's mCommissioningHash)
          # Add sigma1 bytes to the hash - this matches chip-tool's AddData(Sigma1)
          transcript_hash = OpenSSL::Digest.new("SHA256")
          @transcript_hash = transcript_hash
          transcript_hash.update(sigma1_bytes)

          # Store peer ephemeral key
          @peer_ephemeral_key = peer_ephemeral_public_key

          # Generate our ephemeral ECDH key pair
          eph_key = Crypto::ECDH.generate_key_pair
          @ephemeral_key = eph_key

          # Compute shared secret using ECDH
          shared_secret = Crypto::ECDH.compute_shared_secret(
            eph_key.private_key,
            peer_ephemeral_public_key
          )
          @shared_secret = shared_secret
          Log.debug { "CASE Sigma2: ECDH shared_secret: #{shared_secret.hexstring}" }
          Log.debug { "CASE Sigma2: Our ephemeral public key: #{eph_key.public_key.hexstring}" }
          Log.debug { "CASE Sigma2: Peer ephemeral public key: #{peer_ephemeral_public_key.hexstring}" }

          # Generate random nonce for Sigma2 response
          random = @crypto.random_bytes(RANDOM_LENGTH)
          @our_random = random # Store for later signature verification

          # Store our ephemeral public key for later signature verification
          ephemeral_public = eph_key.public_key
          @our_ephemeral_public = ephemeral_public

          # Get intermediate digest from progressive hash (like chip-tool's GetDigest)
          # Dup the hash context to get digest WITHOUT finalizing
          # This way we can continue adding data (Sigma2, Sigma3) later
          sigma1_hash = transcript_hash.dup.final
          Log.debug { "CASE Sigma2: sigma1_bytes size: #{sigma1_bytes.size}, hash: #{sigma1_hash.hexstring}" }

          # Sigma2 salt: IPK ‖ responderRandom ‖ responderEphPubKey ‖ SHA256(sigma1)
          # Per Matter spec section 4.14.2
          salt_bytes = Case.build_salt(@ipk, random, ephemeral_public, sigma1_hash)

          # Derive Sigma2 encryption key using HKDF
          # Key = HKDF(sharedSecret, salt, "Sigma2", 16)
          sigma2_key = @crypto.create_hkdf_key(shared_secret, salt_bytes, KDFSR2_INFO, SYMMETRIC_KEY_LENGTH)
          Log.trace { "CASE Sigma2 encryption key: #{sigma2_key.hexstring}" }

          # Build TLV structure for signature (TBS_Data2)
          # This contains: NOC, ICAC (optional), responder's ephemeral public key, initiator's ephemeral public key
          signed_data = Definitions::SignedData.new(
            responder_noc: @cert_chain.noc,
            responder_icac: @cert_chain.icac,
            responder_public_key: ephemeral_public,
            initiator_public_key: peer_ephemeral_public_key
          )

          # Sign the TLV-encoded SignedData structure
          signed_data_bytes = signed_data.to_slice
          Log.debug { "CASE Sigma2 TBS_Data2: #{signed_data_bytes.size} bytes" }
          Log.trace { "  TBS_Data2 hex: #{signed_data_bytes.hexstring}" }
          signature = @crypto.sign_ecdsa(@operational_key, signed_data_bytes)
          Log.trace { "  Sigma2 signature: #{signature.hexstring}" }

          # The NOC must carry the public half of the key we just signed with,
          # or the initiator will reject the signature.
          begin
            noc_public_key = Crypto::MatterCertificate.public_key_from_tlv(@cert_chain.noc)
            if (pub = @operational_key.public_bits) && noc_public_key != pub
              Log.error { "CASE Sigma2: NOC public key does not match the operational key; the signature will fail verification" }
            end
          rescue ex
            Log.warn(exception: ex) { "CASE Sigma2: could not extract the NOC public key" }
          end

          resumption_id = @crypto.random_bytes(RESUMPTION_ID_LENGTH)
          @resumption_id = resumption_id

          # Build TLV structure for encryption (TBE_Data2)
          # This contains: NOC, ICAC (optional), signature, resumption ID
          encrypted_data = Definitions::EncryptedDataSigma2.new(
            responder_noc: @cert_chain.noc,
            responder_icac: @cert_chain.icac,
            signature: signature,
            resumption_id: resumption_id
          )

          # Encode the TLV structure to bytes
          encrypted_data_bytes = encrypted_data.to_slice
          Log.debug { "CASE Sigma2 TBE_Data2 (plaintext): #{encrypted_data_bytes.size} bytes" }
          Log.trace { "CASE Sigma2 TBE_Data2 hex: #{encrypted_data_bytes.hexstring}" }

          # Encrypt the TLV-encoded structure with fixed nonce "NCASE_Sigma2N"
          encrypted_cert = @crypto.encrypt(sigma2_key, encrypted_data_bytes, TBE_DATA2_NONCE)
          Log.debug { "CASE Sigma2 encrypted2: #{encrypted_cert.size} bytes" }

          # SecureChannel supplies an ID checked against all established and
          # pending sessions. Standalone callers still need a nonzero ID.
          session_id = responder_session_id || draw_nonzero_session_id
          raise Matter::ProtocolError.new("CASE responder session ID must be nonzero") if session_id == Codec::MessageCodec::UNSECURED_SESSION_ID

          # Build the Sigma2 TLV message for later use in session key derivation
          sigma2_msg = Definitions::Sigma2.new(
            responder_random: random,
            responder_session_id: session_id,
            responder_eph_pub_key: ephemeral_public,
            encrypted2: encrypted_cert
          )
          sigma2_bytes = sigma2_msg.to_slice
          @sigma2_bytes = sigma2_bytes

          # Add sigma2_bytes to progressive hash (like chip-tool's AddData(Sigma2))
          # This is done AFTER building sigma2, matching chip-tool's sequence
          transcript_hash.update(sigma2_bytes)
          Log.trace { "CASE Sigma2 TLV (#{sigma2_bytes.size} bytes): #{sigma2_bytes.hexstring}" }

          {
            ephemeral_public_key: ephemeral_public,
            random:               random,
            encrypted_cert:       encrypted_cert,
            session_id:           session_id,
            sigma2_bytes:         sigma2_bytes,
          }
        end

        private def draw_nonzero_session_id : UInt16
          SESSION_ID_ALLOCATION_ATTEMPTS.times do
            candidate = @crypto.random_uint16
            return candidate unless candidate == Codec::MessageCodec::UNSECURED_SESSION_ID
          end
          raise Matter::ProtocolError.new("Could not allocate a nonzero CASE responder session ID")
        end

        # Step 2: Process Sigma3 and verify
        # sigma3_bytes: Raw TLV bytes of Sigma3 message (needed for session key derivation)
        def process_sigma3(
          encrypted_cert : Bytes,
          sigma3_bytes : Bytes,
        ) : Bool
          ephemeral_key = @ephemeral_key
          shared_secret = @shared_secret
          sigma1_bytes = @sigma1_bytes
          sigma2_bytes = @sigma2_bytes

          raise Matter::ProtocolError.new("Ephemeral key not generated") if ephemeral_key.nil?
          raise Matter::ProtocolError.new("Shared secret not computed") if shared_secret.nil?
          raise Matter::ProtocolError.new("Sigma1 bytes not available") if sigma1_bytes.nil?
          raise Matter::ProtocolError.new("Sigma2 bytes not available") if sigma2_bytes.nil?
          raise Matter::ProtocolError.new("Transcript hash not available") if @transcript_hash.nil?

          # Get the combined hash from progressive hashing context (like chip-tool's GetDigest)
          # At this point, transcript_hash contains: Sigma1 + Sigma2
          # Dup to get digest WITHOUT finalizing (so we can add Sigma3 later for session keys)
          combined_hash = @transcript_hash.as(OpenSSL::Digest).dup.final
          Log.debug { "CASE Sigma3: SHA256(sigma1||sigma2) = #{combined_hash.hexstring}" }

          # Sigma3 salt: IPK ‖ SHA256(sigma1 ‖ sigma2)
          salt_bytes = Case.build_salt(@ipk, combined_hash)

          # Derive Sigma3 encryption key using HKDF
          # Key = HKDF(sharedSecret, salt, "Sigma3", 16)
          sigma3_key = @crypto.create_hkdf_key(shared_secret, salt_bytes, KDFSR3_INFO, SYMMETRIC_KEY_LENGTH)
          Log.trace { "CASE Sigma3 decryption key derived (#{sigma3_key.size} bytes)" }

          begin
            # Decrypt the peer's TBE_Data3 using fixed nonce "NCASE_Sigma3N"
            decrypted_data = @crypto.decrypt(sigma3_key, encrypted_cert, TBE_DATA3_NONCE)
            Log.debug { "CASE Sigma3 decrypted TBE_Data3: #{decrypted_data.size} bytes" }

            # Parse TBE_Data3 TLV structure
            encrypted_data3 = Definitions::EncryptedDataSigma3.from_slice(decrypted_data)

            # Store peer NOC
            @peer_cert = encrypted_data3.responder_noc
            @peer_icac = encrypted_data3.responder_icac

            Log.debug { "CASE Sigma3 peer NOC: #{encrypted_data3.responder_noc.size} bytes" }
            Log.debug { "CASE Sigma3 peer ICAC: #{encrypted_data3.responder_icac.try(&.size) || 0} bytes" }

            # Extract peer Subject IDs (NodeId + CATs) from their NOC certificate.
            # This is required for ACL evaluation: subjects may be Node IDs or CATs.
            @peer_subject_ids = Crypto::MatterCertificate.subject_ids_from_tlv(encrypted_data3.responder_noc)

            # Always set peer_node_id from the NodeId field (not from CATs).
            peer_node = Crypto::MatterCertificate.node_id_from_tlv(encrypted_data3.responder_noc)
            if peer_node
              @peer_node_id = peer_node

              # Ensure NodeId is present and first in the subject list.
              @peer_subject_ids.delete(peer_node)
              @peer_subject_ids.unshift(peer_node)

              Log.info { "CASE Sigma3: Extracted peer node ID: 0x#{peer_node.to_s(16)} (subjects=#{@peer_subject_ids.size})" }
            else
              Log.warn { "CASE Sigma3: Could not extract peer node ID from NOC (subjects=#{@peer_subject_ids.size})" }
            end

            # Build TBS_Data3 for signature verification
            # This contains: initiator NOC, ICAC (optional), initiator eph pub key, responder eph pub key
            peer_eph_key = @peer_ephemeral_key.as(Bytes)
            our_eph_key = @our_ephemeral_public.as(Bytes)

            signed_data = Definitions::SignedData.new(
              responder_noc: encrypted_data3.responder_noc,
              responder_icac: encrypted_data3.responder_icac,
              responder_public_key: peer_eph_key, # Initiator's ephemeral key
              initiator_public_key: our_eph_key   # Responder's ephemeral key
            )
            signed_data_bytes = signed_data.to_slice
            Log.debug { "CASE Sigma3 TBS_Data3: #{signed_data_bytes.size} bytes" }

            # The peer holds the private key of the NOC it just presented. Until
            # this passes, the NOC is only a claim: anyone who reached Sigma3
            # could replay a NOC read off the wire and inherit its node id, its
            # CATs and every ACL entry written for them.
            verify_sigma3_signature(
              encrypted_data3.responder_noc,
              signed_data_bytes,
              encrypted_data3.signature
            )

            # And the certificate itself has to have been issued by this
            # fabric's root, or the identity it names is the peer's own
            # invention.
            verify_peer_chain(encrypted_data3.responder_noc, encrypted_data3.responder_icac)

            Log.info { "CASE Sigma3 processed successfully" }

            true
          rescue ex
            Log.error(exception: ex) { "Failed to process Sigma3 (encrypted3_hex=#{encrypted_cert.hexstring})" }
            false
          end
        end

        # Verify TBS_Data3 against the public key carried by the peer's NOC.
        # Raises `Matter::AuthenticationError` when the certificate cannot be
        # read or the signature does not verify.
        private def verify_sigma3_signature(peer_noc : Bytes, transcript : Bytes, signature : Bytes) : Nil
          public_key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
          public_key.public_bits = Crypto::MatterCertificate.public_key_from_tlv(peer_noc)

          @crypto.verify_ecdsa(public_key, transcript, signature)
        rescue ex : Matter::AuthenticationError
          raise ex
        rescue ex
          raise Matter::AuthenticationError.new("CASE: Sigma3 signature could not be checked: #{ex.message}", cause: ex)
        end

        # Check the peer's certificates against the fabric root.
        private def verify_peer_chain(peer_noc : Bytes, peer_icac : Bytes?) : Nil
          root = @root_public_key
          if root.nil?
            raise Matter::AuthenticationError.new("CASE: no fabric root to check the peer certificate against")
          end

          Crypto::MatterCertificate::Validation.verify_chain(peer_noc, peer_icac, root, @root_certificate)
        end

        # Derive session keys after successful CASE
        # sigma3_bytes: Raw TLV bytes of Sigma3 message
        def derive_session_keys(sigma3_bytes : Bytes) : SessionKeys
          shared_secret = @shared_secret
          sigma1_bytes = @sigma1_bytes
          sigma2_bytes = @sigma2_bytes

          raise Matter::ProtocolError.new("Shared secret not computed") if shared_secret.nil?
          raise Matter::ProtocolError.new("Sigma1 bytes not available") if sigma1_bytes.nil?
          raise Matter::ProtocolError.new("Sigma2 bytes not available") if sigma2_bytes.nil?

          # Session key salt: IPK ‖ SHA256(sigma1 ‖ sigma2 ‖ sigma3)
          salt = Case.build_salt(@ipk, @crypto.compute_sha256([sigma1_bytes, sigma2_bytes, sigma3_bytes]))
          Case.derive_session_keys(@crypto, shared_secret, salt, Role::Responder)
        end
      end

      # Run a full CASE handshake between an initiator and a responder in
      # process. Both sides exchange the real Sigma1/Sigma2/Sigma3 TLV messages,
      # so the session keys they derive must match; the live client-side path is
      # `Matter::Controller::Pairing::CasePairing`, which talks to a socket.
      #
      # `destination_id` is opaque to this harness (nothing here resolves a
      # fabric from it), so a random tag stands in when the caller has no root
      # public key to compute one from.
      def self.establish_session(
        initiator_cert : Bytes,
        initiator_key : Crypto::Key,
        responder_cert_chain : OperationalCertChain,
        responder_key : Crypto::Key,
        fabric_id : UInt64,
        initiator_node_id : UInt64,
        responder_node_id : UInt64,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
        ipk : Bytes? = nil,
        destination_id : Bytes? = nil,
        root_public_key : Bytes? = nil,
      ) : {initiator: SecureContext, responder: SecureContext}
        session_ipk = ipk || crypto.random_bytes(SYMMETRIC_KEY_LENGTH)

        initiator = CaseInitiator.new(initiator_cert, initiator_key, fabric_id, initiator_node_id, session_ipk, crypto)
        responder = CaseResponder.new(
          responder_cert_chain, responder_key, fabric_id, responder_node_id, session_ipk, crypto,
          root_public_key: root_public_key
        )

        # 1. Initiator generates Sigma1
        sigma1 = initiator.generate_sigma1(destination_id || crypto.random_bytes(DESTINATION_ID_LENGTH))

        # 2. Responder processes Sigma1 and generates Sigma2
        sigma2 = responder.process_sigma1(
          sigma1[:ephemeral_public_key],
          sigma1[:random],
          sigma1[:session_id],
          sigma1[:sigma1_bytes]
        )

        # 3. Initiator processes Sigma2 and generates Sigma3
        sigma2_bytes = sigma2[:sigma2_bytes]
        sigma3 = initiator.process_sigma2(Definitions::Sigma2.from_slice(sigma2_bytes), sigma2_bytes)

        # 4. Responder processes Sigma3 and verifies
        unless responder.process_sigma3(sigma3[:encrypted_cert], sigma3[:sigma3_bytes])
          raise Matter::AuthenticationError.new("CASE Sigma3 verification failed")
        end

        # 5. Both sides derive the session keys from the same transcript
        initiator_keys = initiator.derive_session_keys
        responder_keys = responder.derive_session_keys(sigma3[:sigma3_bytes])

        initiator_context = SecureContext.new(
          session_id: sigma1[:session_id],
          peer_session_id: sigma2[:session_id],
          session_type: SessionType::Unicast,
          encryption_key: initiator_keys[:encryption],
          decryption_key: initiator_keys[:decryption],
          attestation_challenge: initiator_keys[:attestation_challenge],
          initiator: true,
          local_node_id: DataType::NodeId.new(initiator_node_id),
          peer_node_id: DataType::NodeId.new(responder_node_id),
          case_session: true
        )

        responder_context = SecureContext.new(
          session_id: sigma2[:session_id],
          peer_session_id: sigma1[:session_id],
          session_type: SessionType::Unicast,
          encryption_key: responder_keys[:encryption],
          decryption_key: responder_keys[:decryption],
          attestation_challenge: responder_keys[:attestation_challenge],
          initiator: false,
          local_node_id: DataType::NodeId.new(responder_node_id),
          peer_node_id: DataType::NodeId.new(initiator_node_id),
          case_session: true
        )

        {initiator: initiator_context, responder: responder_context}
      end
    end
  end
end
