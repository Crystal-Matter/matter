require "log"
require "socket"

require "../codec/message_codec"
require "../fabric_table"
require "../session/case/case"
require "../session/case/definitions"
require "../session/case/resumption_store"
require "../session/context"
require "../session/pase/pase"
require "../transport/tcp_enabled_transport"
require "./message_type"
require "./response_sender"
require "./session_registry"

module Matter
  module Protocol
    # The PASE and CASE handshakes, and the PASE parameters a commissioning
    # window configures.
    #
    # Handshake state is keyed by peer endpoint and exchange id: commissioners
    # may independently choose the same exchange id, and an unsecured follow-up
    # from another peer must not advance either handshake.
    class SecureChannel
      Log = ::Log.for("matter.protocol.secure_channel")

      # How long an incomplete handshake is kept before it is discarded.
      HANDSHAKE_TIMEOUT = 60.seconds

      # PBKDFParamRequest and Sigma1 are unsecured. Bound their pending state
      # across all peers while allowing a new commissioner to make progress.
      MAX_HANDSHAKES_IN_FLIGHT = 64

      # Bound rejection sampling even if a random source repeats an unusable ID.
      SESSION_ID_ALLOCATION_ATTEMPTS = 32

      # SPAKE2+ context prefix (Matter spec 3.10).
      SPAKE_CONTEXT = "CHIP PAKE V1 Commissioning"

      # Length of the random values exchanged during PBKDF parameter discovery.
      RANDOM_LENGTH = 32

      # StatusReport general/protocol code for success (Matter spec 4.10.1.5).
      STATUS_REPORT_SUCCESS = 0_u16
      STATUS_REPORT_FAILURE = 1_u16
      PASE_INVALID_PARAM    = 2_u16
      CASE_NO_SHARED_ROOT   = 1_u16

      # An in-flight handshake, remembered against the exchange it runs on.
      private abstract class Handshake
        getter created_at : Time::Instant = Time.instant

        def expired?(now : Time::Instant = Time.instant) : Bool
          now - @created_at > HANDSHAKE_TIMEOUT
        end
      end

      # A PASE handshake between PBKDFParamRequest and Pake3.
      private class PaseHandshake < Handshake
        getter responder : Session::Pase::PaseResponder
        getter initiator_session_id : UInt16
        getter responder_session_id : UInt16
        getter mrp_parameters : Session::Pase::Definitions::MrpParameters?

        def initialize(@responder, @initiator_session_id, @responder_session_id, @mrp_parameters)
          super()
        end
      end

      # A CASE handshake between Sigma1 and Sigma3.
      private class CaseHandshake < Handshake
        getter responder : Session::Case::CaseResponder
        getter fabric : Fabric
        getter initiator_session_id : UInt16
        getter responder_session_id : UInt16
        getter session_parameters : Session::Case::Definitions::SessionParameter?

        def initialize(@responder, @fabric, @initiator_session_id, @responder_session_id, @session_parameters)
          super()
        end
      end

      private class CaseResumeHandshake < Handshake
        getter record : Session::Case::ResumptionStore::Record
        getter fabric : Fabric
        getter initiator_random : Bytes
        getter new_resumption_id : Bytes
        getter initiator_session_id : UInt16
        getter responder_session_id : UInt16
        getter session_parameters : Session::Case::Definitions::SessionParameter?

        def initialize(@record, @fabric, @initiator_random, @new_resumption_id,
                       @initiator_session_id, @responder_session_id, @session_parameters)
          super()
        end
      end

      alias HandshakeKey = Tuple(Socket::IPAddress, UInt16)

      @pase_handshakes : Hash(HandshakeKey, PaseHandshake) = {} of HandshakeKey => PaseHandshake
      @case_handshakes : Hash(HandshakeKey, CaseHandshake) = {} of HandshakeKey => CaseHandshake
      @case_resume_handshakes : Hash(HandshakeKey, CaseResumeHandshake) = {} of HandshakeKey => CaseResumeHandshake

      getter resumption_store : Session::Case::ResumptionStore

      private def handshake_key(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : HandshakeKey
        {peer, msg.payload_header.exchange_id}
      end

      private def evict_oldest_handshake : Nil
        pase = @pase_handshakes.min_by? { |_, handshake| handshake.created_at }
        case_entry = @case_handshakes.min_by? { |_, handshake| handshake.created_at }
        resume_entry = @case_resume_handshakes.min_by? { |_, handshake| handshake.created_at }
        if resume_entry && (!pase || resume_entry[1].created_at < pase[1].created_at) &&
           (!case_entry || resume_entry[1].created_at < case_entry[1].created_at)
          @case_resume_handshakes.delete(resume_entry[0])
          return
        end
        if pase && (!case_entry || pase[1].created_at <= case_entry[1].created_at)
          @pase_handshakes.delete(pase[0])
        elsif case_entry
          @case_handshakes.delete(case_entry[0])
        end
      end

      # The passcode the node commissions with, and the PBKDF parameters it
      # advertises. A commissioning window may replace them for its lifetime.
      getter setup_pin : UInt32
      getter iterations : UInt32
      getter salt : Bytes

      # A pre-computed SPAKE2+ passcode verifier (w0 || L) supplied by an
      # enhanced commissioning window, used instead of deriving one from the pin.
      getter passcode_verifier : Bytes?

      # Called when no fabric matches a Sigma1 destination id, as a last resort
      # for devices that hold their fabric outside the FabricTable.
      property on_get_fabric : Proc(Fabric?)?

      @local_mrp_idle_interval_ms : UInt32? = nil
      @local_mrp_active_interval_ms : UInt32? = nil
      @local_mrp_active_threshold_ms : UInt16? = nil

      def configure_local_mrp(idle_interval_ms : UInt32?, active_interval_ms : UInt32?,
                              active_threshold_ms : UInt16? = nil) : Nil
        @local_mrp_idle_interval_ms = idle_interval_ms
        @local_mrp_active_interval_ms = active_interval_ms
        @local_mrp_active_threshold_ms = active_threshold_ms
      end

      private def local_pase_mrp_parameters : Session::Pase::Definitions::MrpParameters?
        return unless @local_mrp_idle_interval_ms || @local_mrp_active_interval_ms
        Session::Pase::Definitions::MrpParameters.new(
          idle_retransmit_timeout_ms: @local_mrp_idle_interval_ms,
          active_retransmit_timeout_ms: @local_mrp_active_interval_ms)
      end

      private def local_case_session_parameters : Session::Case::Definitions::SessionParameter?
        return unless @local_mrp_idle_interval_ms || @local_mrp_active_interval_ms || @local_mrp_active_threshold_ms
        Session::Case::Definitions::SessionParameter.new(
          session_idle_interval: @local_mrp_idle_interval_ms,
          session_active_interval: @local_mrp_active_interval_ms,
          session_active_threshold: @local_mrp_active_threshold_ms)
      end

      @default_setup_pin : UInt32
      @default_iterations : UInt32
      @default_salt : Bytes

      # Injected only by protocol specs to force rejected ID candidates.
      @session_id_candidate : Proc(UInt16)

      def initialize(
        @fabric_table : FabricTable,
        @registry : SessionRegistry,
        @sender : ResponseSender,
        @setup_pin : UInt32,
        @iterations : UInt32,
        @salt : Bytes,
        @session_id_candidate : Proc(UInt16) = -> { Random::Secure.rand(UInt16) },
      )
        @default_setup_pin = @setup_pin
        @default_iterations = @iterations
        @default_salt = @salt.dup
        @passcode_verifier = nil
        @resumption_store = Session::Case::ResumptionStore.new(@fabric_table.backend)
        @fabric_table.register_removal_guard do |fabric|
          @resumption_store.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.node_id)
        end
      end

      # An encrypted session ID must be nonzero and must not alias either an
      # established session or any handshake that may still establish one.
      private def allocate_responder_session_id : UInt16
        SESSION_ID_ALLOCATION_ATTEMPTS.times do
          id = @session_id_candidate.call
          next if id == 0_u16 || @registry.session(id)
          next if @pase_handshakes.values.any?(&.responder_session_id.==(id))
          next if @case_handshakes.values.any?(&.responder_session_id.==(id))
          next if @case_resume_handshakes.values.any?(&.responder_session_id.==(id))
          return id
        end
        raise Matter::ProtocolError.new("Could not allocate an unused responder session ID")
      end

      # Handles a Secure Channel message. Returns whether it was one this
      # handles; StandaloneAck belongs to the subscription chunk ladder.
      def handle(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Bool
        prune_expired_handshakes

        case SecureChannelMessageType.from_value?(msg.payload_header.message_type)
        when SecureChannelMessageType::PbkdfParamRequest
          handle_pbkdf_param_request(msg, peer)
        when SecureChannelMessageType::PasePake1
          handle_pase_pake1(msg, peer)
        when SecureChannelMessageType::PasePake3
          handle_pase_pake3(msg, peer)
        when SecureChannelMessageType::StatusReport
          handle_status_report(msg, peer)
        when SecureChannelMessageType::CaseSigma1
          handle_case_sigma1(msg, peer)
        when SecureChannelMessageType::CaseSigma3
          handle_case_sigma3(msg, peer)
        else
          return false
        end

        true
      end

      # Configures PASE for an enhanced commissioning window, which supplies a
      # pre-computed SPAKE2+ verifier (w0 || L) rather than a passcode.
      def configure_pase_server(passcode_verifier : Bytes, iterations : UInt32, salt : Bytes) : Nil
        @registry.synchronize do
          @passcode_verifier = passcode_verifier.dup
          @iterations = iterations
          @salt = salt.dup
          @pase_handshakes.clear
        end
      end

      # Configures PASE for a basic commissioning window.
      def configure_pase_pin(pin : UInt32, iterations : UInt32, salt : Bytes) : Nil
        @registry.synchronize do
          @passcode_verifier = nil
          @setup_pin = pin
          @iterations = iterations
          @salt = salt.dup
          @pase_handshakes.clear
        end
      end

      # Restores the node's own PASE parameters and drops any window verifier.
      def reset_pase_server : Nil
        @registry.synchronize do
          @passcode_verifier = nil
          @setup_pin = @default_setup_pin
          @iterations = @default_iterations
          @salt = @default_salt.dup
          @pase_handshakes.clear
        end
      end

      # The number of handshakes in flight, for specs and diagnostics.
      def handshakes_in_flight : Int32
        @pase_handshakes.size + @case_handshakes.size + @case_resume_handshakes.size
      end

      # Forgets handshakes a commissioner started and walked away from. Runs on
      # every handshake message.
      def prune_expired_handshakes(now : Time::Instant = Time.instant) : Nil
        @pase_handshakes.reject! { |_, handshake| handshake.expired?(now) }
        @case_handshakes.reject! { |_, handshake| handshake.expired?(now) }
        @case_resume_handshakes.reject! { |_, handshake| handshake.expired?(now) }
      end

      # ----------------------------------------------------------------------
      # PASE
      # ----------------------------------------------------------------------

      # PBKDFParamRequest: answer with our PBKDF parameters and open a PASE
      # handshake on this exchange.
      private def handle_pbkdf_param_request(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Handling PBKDFParamRequest" }
        Log.trace { "PBKDF Request payload (#{msg.payload.size} bytes): #{msg.payload.hexstring}" }

        request_payload = msg.payload.dup
        request = begin
          Session::Pase::Definitions::PbkdfParamRequest.from_slice(request_payload)
        rescue ex : BinData::ParseError
          Log.warn { "Malformed PBKDFParamRequest: #{ex.message}" }
          send_status_report_invalid_param(msg, peer)
          return
        end

        unless request.valid?
          Log.error { "Invalid PBKDFParamRequest" }
          send_status_report_invalid_param(msg, peer)
          return
        end

        initiator_session_id = request.initiator_session_id || return
        initiator_random = request.initiator_random || return
        if mrp = request.mrp_parameters
          @sender.configure_unsecured_mrp_peer(peer,
            mrp.idle_retransmit_timeout_ms, mrp.active_retransmit_timeout_ms)
        end
        Log.debug { "  Initiator session ID: #{initiator_session_id}, random: #{initiator_random.size} bytes" }

        responder_session_id = allocate_responder_session_id
        response_payload = Session::Pase::Definitions::PbkdfParamResponse.new(
          initiator_random: initiator_random,
          responder_random: Random::Secure.random_bytes(RANDOM_LENGTH),
          responder_session_id: responder_session_id,
          pbkdf_parameters: request.has_pbkdf_parameters ? nil : Session::Pase::Definitions::PbkdfParametersTLV.new(@iterations, @salt),
          mrp_parameters: local_pase_mrp_parameters
        ).to_slice
        Log.debug { "PBKDF Response payload (#{response_payload.size} bytes): #{response_payload.hexstring}" }

        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::PbkdfParamResponse.value,
          payload: response_payload
        )
        Log.info { "Sent PBKDFParamResponse with session ID: #{responder_session_id}" }

        key = handshake_key(msg, peer)
        evict_oldest_handshake if !@pase_handshakes.has_key?(key) && handshakes_in_flight >= MAX_HANDSHAKES_IN_FLIGHT
        @pase_handshakes[key] = PaseHandshake.new(
          responder: build_pase_responder(spake_context_hash(request_payload, response_payload)),
          initiator_session_id: initiator_session_id,
          responder_session_id: responder_session_id,
          mrp_parameters: request.mrp_parameters
        )
        Log.debug { "Created PaseResponder with hashed context" }
      end

      # The SPAKE2+ context: SHA256(SPAKE_CONTEXT || request || response), over
      # the exact bytes both sides exchanged.
      private def spake_context_hash(request_payload : Bytes, response_payload : Bytes) : Bytes
        digest = OpenSSL::Digest.new("SHA256")
        digest.update(SPAKE_CONTEXT.to_slice)
        digest.update(request_payload)
        digest.update(response_payload)
        context_hash = digest.final
        Log.debug { "  SPAKE2+ context hash: #{context_hash.hexstring}" }
        context_hash
      end

      private def build_pase_responder(context_hash : Bytes) : Session::Pase::PaseResponder
        pbkdf_params = Session::Pase::PbkdfParameters.new(@iterations.to_i32, @salt)
        crypto = Crypto::StandardCrypto.new

        if verifier = @passcode_verifier
          Log.debug { "Creating PaseResponder using passcode verifier (bytes=#{verifier.size})" }
          Session::Pase::PaseResponder.from_passcode_verifier(verifier, pbkdf_params, crypto, context_hash)
        else
          Session::Pase::PaseResponder.new(@setup_pin, pbkdf_params, crypto, context_hash)
        end
      end

      # Pake1: the commissioner's public value; answer with ours and our
      # confirmation.
      private def handle_pase_pake1(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Handling PASE Pake1" }

        handshake = @pase_handshakes[handshake_key(msg, peer)]?
        unless handshake
          Log.error { "PASE responder not initialized - PBKDF request must come first (exchange=#{msg.payload_header.exchange_id})" }
          return
        end

        p_a = Session::Pase::Definitions::Pake1.from_slice(msg.payload).x
        Log.debug { "  Received pA: #{p_a.size} bytes" }
        Log.trace { "  pA hex: #{p_a.hexstring}" }

        p_b = handshake.responder.process_pake1(p_a)
        c_b = handshake.responder.generate_pake3
        Log.debug { "  Generated pB: #{p_b.size} bytes, cB: #{c_b.size} bytes" }

        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::PasePake2.value,
          payload: Session::Pase::Definitions::Pake2.new(y: p_b, verifier: c_b).to_slice
        )
        Log.info { "Sent PASE Pake2 (pB + cB)" }
      rescue ex
        Log.error(exception: ex) do
          "Error handling PASE Pake1: peer=#{peer.address}:#{peer.port} msg_id=#{msg.packet_header.message_id} " \
          "exchange=#{msg.payload_header.exchange_id} payload_hex=#{msg.payload.hexstring}"
        end
      end

      # Pake3: verify the commissioner's confirmation and open the session.
      private def handle_pase_pake3(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Handling PASE Pake3" }

        exchange_id = msg.payload_header.exchange_id
        key = handshake_key(msg, peer)
        handshake = @pase_handshakes[key]?
        unless handshake
          Log.error { "PASE responder not initialized (exchange=#{exchange_id})" }
          return
        end

        c_a = Session::Pase::Definitions::Pake3.from_slice(msg.payload).verifier
        Log.debug { "  Received cA: #{c_a.size} bytes" }

        secret_and_verifiers = handshake.responder.secret_and_verifiers
        unless secret_and_verifiers
          Log.error { "Shared secret not computed - Pake1 must be processed first" }
          return
        end

        unless c_a == secret_and_verifiers.h_ay
          Log.error { "PASE confirmation failed - cA doesn't match h_ay" }
          Log.trace { "  Expected: #{secret_and_verifiers.h_ay.hexstring}" }
          Log.trace { "  Received: #{c_a.hexstring}" }
          @pase_handshakes.delete(key)
          return
        end
        Log.debug { "PASE confirmation successful" }

        keys = handshake.responder.derive_session_keys
        Log.trace { "  Encryption key (R2I): #{keys[:encryption].hexstring}" }
        Log.trace { "  Decryption key (I2R): #{keys[:decryption].hexstring}" }
        Log.trace { "  Attestation challenge: #{keys[:attestation_challenge].hexstring}" }

        session = Session::SecureContext.new(
          session_id: handshake.responder_session_id,
          peer_session_id: handshake.initiator_session_id,
          session_type: Session::SessionType::Unicast,
          encryption_key: keys[:encryption],
          decryption_key: keys[:decryption],
          attestation_challenge: keys[:attestation_challenge],
          initiator: false
        )
        session.bind_tcp_peer(peer) if peer.port == Transport::TcpEnabledTransport::TOKEN_PORT
        if mrp = handshake.mrp_parameters
          session.peer_mrp_idle_interval_ms = mrp.idle_retransmit_timeout_ms
          session.peer_mrp_active_interval_ms = mrp.active_retransmit_timeout_ms
        end
        @registry.establish_session(session)
        @sender.configure_mrp_peer(peer, session)
        @sender.mark_mrp_peer_active(peer, session)
        @pase_handshakes.delete(key)

        Log.info do
          "PASE secure session established (session_id=#{handshake.responder_session_id}, " \
          "peer_session_id=#{handshake.initiator_session_id})"
        end

        # The session only becomes active once this unsecured StatusReport is
        # acknowledged, so it is sent on session 0 like the rest of the handshake.
        send_status_report_success(msg, peer)
      rescue ex
        Log.error(exception: ex) do
          "Error handling PASE Pake3: peer=#{peer.address}:#{peer.port} msg_id=#{msg.packet_header.message_id} " \
          "exchange=#{msg.payload_header.exchange_id} payload_hex=#{msg.payload.hexstring}"
        end
      end

      # ----------------------------------------------------------------------
      # CASE
      # ----------------------------------------------------------------------

      # Sigma1: find the fabric the initiator addressed and answer with Sigma2.
      private def handle_case_sigma1(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Handling CASE Sigma1" }

        sigma1 = Session::Case::Definitions::Sigma1.from_slice(msg.payload)
        if params = sigma1.initiator_session_params
          @sender.configure_unsecured_mrp_peer(peer,
            params.session_idle_interval, params.session_active_interval,
            params.session_active_threshold)
        end
        Log.info { "  Initiator session ID: #{sigma1.initiator_session_id}" }
        Log.debug { "  Destination ID: #{sigma1.destination_id.hexstring}" }

        match = find_fabric(sigma1)
        unless match
          Log.error { "No fabric found matching destination_id: #{sigma1.destination_id.hexstring}" }
          Log.error { "Device may not be commissioned or destination_id computation differs" }
          send_status_report(msg, peer, STATUS_REPORT_FAILURE, CASE_NO_SHARED_ROOT)
          return
        end
        fabric, matched_ipk = match

        if sigma1.resumption_id.nil? != sigma1.initiator_resume_mic.nil?
          send_status_report_invalid_param(msg, peer)
          return
        end
        if resumption_id = sigma1.resumption_id
          if resume_mic = sigma1.initiator_resume_mic
            return if handle_case_resume_sigma1(msg, peer, sigma1, fabric, resumption_id, resume_mic)
          end
        end

        Log.info { "Using fabric: #{fabric.fabric_id.to_s(16)} (NOC #{fabric.operational_cert.size} bytes)" }
        if icac = fabric.intermediate_cert
          Log.info { "  ICAC size: #{icac.size} bytes" }
        else
          Log.warn { "  NO ICAC in fabric - CASE may fail if controller expects 3-tier PKI" }
        end

        responder = Session::Case::CaseResponder.new(
          cert_chain: Session::Case::OperationalCertChain.new(
            noc: fabric.operational_cert,
            icac: fabric.intermediate_cert,
            root: nil # The responder does not send its root certificate
          ),
          operational_key: fabric.operational_key,
          fabric_id: fabric.fabric_id,
          node_id: fabric.node_id,
          ipk: matched_ipk,
          crypto: Crypto::StandardCrypto.new,
          # Sigma1 already pinned the fabric via the destination id; the peer's
          # node certificate has to chain to that fabric's root.
          root_public_key: fabric.root_public_key,
          root_certificate: fabric.root_cert
        )

        sigma2_data = responder.process_sigma1(
          peer_ephemeral_public_key: sigma1.initiator_eph_pub_key,
          peer_random: sigma1.initiator_random,
          peer_session_id: sigma1.initiator_session_id,
          sigma1_bytes: msg.payload,
          responder_session_id: allocate_responder_session_id
        )

        key = handshake_key(msg, peer)
        evict_oldest_handshake if !@case_handshakes.has_key?(key) && handshakes_in_flight >= MAX_HANDSHAKES_IN_FLIGHT
        @case_handshakes[key] = CaseHandshake.new(
          responder: responder,
          fabric: fabric,
          initiator_session_id: sigma1.initiator_session_id,
          responder_session_id: sigma2_data[:session_id],
          session_parameters: sigma1.initiator_session_params
        )
        @case_resume_handshakes.delete(key)

        Log.info { "  Generated Sigma2 response (responder session ID: #{sigma2_data[:session_id]})" }

        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::CaseSigma2.value,
          payload: Session::Case::Definitions::Sigma2.new(
            responder_random: sigma2_data[:random],
            responder_session_id: sigma2_data[:session_id],
            responder_eph_pub_key: sigma2_data[:ephemeral_public_key],
            encrypted2: sigma2_data[:encrypted_cert],
            responder_session_params: local_case_session_parameters
          ).to_slice
        )
        Log.info { "Sent CASE Sigma2" }
      rescue ex
        Log.error(exception: ex) do
          "Error handling CASE Sigma1: peer=#{peer.address}:#{peer.port} session_id=#{msg.packet_header.session_id} " \
          "msg_id=#{msg.packet_header.message_id} exchange=#{msg.payload_header.exchange_id} payload_hex=#{msg.payload.hexstring}"
        end
      end

      # Return true only when an authenticated resumption record was used.
      # Unknown or invalid records fall back to the full certificate exchange.
      private def handle_case_resume_sigma1(msg : Codec::MessageCodec::Message,
                                            peer : Socket::IPAddress,
                                            sigma1 : Session::Case::Definitions::Sigma1,
                                            fabric : Fabric, resumption_id : Bytes,
                                            resume_mic : Bytes) : Bool
        record = @resumption_store.find_by_id(resumption_id)
        return false unless record
        return false unless record.fabric_id == fabric.fabric_id &&
                            record.root_public_key == fabric.root_public_key &&
                            record.local_node_id == fabric.node_id
        crypto = Crypto::StandardCrypto.new
        return false unless Session::Case.valid_resume1_mic?(crypto, record.shared_secret,
                              sigma1.initiator_random, resumption_id, resume_mic)

        key = handshake_key(msg, peer)
        evict_oldest_handshake if !@case_resume_handshakes.has_key?(key) &&
                                  handshakes_in_flight >= MAX_HANDSHAKES_IN_FLIGHT
        responder_session_id = allocate_responder_session_id
        new_id = crypto.random_bytes(Session::Case::RESUMPTION_ID_LENGTH)
        @case_resume_handshakes[key] = CaseResumeHandshake.new(record, fabric,
          sigma1.initiator_random.dup, new_id, sigma1.initiator_session_id,
          responder_session_id, sigma1.initiator_session_params)
        @case_handshakes.delete(key)
        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::CaseSigma2Resume.value,
          payload: Session::Case::Definitions::Sigma2Resume.new(
            resumption_id: new_id,
            resume_mic: Session::Case.resume2_mic(crypto, record.shared_secret,
              sigma1.initiator_random, new_id),
            responder_session_id: responder_session_id,
            responder_session_params: local_case_session_parameters
          ).to_slice
        )
        true
      end

      # The fabric whose destination id matches the one the initiator computed
      # as HMAC-SHA256(IPK, initiatorRandom || rootPublicKey || fabricId || nodeId).
      private def find_fabric(sigma1 : Session::Case::Definitions::Sigma1) : Tuple(Fabric, Bytes)?
        Log.debug { "Searching #{@fabric_table.size} fabrics for destination_id match" } if @fabric_table.size > 0

        @fabric_table.all_fabrics.each do |fabric|
          if ipk = fabric.matching_derived_ipk(sigma1.destination_id, sigma1.initiator_random)
            Log.info { "  Matched fabric by destination_id: #{fabric.fabric_id.to_s(16)}" }
            return {fabric, ipk}
          end
        end

        fabric = @on_get_fabric.try(&.call)
        return unless fabric

        # The callback bypasses destination id matching; say so rather than
        # silently commissioning against the wrong fabric.
        ipk = fabric.matching_derived_ipk(sigma1.destination_id, sigma1.initiator_random)
        unless ipk
          Log.warn { "Fabric from callback doesn't match destination_id" }
          return
        end
        {fabric, ipk}
      end

      # Sigma3: verify the initiator's certificate and open the session.
      private def handle_case_sigma3(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Handling CASE Sigma3" }

        exchange_id = msg.payload_header.exchange_id
        key = handshake_key(msg, peer)
        handshake = @case_handshakes[key]?
        unless handshake
          Log.error { "CASE responder not initialized - Sigma1 must come first (exchange=#{exchange_id})" }
          return
        end

        sigma3 = Session::Case::Definitions::Sigma3.from_slice(msg.payload)
        Log.debug { "  Encrypted cert: #{sigma3.encrypted3.size} bytes" }

        responder = handshake.responder
        unless responder.process_sigma3(sigma3.encrypted3, msg.payload)
          Log.error { "CASE Sigma3 verification failed" }
          @case_handshakes.delete(key)
          return
        end
        Log.debug { "CASE Sigma3 verified successfully" }

        keys = responder.derive_session_keys(msg.payload)
        Log.trace { "  Derived encryption key (R2I): #{keys[:encryption].hexstring}" }
        Log.trace { "  Derived decryption key (I2R): #{keys[:decryption].hexstring}" }
        Log.trace { "  Derived attestation challenge: #{keys[:attestation_challenge].hexstring}" }

        # The fabric matched during Sigma1, not one looked up again: in a
        # multi-fabric node only the destination id identifies the right one.
        fabric = handshake.fabric
        Log.debug { "Using CASE fabric from Sigma1: fabric_id=0x#{fabric.fabric_id.to_s(16)}, index=#{fabric.fabric_index}" }

        # The peer node id comes from the NOC in Sigma3, and is what the AEAD
        # nonce of every later message is built from.
        peer_node_id = responder.peer_node_id
        Log.warn { "No peer node ID extracted from Sigma3; falling back to nil" } unless peer_node_id

        session = Session::SecureContext.new(
          session_id: handshake.responder_session_id,
          peer_session_id: handshake.initiator_session_id,
          session_type: Session::SessionType::Unicast,
          encryption_key: keys[:encryption],
          decryption_key: keys[:decryption],
          attestation_challenge: keys[:attestation_challenge], # Signs attestation responses
          initiator: false,
          local_node_id: DataType::NodeId.new(fabric.node_id),
          peer_node_id: peer_node_id ? DataType::NodeId.new(peer_node_id) : nil,
          case_session: true,
          fabric_index: fabric.fabric_index
        )

        # ACL subjects: the node id plus any CATs, which is how iOS installs
        # its entries.
        session.peer_subject_ids = responder.peer_subject_ids.dup
        session.peer_icac = responder.peer_icac.try(&.dup)
        if session.peer_subject_ids.empty?
          if peer_node = session.peer_node_id
            session.peer_subject_ids = [peer_node.id]
          end
        end
        Log.debug do
          subjects = session.peer_subject_ids.map { |id| "0x#{id.to_s(16)}" }.join(",")
          "CASE peer subjects: [#{subjects}] (session_id=#{session.session_id} fabric_index=#{session.fabric_index})"
        end

        session.bind_tcp_peer(peer) if peer.port == Transport::TcpEnabledTransport::TOKEN_PORT
        if params = handshake.session_parameters
          session.peer_mrp_idle_interval_ms = params.session_idle_interval
          session.peer_mrp_active_interval_ms = params.session_active_interval
          session.peer_mrp_active_threshold_ms = params.session_active_threshold
        end
        @registry.establish_session(session)
        @sender.configure_mrp_peer(peer, session)
        @sender.mark_mrp_peer_active(peer, session)
        @case_handshakes.delete(key)

        if id = responder.resumption_id
          if secret = responder.shared_secret
            if peer_node_id
              save_resumption_record(Session::Case::ResumptionStore::Record.new(
                fabric.fabric_id, fabric.root_public_key, fabric.node_id,
                peer_node_id, id, secret, session.peer_subject_ids,
                session.peer_icac))
            end
          end
        end

        Log.info do
          "CASE secure session established (session_id=#{session.session_id}, " \
          "peer_session_id=#{handshake.initiator_session_id}, fabric_index=#{fabric.fabric_index})"
        end

        send_status_report_success(msg, peer)
      rescue ex
        Log.error(exception: ex) do
          "Error handling CASE Sigma3: peer=#{peer.address}:#{peer.port} session_id=#{msg.packet_header.session_id} " \
          "msg_id=#{msg.packet_header.message_id} exchange=#{msg.payload_header.exchange_id} payload_hex=#{msg.payload.hexstring}"
        end
      end

      # ----------------------------------------------------------------------
      # Status reports
      # ----------------------------------------------------------------------

      private def handle_status_report(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        status_report = Session::Pase::Definitions::StatusReport.from_bytes(msg.payload)
        general = status_report.general_status
        protocol = status_report.protocol_status

        if general == STATUS_REPORT_SUCCESS && protocol == STATUS_REPORT_SUCCESS
          complete_case_resumption(handshake_key(msg, peer)) if msg.packet_header.session_id == 0
          Log.debug { "StatusReport: SUCCESS (peer=#{peer})" }
          return
        end

        @case_resume_handshakes.delete(handshake_key(msg, peer))

        Log.warn { "StatusReport: general=#{Hex.u16(general)}, protocol=#{Hex.u16(protocol)} (peer=#{peer})" }
        return if general == STATUS_REPORT_SUCCESS

        if @case_handshakes.has_key?(handshake_key(msg, peer))
          Log.debug do
            "StatusReport during CASE: protocol=#{Hex.u16(protocol)} " \
            "(e.g. 0x0002 NO_SHARED_TRUST_ROOTS; check ICAC/root trust)"
          end
        else
          Log.debug { "StatusReport during PASE: check PIN, SPAKE2+, and crypto parameter compatibility" }
        end
      rescue ex
        Log.error(exception: ex) { "Failed to parse StatusReport (#{msg.payload.size} bytes): #{msg.payload.hexstring}" }
      end

      private def complete_case_resumption(key : HandshakeKey) : Nil
        handshake = @case_resume_handshakes.delete(key)
        return unless handshake
        record = handshake.record
        fabric = @fabric_table.find_by_fabric_identity(record.fabric_id, record.root_public_key)
        return unless fabric && fabric.node_id == record.local_node_id

        keys = Session::Case.derive_session_keys(Crypto::StandardCrypto.new,
          record.shared_secret, handshake.initiator_random + record.resumption_id,
          Session::Case::Role::Responder, resumption: true)
        session = Session::SecureContext.new(
          session_id: handshake.responder_session_id,
          peer_session_id: handshake.initiator_session_id,
          session_type: Session::SessionType::Unicast,
          encryption_key: keys[:encryption],
          decryption_key: keys[:decryption],
          attestation_challenge: keys[:attestation_challenge],
          initiator: false,
          local_node_id: DataType::NodeId.new(fabric.node_id),
          peer_node_id: DataType::NodeId.new(record.peer_node_id),
          case_session: true,
          fabric_index: fabric.fabric_index
        )
        session.peer_subject_ids = record.peer_subject_ids.dup
        session.peer_icac = record.peer_icac.try(&.dup)
        session.bind_tcp_peer(key[0]) if key[0].port == Transport::TcpEnabledTransport::TOKEN_PORT
        if params = handshake.session_parameters
          session.peer_mrp_idle_interval_ms = params.session_idle_interval
          session.peer_mrp_active_interval_ms = params.session_active_interval
          session.peer_mrp_active_threshold_ms = params.session_active_threshold
        end
        @registry.establish_session(session)
        @sender.configure_mrp_peer(key[0], session)
        @sender.mark_mrp_peer_active(key[0], session)
        save_resumption_record(Session::Case::ResumptionStore::Record.new(
          record.fabric_id, record.root_public_key, record.local_node_id,
          record.peer_node_id, handshake.new_resumption_id, record.shared_secret,
          record.peer_subject_ids, record.peer_icac))
      end

      private def save_resumption_record(record : Session::Case::ResumptionStore::Record) : Nil
        @resumption_store.save(record)
      rescue ex : Matter::Error
        # The authenticated session is already established; a storage error
        # must not turn its successful CASE exchange into a timeout.
        Log.warn(exception: ex) { "CASE session established without a saved resumption record" }
      end

      private def send_status_report_success(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Sending StatusReport (SUCCESS) unsecured to confirm the session" }

        send_status_report(msg, peer, STATUS_REPORT_SUCCESS, STATUS_REPORT_SUCCESS)
      end

      private def send_status_report_invalid_param(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        send_status_report(msg, peer, STATUS_REPORT_FAILURE, PASE_INVALID_PARAM)
      end

      private def send_status_report(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress,
                                     general_status : UInt16, protocol_status : UInt16) : Nil
        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::StatusReport.value,
          payload: Session::Pase::Definitions::StatusReport.new(
            general_status: general_status,
            protocol_status: protocol_status
          ).to_bytes
        )
      end
    end
  end
end
