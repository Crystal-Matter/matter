require "openssl"

require "../../crypto/crypto"
require "../../crypto/spake2p"
require "../../session/context"
require "../../session/pase/definitions"
require "../client"

module Matter
  module Controller
    module Pairing
      class PasePairing
        Log = ::Log.for("matter.controller.pairing.pase_pairing")

        MSG_PBKDF_PARAM_REQUEST  = 0x20_u8
        MSG_PBKDF_PARAM_RESPONSE = 0x21_u8
        MSG_PASE_PAKE1           = 0x22_u8
        MSG_PASE_PAKE2           = 0x23_u8
        MSG_PASE_PAKE3           = 0x24_u8
        MSG_STATUS_REPORT        = 0x40_u8

        def initialize(@crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        end

        def pair(
          client : Client,
          peer : Socket::IPAddress,
          pin_code : UInt32,
          timeout : Time::Span = 10.seconds,
        ) : Session::SecureContext
          initiator_random = @crypto.random_bytes(32)
          initiator_session_id = client.allocate_session_id("PASE") { @crypto.random_uint16 }

          pbkdf_req = Session::Pase::Definitions::PbkdfParamRequest.new(
            initiator_random: initiator_random,
            initiator_session_id: initiator_session_id,
            passcode_id: Session::Pase::Definitions::PbkdfParamRequest::DEFAULT_PASSCODE_ID,
            has_pbkdf_parameters: false,
            mrp_parameters: nil
          )
          pbkdf_req_bytes = pbkdf_req.to_slice

          exchange_id = client.send_unsecured_request(
            peer: peer,
            protocol_id: Client::PROTOCOL_SECURE_CHANNEL,
            message_type: MSG_PBKDF_PARAM_REQUEST,
            payload: pbkdf_req_bytes,
            requires_ack: true
          )

          pbkdf_resp = client.wait_for(exchange_id, Client::PROTOCOL_SECURE_CHANNEL, MSG_PBKDF_PARAM_RESPONSE, timeout)
          raise Matter::TimeoutError.new("PASE: timeout waiting for PBKDFParamResponse") unless pbkdf_resp

          pbkdf_resp_bytes = pbkdf_resp.message.payload.to_slice
          resp = Session::Pase::Definitions::PbkdfParamResponse.from_slice(pbkdf_resp_bytes)
          if mrp = resp.mrp_parameters
            client.transport.configure_mrp_peer(peer, Codec::MessageCodec::UNSECURED_SESSION_ID,
              mrp.idle_retransmit_timeout_ms, mrp.active_retransmit_timeout_ms)
          end

          pbkdf_params = resp.pbkdf_parameters
          raise Matter::ProtocolError.new("PASE: PBKDF parameters missing in response") unless pbkdf_params

          context_hash = OpenSSL::Digest.new("SHA256").tap do |digest|
            digest.update("CHIP PAKE V1 Commissioning".to_slice)
            digest.update(pbkdf_req_bytes)
            digest.update(pbkdf_resp_bytes)
          end.final

          w0_w1 = Crypto::Spake2p.compute_w0_w1(
            @crypto,
            Crypto::Spake2p::PbkdfParameters.new(pbkdf_params.iterations.to_i32, pbkdf_params.salt),
            pin_code
          )

          spake = Crypto::Spake2p.create(@crypto, context_hash, w0_w1.w0)
          p_a = spake.compute_x

          pake1_bytes = Session::Pase::Definitions::Pake1.new(x: p_a).to_slice
          client.send_unsecured_on_exchange(
            peer: peer,
            exchange_id: exchange_id,
            protocol_id: Client::PROTOCOL_SECURE_CHANNEL,
            message_type: MSG_PASE_PAKE1,
            payload: pake1_bytes,
            initiator_message: true,
            requires_ack: true
          )

          pake2 = client.wait_for(exchange_id, Client::PROTOCOL_SECURE_CHANNEL, MSG_PASE_PAKE2, timeout)
          raise Matter::TimeoutError.new("PASE: timeout waiting for Pake2") unless pake2

          pake2_msg = Session::Pase::Definitions::Pake2.from_slice(pake2.message.payload.to_slice)
          secret = spake.compute_secret_and_verifiers_from_y(w0_w1.w1, p_a, pake2_msg.y)

          unless pake2_msg.verifier == secret.h_bx
            raise Matter::AuthenticationError.new("PASE: verifier mismatch (expected=#{secret.h_bx.hexstring} got=#{pake2_msg.verifier.hexstring})")
          end

          pake3_bytes = Session::Pase::Definitions::Pake3.new(verifier: secret.h_ay).to_slice
          client.send_unsecured_on_exchange(
            peer: peer,
            exchange_id: exchange_id,
            protocol_id: Client::PROTOCOL_SECURE_CHANNEL,
            message_type: MSG_PASE_PAKE3,
            payload: pake3_bytes,
            initiator_message: true,
            requires_ack: true
          )

          status = client.wait_for(exchange_id, Client::PROTOCOL_SECURE_CHANNEL, MSG_STATUS_REPORT, timeout)
          raise Matter::TimeoutError.new("PASE: timeout waiting for StatusReport") unless status

          report = Session::Pase::Definitions::StatusReport.from_bytes(status.message.payload.to_slice)
          unless report.general_status == Session::Pase::Definitions::StatusReport::GENERAL_STATUS_SUCCESS && report.protocol_status == Session::Pase::Definitions::StatusReport::PROTOCOL_STATUS_SUCCESS
            raise Matter::ProtocolError.new("PASE: status report failure (general_status=#{report.general_status} protocol_status=#{report.protocol_status})")
          end

          responder_session_id = resp.responder_session_id

          session_keys = @crypto.create_hkdf_key(secret.ke, Bytes.new(0), "SessionKeys".to_slice, 48)
          encryption_key = session_keys[0, 16]
          decryption_key = session_keys[16, 16]
          attestation_challenge = session_keys[32, 16]

          session = Session::SecureContext.new(
            session_id: initiator_session_id,
            peer_session_id: responder_session_id,
            session_type: Session::SessionType::Unicast,
            encryption_key: encryption_key,
            decryption_key: decryption_key,
            attestation_challenge: attestation_challenge,
            initiator: true
          )
          if mrp = resp.mrp_parameters
            session.peer_mrp_idle_interval_ms = mrp.idle_retransmit_timeout_ms
            session.peer_mrp_active_interval_ms = mrp.active_retransmit_timeout_ms
          end
          session
        end
      end
    end
  end
end
