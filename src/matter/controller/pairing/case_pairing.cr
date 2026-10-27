require "log"

require "../../crypto/crypto"
require "../../crypto/ecdh"
require "../../crypto/key"
require "../../crypto/certificate"
require "../../crypto/certificate_validation"
require "../../fabric"
require "../../session/case/definitions"
require "../../session/case/resumption_store"
require "../../session/pase/definitions"
require "../client"
require "../operational_peer_resolver"
require "../state"
require "../state_store"

module Matter
  module Controller
    module Pairing
      class CasePairing
        record VerifiedResponder, subject_ids : Array(UInt64), icac : Bytes?
        Log = ::Log.for("matter.controller.pairing.case_pairing")

        MSG_CASE_SIGMA1        = 0x30_u8
        MSG_CASE_SIGMA2        = 0x31_u8
        MSG_CASE_SIGMA3        = 0x32_u8
        MSG_CASE_SIGMA2_RESUME = 0x33_u8
        MSG_STATUS_REPORT      = 0x40_u8

        SIGMA2_INFO = "Sigma2".to_slice
        SIGMA3_INFO = "Sigma3".to_slice

        TBE_DATA2_NONCE = "NCASE_Sigma2N".to_slice
        TBE_DATA3_NONCE = "NCASE_Sigma3N".to_slice

        SESSION_KEYS_INFO  = "SessionKeys".to_slice
        IPV4_MAPPED_PREFIX = "::ffff:"

        def initialize(@crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
                       @resumption_store : Session::Case::ResumptionStore? = nil)
        end

        # Select the controller identity explicitly when a state contains
        # multiple fabrics. The original FabricInfo overload remains available.
        def pair(
          client : Client,
          peer : Socket::IPAddress,
          state : State,
          peer_node_id : UInt64,
          fabric_id : UInt64? = nil,
          root_public_key : Bytes? = nil,
          controller_node_id : UInt64? = nil,
          timeout : Time::Span = 10.seconds,
        ) : Session::SecureContext
          if (root_public_key || controller_node_id) && fabric_id.nil?
            raise Matter::ConfigurationError.new("Selecting a fabric by root public key or controller Node ID also requires a fabric ID")
          end
          fabric = fabric_id ? state.fabric_for(fabric_id, root_public_key, controller_node_id) : state.fabric
          unless fabric
            raise Matter::ConfigurationError.new("No controller fabric is installed")
          end
          pair(client, peer, fabric, peer_node_id: peer_node_id, timeout: timeout)
        end

        # Resolve a commissioned node by its operational DNS-SD identity and
        # remember the address only after CASE verifies the expected fabric
        # and Node ID. A saved address is used when discovery is unavailable.
        def pair_discovered(
          client : Client,
          store : StateStore,
          peer_node_id : UInt64,
          fabric_id : UInt64? = nil,
          root_public_key : Bytes? = nil,
          controller_node_id : UInt64? = nil,
          timeout : Time::Span = 10.seconds,
          resolver : OperationalPeerResolver = OperationalPeerResolver.new,
        ) : Tuple(Session::SecureContext, Socket::IPAddress)
          if (root_public_key || controller_node_id) && fabric_id.nil?
            raise Matter::ConfigurationError.new("Selecting a fabric by root public key or controller Node ID also requires a fabric ID")
          end
          state = store.load
          fabric = if id = fabric_id
                     state.fabric_for(id, root_public_key, controller_node_id)
                   else
                     state.fabric || raise Matter::ConfigurationError.new("No controller fabric is installed")
                   end
          peer = resolver.resolve(state, fabric, peer_node_id, timeout)
          if intervals = resolver.last_mrp_parameters
            client.transport.configure_mrp_peer(peer, Codec::MessageCodec::UNSECURED_SESSION_ID,
              intervals[0], intervals[1], intervals[2])
          end
          record_peer = false
          begin
            session = pair(client, peer, fabric, peer_node_id: peer_node_id, timeout: timeout)
            if intervals = resolver.last_mrp_parameters
              session.peer_mrp_idle_interval_ms ||= intervals[0]
              session.peer_mrp_active_interval_ms ||= intervals[1]
              session.peer_mrp_active_threshold_ms ||= intervals[2]
              client.transport.configure_mrp_peer(peer, session.session_id,
                session.peer_mrp_idle_interval_ms, session.peer_mrp_active_interval_ms,
                session.peer_mrp_active_threshold_ms)
            end
            record_peer = true
            {session, peer}
          ensure
            # Sigma1 consumes an unsecured message counter even if CASE fails.
            store.update do |current|
              if record_peer
                current.record_node(fabric.fabric_id,
                  NodeInfo.new(peer_node_id, OperationalPeerResolver.address_hint(peer), peer.port),
                  fabric.root_public_key, fabric.controller_node_id)
              end
              current.unsecured_message_counter = client.transport.message_counter.counter
            end
          end
        end

        def pair(
          client : Client,
          peer : Socket::IPAddress,
          fabric : FabricInfo,
          peer_node_id : UInt64,
          timeout : Time::Span = 10.seconds,
        ) : Session::SecureContext
          keys = fabric.ipk_epoch_keys
          preferred = fabric.case_ipk_value
          candidates = [preferred] + keys.reverse.reject { |key| key == preferred }
          last_error : NoSharedRoot? = nil
          candidates.each do |epoch_key|
            return pair_with_ipk(client, peer, fabric, peer_node_id, timeout, epoch_key)
          rescue ex : NoSharedRoot
            last_error = ex
          end
          raise(last_error || Matter::ProtocolError.new("CASE: no shared IPK epoch"))
        end

        private class NoSharedRoot < Matter::ProtocolError
        end

        private def pair_with_ipk(client : Client, peer : Socket::IPAddress,
                                  fabric : FabricInfo, peer_node_id : UInt64,
                                  timeout : Time::Span, epoch_key : Bytes) : Session::SecureContext
          controller_key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
          controller_key.private_bits = fabric.controller_private_key
          controller_key.public_bits = Crypto::MatterCertificate.from_slice(fabric.controller_noc).ec_public_key

          controller_fabric = Fabric.new(
            fabric_id: fabric.fabric_id,
            fabric_index: Fabric::MIN_FABRIC_INDEX,
            node_id: fabric.controller_node_id,
            root_public_key: fabric.root_public_key,
            operational_cert: fabric.controller_noc,
            operational_key: controller_key,
            ipk: epoch_key,
            vendor_id: fabric.admin_vendor_id,
            label: "controller",
            intermediate_cert: fabric.intermediate_cert
          )

          initiator_random = @crypto.random_bytes(32)
          initiator_session_id = client.allocate_session_id("CASE") { @crypto.random_uint16 }

          ephemeral_key = Crypto::ECDH.generate_key_pair
          initiator_eph_pub = ephemeral_key.public_key

          destination_id = compute_destination_id(controller_fabric.derived_ipk, initiator_random, fabric.root_public_key, fabric.fabric_id, peer_node_id)

          resume_record = @resumption_store.try(&.find_by_peer(fabric.fabric_id,
            fabric.root_public_key, fabric.controller_node_id, peer_node_id,
            role: Session::Case::Role::Initiator))

          sigma1 = Session::Case::Definitions::Sigma1.new(
            initiator_random: initiator_random,
            initiator_session_id: initiator_session_id,
            destination_id: destination_id,
            initiator_eph_pub_key: initiator_eph_pub,
            resumption_id: resume_record.try(&.resumption_id),
            initiator_resume_mic: resume_record ? Session::Case.resume1_mic(@crypto,
              resume_record.shared_secret, initiator_random, resume_record.resumption_id) : nil
          )
          sigma1_bytes = sigma1.to_slice

          exchange_id = client.send_unsecured_request(
            peer: peer,
            protocol_id: Client::PROTOCOL_SECURE_CHANNEL,
            message_type: MSG_CASE_SIGMA1,
            payload: sigma1_bytes,
            requires_ack: true
          )

          sigma2 = client.wait_for_any(exchange_id, Client::PROTOCOL_SECURE_CHANNEL,
            [MSG_CASE_SIGMA2, MSG_CASE_SIGMA2_RESUME, MSG_STATUS_REPORT], timeout)
          raise Matter::TimeoutError.new("CASE: timeout waiting for Sigma2") unless sigma2
          unless same_peer?(sigma2.peer, peer)
            raise Matter::AuthenticationError.new("CASE: response came from another peer")
          end
          if sigma2.message.payload_header.message_type == MSG_STATUS_REPORT
            report = Session::Pase::Definitions::StatusReport.from_bytes(sigma2.message.payload.to_slice)
            if report.general_status == Session::Pase::Definitions::StatusReport::GENERAL_STATUS_FAILURE && report.protocol_status == Session::Pase::Definitions::StatusReport::CASE_NO_SHARED_ROOT
              raise NoSharedRoot.new("CASE: status report before Sigma2 (general_status=1 protocol_status=1)")
            end
            raise Matter::ProtocolError.new(
              "CASE: status report before Sigma2 (general_status=#{report.general_status} protocol_status=#{report.protocol_status})")
          end

          if sigma2.message.payload_header.message_type == MSG_CASE_SIGMA2_RESUME
            unless resume_record
              raise Matter::AuthenticationError.new("CASE: unsolicited Sigma2Resume")
            end
            return finish_resumed_case(client, peer, fabric, peer_node_id, exchange_id,
              initiator_random, initiator_session_id, resume_record, sigma2.message.payload.to_slice)
          end

          sigma2_msg = Session::Case::Definitions::Sigma2.from_slice(sigma2.message.payload.to_slice)
          sigma2_bytes = sigma2.message.payload.to_slice

          shared_secret = Crypto::ECDH.compute_shared_secret(ephemeral_key.private_key, sigma2_msg.responder_eph_pub_key)

          sigma1_hash = @crypto.compute_sha256(sigma1_bytes)
          sigma2_salt = IO::Memory.new.tap do |io|
            io.write(controller_fabric.derived_ipk)
            io.write(sigma2_msg.responder_random)
            io.write(sigma2_msg.responder_eph_pub_key)
            io.write(sigma1_hash)
          end.to_slice

          sigma2_key = @crypto.create_hkdf_key(shared_secret, sigma2_salt, SIGMA2_INFO, 16)
          decrypted2 = @crypto.decrypt(sigma2_key, sigma2_msg.encrypted2, TBE_DATA2_NONCE)
          encrypted_data2 = Session::Case::Definitions::EncryptedDataSigma2.from_slice(decrypted2)

          verified_responder = verify_sigma2_signature(encrypted_data2,
            sigma2_msg.responder_eph_pub_key, initiator_eph_pub, fabric, peer_node_id)

          signed_data3 = Session::Case::Definitions::SignedData.new(
            responder_noc: fabric.controller_noc,
            responder_icac: fabric.intermediate_cert,
            responder_public_key: initiator_eph_pub,
            initiator_public_key: sigma2_msg.responder_eph_pub_key
          )

          signature3 = @crypto.sign_ecdsa(controller_key, signed_data3.to_slice)

          encrypted_data3 = Session::Case::Definitions::EncryptedDataSigma3.new(
            responder_noc: fabric.controller_noc,
            responder_icac: fabric.intermediate_cert,
            signature: signature3
          )
          encrypted_data3_bytes = encrypted_data3.to_slice

          sigma3_hash = @crypto.compute_sha256(sigma1_bytes + sigma2_bytes)
          sigma3_salt = IO::Memory.new.tap do |io|
            io.write(controller_fabric.derived_ipk)
            io.write(sigma3_hash)
          end.to_slice

          sigma3_key = @crypto.create_hkdf_key(shared_secret, sigma3_salt, SIGMA3_INFO, 16)
          encrypted3 = @crypto.encrypt(sigma3_key, encrypted_data3_bytes, TBE_DATA3_NONCE)

          sigma3 = Session::Case::Definitions::Sigma3.new(encrypted3: encrypted3)
          sigma3_bytes = sigma3.to_slice

          client.send_unsecured_on_exchange(
            peer: peer,
            exchange_id: exchange_id,
            protocol_id: Client::PROTOCOL_SECURE_CHANNEL,
            message_type: MSG_CASE_SIGMA3,
            payload: sigma3_bytes,
            initiator_message: true,
            requires_ack: true
          )

          status = client.wait_for(exchange_id, Client::PROTOCOL_SECURE_CHANNEL, MSG_STATUS_REPORT, timeout)
          raise Matter::TimeoutError.new("CASE: timeout waiting for StatusReport") unless status
          unless same_peer?(status.peer, peer)
            raise Matter::AuthenticationError.new("CASE: status came from another peer")
          end

          report = Session::Pase::Definitions::StatusReport.from_bytes(status.message.payload.to_slice)
          unless report.general_status == Session::Pase::Definitions::StatusReport::GENERAL_STATUS_SUCCESS && report.protocol_status == Session::Pase::Definitions::StatusReport::PROTOCOL_STATUS_SUCCESS
            raise Matter::ProtocolError.new("CASE: status report failure (general_status=#{report.general_status} protocol_status=#{report.protocol_status})")
          end

          session_hash = @crypto.compute_sha256(sigma1_bytes + sigma2_bytes + sigma3_bytes)
          session_salt = IO::Memory.new.tap do |io|
            io.write(controller_fabric.derived_ipk)
            io.write(session_hash)
          end.to_slice

          session_keys = @crypto.create_hkdf_key(shared_secret, session_salt, SESSION_KEYS_INFO, 48)

          secure_context = Session::SecureContext.new(
            session_id: initiator_session_id,
            peer_session_id: sigma2_msg.responder_session_id,
            session_type: Session::SessionType::Unicast,
            encryption_key: session_keys[0, 16],  # I2R
            decryption_key: session_keys[16, 16], # R2I
            attestation_challenge: session_keys[32, 16],
            initiator: true,
            local_node_id: DataType::NodeId.new(fabric.controller_node_id),
            peer_node_id: DataType::NodeId.new(peer_node_id),
            case_session: true
          )
          secure_context.peer_subject_ids = verified_responder.subject_ids
          secure_context.peer_icac = verified_responder.icac
          if params = sigma2_msg.responder_session_params
            secure_context.peer_mrp_idle_interval_ms = params.session_idle_interval
            secure_context.peer_mrp_active_interval_ms = params.session_active_interval
            secure_context.peer_mrp_active_threshold_ms = params.session_active_threshold
          end

          client.register_session(secure_context, peer: peer)
          save_resumption_record(Session::Case::ResumptionStore::Record.new(
            fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
            peer_node_id, encrypted_data2.resumption_id, shared_secret,
            verified_responder.subject_ids, verified_responder.icac,
            role: Session::Case::Role::Initiator))
          secure_context
        end

        private def finish_resumed_case(client : Client, peer : Socket::IPAddress,
                                        fabric : FabricInfo, peer_node_id : UInt64,
                                        exchange_id : UInt16, initiator_random : Bytes,
                                        initiator_session_id : UInt16,
                                        record : Session::Case::ResumptionStore::Record,
                                        payload : Bytes) : Session::SecureContext
          sigma2 = Session::Case::Definitions::Sigma2Resume.from_slice(payload)
          unless Session::Case.valid_resume2_mic?(@crypto, record.shared_secret,
                   initiator_random, sigma2.resumption_id, sigma2.resume_mic)
            raise Matter::AuthenticationError.new("CASE: Sigma2Resume MIC is invalid")
          end
          keys = Session::Case.derive_session_keys(@crypto, record.shared_secret,
            initiator_random + record.resumption_id, Session::Case::Role::Initiator,
            resumption: true)
          session = Session::SecureContext.new(
            session_id: initiator_session_id,
            peer_session_id: sigma2.responder_session_id,
            session_type: Session::SessionType::Unicast,
            encryption_key: keys[:encryption],
            decryption_key: keys[:decryption],
            attestation_challenge: keys[:attestation_challenge],
            initiator: true,
            local_node_id: DataType::NodeId.new(fabric.controller_node_id),
            peer_node_id: DataType::NodeId.new(peer_node_id),
            case_session: true)
          session.peer_subject_ids = record.peer_subject_ids.dup
          session.peer_icac = record.peer_icac.try(&.dup)
          if params = sigma2.responder_session_params
            session.peer_mrp_idle_interval_ms = params.session_idle_interval
            session.peer_mrp_active_interval_ms = params.session_active_interval
            session.peer_mrp_active_threshold_ms = params.session_active_threshold
          end
          client.send_unsecured_on_exchange(peer: peer, exchange_id: exchange_id,
            protocol_id: Client::PROTOCOL_SECURE_CHANNEL,
            message_type: MSG_STATUS_REPORT,
            payload: Session::Pase::Definitions::StatusReport.new.to_bytes,
            initiator_message: true, requires_ack: true)
          client.register_session(session, peer: peer)
          save_resumption_record(Session::Case::ResumptionStore::Record.new(
            fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
            peer_node_id, sigma2.resumption_id, record.shared_secret,
            record.peer_subject_ids, record.peer_icac,
            role: Session::Case::Role::Initiator))
          session
        end

        private def save_resumption_record(record : Session::Case::ResumptionStore::Record) : Nil
          @resumption_store.try(&.save(record))
        rescue ex : Matter::Error
          Log.warn(exception: ex) { "CASE session established without a saved resumption record" }
        end

        private def same_peer?(received : Socket::IPAddress, expected : Socket::IPAddress) : Bool
          return false unless received.port == expected.port
          received_address = received.address
          expected_address = expected.address
          received_address = received_address[IPV4_MAPPED_PREFIX.size..] if received_address.starts_with?(IPV4_MAPPED_PREFIX)
          expected_address = expected_address[IPV4_MAPPED_PREFIX.size..] if expected_address.starts_with?(IPV4_MAPPED_PREFIX)
          received_address == expected_address
        end

        private def compute_destination_id(
          derived_ipk : Bytes,
          initiator_random : Bytes,
          root_public_key : Bytes,
          fabric_id : UInt64,
          node_id : UInt64,
        ) : Bytes
          data = IO::Memory.new
          data.write(initiator_random)
          data.write(root_public_key)

          fabric_id_bytes = Bytes.new(8)
          IO::ByteFormat::LittleEndian.encode(fabric_id, fabric_id_bytes)
          data.write(fabric_id_bytes)

          node_id_bytes = Bytes.new(8)
          IO::ByteFormat::LittleEndian.encode(node_id, node_id_bytes)
          data.write(node_id_bytes)

          Crypto.sign_hmac(derived_ipk, data.to_slice)
        end

        # Authenticate the responder's certificate as well as its handshake signature.
        def verify_sigma2_signature(
          encrypted_data2 : Session::Case::Definitions::EncryptedDataSigma2,
          responder_eph_pub : Bytes,
          initiator_eph_pub : Bytes,
          fabric : FabricInfo,
          peer_node_id : UInt64,
        ) : VerifiedResponder
          signed_data = Session::Case::Definitions::SignedData.new(
            responder_noc: encrypted_data2.responder_noc,
            responder_icac: encrypted_data2.responder_icac,
            responder_public_key: responder_eph_pub,
            initiator_public_key: initiator_eph_pub
          )

          noc = Crypto::MatterCertificate.from_slice(encrypted_data2.responder_noc)
          unless noc.fabric_id == fabric.fabric_id && noc.node_id == peer_node_id
            raise Matter::AuthenticationError.new("CASE: responder fabric or node ID does not match the requested peer")
          end
          Crypto::MatterCertificate::Validation.verify_chain(
            encrypted_data2.responder_noc,
            encrypted_data2.responder_icac,
            fabric.root_public_key,
            fabric.root_cert
          )
          public_key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
          public_key.public_bits = noc.ec_public_key

          @crypto.verify_ecdsa(public_key, signed_data.to_slice, encrypted_data2.signature)
          VerifiedResponder.new(Crypto::MatterCertificate.subject_ids_from_tlv(
            encrypted_data2.responder_noc), encrypted_data2.responder_icac.try(&.dup))
        rescue ex : Matter::AuthenticationError
          raise ex
        rescue ex
          raise Matter::AuthenticationError.new("CASE: Sigma2 signature verification failed: #{ex.message}", cause: ex)
        end
      end
    end
  end
end
