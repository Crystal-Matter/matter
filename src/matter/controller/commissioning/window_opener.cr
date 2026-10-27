require "../../node"
require "../im_client"
require "../../setup_payload"
require "../../crypto/spake2p"
require "../../cluster/administrator_commissioning"

module Matter
  module Controller
    module Commissioning
      class CommissioningWindowOpener
        record EnhancedWindow, pin : UInt32, discriminator : UInt16, iterations : UInt32, salt : Bytes, verifier : Bytes do
          def manual_pairing_code : String
            SetupPayload.generate_manual_code(discriminator, pin)
          end
        end

        def initialize(@crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        end

        # Opens an Enhanced commissioning window and returns the ephemeral pairing data (PIN + discriminator).
        #
        # This is the controller-side equivalent of CHIP's CommissioningWindowOpener for the "token with random PIN" option.
        def open_enhanced(
          im : ImClient,
          session : Session::SecureContext,
          peer : Socket::IPAddress,
          timeout_seconds : UInt16,
          iterations : UInt32,
          discriminator : UInt16,
          pin : UInt32 = SetupPayload.generate_random_pin,
          salt : Bytes = Random::Secure.random_bytes(32),
        ) : EnhancedWindow
          pbkdf = Crypto::Spake2p::PbkdfParameters.new(iterations.to_i32, salt)
          verifier = Crypto::Spake2p.compute_passcode_verifier(@crypto, pbkdf, pin)

          request = Cluster::AdministratorCommissioning::OpenCommissioningWindowRequest.new(
            commissioning_timeout: timeout_seconds,
            pake_passcode_verifier: verifier,
            discriminator: discriminator,
            iterations: iterations,
            salt: salt
          )

          resp = im.invoke(
            session: session,
            peer: peer,
            endpoint_id: Node::ROOT_ENDPOINT_ID,
            cluster_id: Cluster::AdministratorCommissioning::CLUSTER_ID,
            command_id: Cluster::AdministratorCommissioning::CMD_OPEN_COMMISSIONING_WINDOW,
            fields: request.to_slice,
            timed_request: true
          )

          # The command uses a status-only InvokeResponse.
          if status = resp.invoke_responses.first?.try(&.command_status).try(&.status)
            unless status.status == InteractionModel::StatusCode::Success.value
              raise Matter::CommissioningError.new("OpenCommissioningWindow failed (status=#{status.status})")
            end
          end

          EnhancedWindow.new(pin, discriminator, iterations, salt, verifier)
        end
      end
    end
  end
end
