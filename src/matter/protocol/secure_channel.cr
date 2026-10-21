require "log"
require "socket"

require "../codec/message_codec"
require "../fabric_table"
require "../session/case/case"
require "../session/case/definitions"
require "../session/context"
require "../session/pase/pase"
require "./message_type"
require "./response_sender"
require "./session_registry"

module Matter
  module Protocol
    # The PASE and CASE handshakes, and the PASE parameters a commissioning
    # window configures.
    #
    # Handshake state is keyed by exchange id: two commissioners talking to the
    # node at once each get their own responder, and an abandoned handshake is
    # forgotten rather than reused by whoever sends the next Sigma3.
    class SecureChannel
      Log = ::Log.for("matter.protocol.secure_channel")

      # How long an incomplete handshake is kept before it is discarded.
      HANDSHAKE_TIMEOUT = 60.seconds

      # SPAKE2+ context prefix (Matter spec 3.10).
      SPAKE_CONTEXT = "CHIP PAKE V1 Commissioning"

      # Length of the random values exchanged during PBKDF parameter discovery.
      RANDOM_LENGTH = 32

      # StatusReport general/protocol code for success (Matter spec 4.10.1.5).
      STATUS_REPORT_SUCCESS = 0_u16

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

        def initialize(@responder, @initiator_session_id, @responder_session_id)
          super()
        end
      end

      # A CASE handshake between Sigma1 and Sigma3.
      private class CaseHandshake < Handshake
        getter responder : Session::Case::CaseResponder
        getter fabric : Fabric
        getter initiator_session_id : UInt16
        getter responder_session_id : UInt16

        def initialize(@responder, @fabric, @initiator_session_id, @responder_session_id)
          super()
        end
      end

      @pase_handshakes : Hash(UInt16, PaseHandshake) = {} of UInt16 => PaseHandshake
      @case_handshakes : Hash(UInt16, CaseHandshake) = {} of UInt16 => CaseHandshake

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

      @default_setup_pin : UInt32
      @default_iterations : UInt32
      @default_salt : Bytes

      def initialize(
        @fabric_table : FabricTable,
        @registry : SessionRegistry,
        @sender : ResponseSender,
        @setup_pin : UInt32,
        @iterations : UInt32,
        @salt : Bytes,
      )
        @default_setup_pin = @setup_pin
        @default_iterations = @iterations
        @default_salt = @salt.dup
        @passcode_verifier = nil
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
        @pase_handshakes.size + @case_handshakes.size
      end

      # Forgets handshakes a commissioner started and walked away from. Runs on
      # every handshake message.
      def prune_expired_handshakes(now : Time::Instant = Time.instant) : Nil
        @pase_handshakes.reject! { |_, handshake| handshake.expired?(now) }
        @case_handshakes.reject! { |_, handshake| handshake.expired?(now) }
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
        request = Session::Pase::Definitions::PbkdfParamRequest.from_slice(request_payload)

        initiator_session_id = request.initiator_session_id
        unless initiator_session_id
          Log.error { "PBKDFParamRequest missing initiator session id" }
          return
        end

        initiator_random = request.initiator_random
        unless initiator_random
          Log.error { "PBKDFParamRequest missing initiator_random" }
          return
        end
        Log.debug { "  Initiator session ID: #{initiator_session_id}, random: #{initiator_random.size} bytes" }

        responder_session_id = Random::Secure.rand(UInt16)
        response_payload = Session::Pase::Definitions::PbkdfParamResponse.new(
          initiator_random: initiator_random,
          responder_random: Random::Secure.random_bytes(RANDOM_LENGTH),
          responder_session_id: responder_session_id,
          iterations: @iterations,
          salt: @salt
        ).to_slice
        Log.debug { "PBKDF Response payload (#{response_payload.size} bytes): #{response_payload.hexstring}" }

        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::PbkdfParamResponse.value,
          payload: response_payload
        )
        Log.info { "Sent PBKDFParamResponse with session ID: #{responder_session_id}" }

        @pase_handshakes[msg.payload_header.exchange_id] = PaseHandshake.new(
          responder: build_pase_responder(spake_context_hash(request_payload, response_payload)),
          initiator_session_id: initiator_session_id,
          responder_session_id: responder_session_id
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

        handshake = @pase_handshakes[msg.payload_header.exchange_id]?
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
        handshake = @pase_handshakes[exchange_id]?
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
          @pase_handshakes.delete(exchange_id)
          return
        end
        Log.debug { "PASE confirmation successful" }

        keys = handshake.responder.derive_session_keys
        Log.trace { "  Encryption key (R2I): #{keys[:encryption].hexstring}" }
        Log.trace { "  Decryption key (I2R): #{keys[:decryption].hexstring}" }
        Log.trace { "  Attestation challenge: #{keys[:attestation_challenge].hexstring}" }

        @registry.establish_session(Session::SecureContext.new(
          session_id: handshake.responder_session_id,
          peer_session_id: handshake.initiator_session_id,
          session_type: Session::SessionType::Unicast,
          encryption_key: keys[:encryption],
          decryption_key: keys[:decryption],
          attestation_challenge: keys[:attestation_challenge],
          initiator: false
        ))
        @pase_handshakes.delete(exchange_id)

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
        Log.info { "  Initiator session ID: #{sigma1.initiator_session_id}" }
        Log.debug { "  Destination ID: #{sigma1.destination_id.hexstring}" }

        fabric = find_fabric(sigma1)
        unless fabric
          Log.error { "No fabric found matching destination_id: #{sigma1.destination_id.hexstring}" }
          Log.error { "Device may not be commissioned or destination_id computation differs" }
          return
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
          ipk: fabric.derived_ipk, # Derived with the "GroupKey v1.0" info string
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
          sigma1_bytes: msg.payload
        )

        @case_handshakes[msg.payload_header.exchange_id] = CaseHandshake.new(
          responder: responder,
          fabric: fabric,
          initiator_session_id: sigma1.initiator_session_id,
          responder_session_id: sigma2_data[:session_id]
        )

        Log.info { "  Generated Sigma2 response (responder session ID: #{sigma2_data[:session_id]})" }

        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::CaseSigma2.value,
          payload: Session::Case::Definitions::Sigma2.new(
            responder_random: sigma2_data[:random],
            responder_session_id: sigma2_data[:session_id],
            responder_eph_pub_key: sigma2_data[:ephemeral_public_key],
            encrypted2: sigma2_data[:encrypted_cert]
          ).to_slice
        )
        Log.info { "Sent CASE Sigma2" }
      rescue ex
        Log.error(exception: ex) do
          "Error handling CASE Sigma1: peer=#{peer.address}:#{peer.port} session_id=#{msg.packet_header.session_id} " \
          "msg_id=#{msg.packet_header.message_id} exchange=#{msg.payload_header.exchange_id} payload_hex=#{msg.payload.hexstring}"
        end
      end

      # The fabric whose destination id matches the one the initiator computed
      # as HMAC-SHA256(IPK, initiatorRandom || rootPublicKey || fabricId || nodeId).
      private def find_fabric(sigma1 : Session::Case::Definitions::Sigma1) : Fabric?
        Log.debug { "Searching #{@fabric_table.size} fabrics for destination_id match" } if @fabric_table.size > 0

        matched = @fabric_table.all_fabrics.find do |fabric|
          fabric.compute_destination_id(sigma1.initiator_random) == sigma1.destination_id
        end

        if matched
          Log.info { "  Matched fabric by destination_id: #{matched.fabric_id.to_s(16)}" }
          return matched
        end

        fabric = @on_get_fabric.try(&.call)
        return unless fabric

        # The callback bypasses destination id matching; say so rather than
        # silently commissioning against the wrong fabric.
        if fabric.compute_destination_id(sigma1.initiator_random) != sigma1.destination_id
          Log.warn { "Fabric from callback doesn't match destination_id" }
        end
        fabric
      end

      # Sigma3: verify the initiator's certificate and open the session.
      private def handle_case_sigma3(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Handling CASE Sigma3" }

        exchange_id = msg.payload_header.exchange_id
        handshake = @case_handshakes[exchange_id]?
        unless handshake
          Log.error { "CASE responder not initialized - Sigma1 must come first (exchange=#{exchange_id})" }
          return
        end

        sigma3 = Session::Case::Definitions::Sigma3.from_slice(msg.payload)
        Log.debug { "  Encrypted cert: #{sigma3.encrypted3.size} bytes" }

        responder = handshake.responder
        unless responder.process_sigma3(sigma3.encrypted3, msg.payload)
          Log.error { "CASE Sigma3 verification failed" }
          @case_handshakes.delete(exchange_id)
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

        @registry.establish_session(session)
        @case_handshakes.delete(exchange_id)

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
          Log.debug { "StatusReport: SUCCESS (peer=#{peer})" }
          return
        end

        Log.warn { "StatusReport: general=#{Hex.u16(general)}, protocol=#{Hex.u16(protocol)} (peer=#{peer})" }
        return if general == STATUS_REPORT_SUCCESS

        if @case_handshakes.has_key?(msg.payload_header.exchange_id)
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

      private def send_status_report_success(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        Log.info { "Sending StatusReport (SUCCESS) unsecured to confirm the session" }

        @sender.send_secure_channel_response(
          original_msg: msg,
          peer: peer,
          message_type: SecureChannelMessageType::StatusReport.value,
          payload: Session::Pase::Definitions::StatusReport.new(
            general_status: STATUS_REPORT_SUCCESS,
            protocol_status: STATUS_REPORT_SUCCESS
          ).to_bytes
        )
      end
    end
  end
end
