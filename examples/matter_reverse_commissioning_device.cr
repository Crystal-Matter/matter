require "./support/console"
require "./support/main"
require "../src/matter/controller"

# Opt-in reverse-commissioning fixture for the SDK bridge or Crystal target.
# Approval is restricted to one test identity and requires explicit consent.
module MatterReverseCommissioning
  DEVICE_ENDPOINT_ID = 1_u16

  class Device < Matter::Device
    include Examples::Console

    alias Control = Matter::Cluster::CommissionerControl

    TEST_VENDOR_ID                 = 0xFFF1_u16
    TEST_BRIDGE_PRODUCT_ID         = 0x8001_u16
    TEST_DEVICE_PRODUCT_ID         = 0x1234_u16
    TEST_CRYSTAL_TARGET_PRODUCT_ID = 0x1235_u16
    SOURCE_FABRIC_ID               = 0xA100_u64
    SOURCE_CONTROLLER_ID           = 0xA101_u64
    SOURCE_BRIDGE_NODE_ID          = 0xA103_u64
    APPROVAL_DELAY                 = 100.milliseconds
    WINDOW_TIMEOUT                 =  180_u16
    ITERATIONS                     = 1000_u32
    SALT_LENGTH                    =       32
    COMMISSION_TIMEOUT             = 90.seconds
    SDK_ROOT_ENV                   = "MATTER_REVERSE_SDK_ROOT"
    SDK_PAA_CERT                   = "credentials/development/paa-root-certs/Chip-Test-PAA-FFF1-Cert.der"
    SDK_CD_CERT_GLOB               = "credentials/development/cd-certs/CSA_Matter_CD_Signing_Key_*.cert.der"

    identity vendor: "Spider-Gazelle", product: "Reverse Commissioning Aggregator",
      vendor_id: TEST_VENDOR_ID,
      product_id: TEST_DEVICE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE,
      appearance: :matte

    storage yaml: "matter_reverse_commissioning_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Control
    end

    def console_notes : Array(String)
      ["Opt-in reverse-commissioning fixture; no production approval policy"]
    end

    # The SDK example PAI chains to its VID FFF1 test PAA, and the bridge uses
    # an upstream development CD signer. Only this opt-in fixture trusts them.
    private def sdk_attestation_trust : Matter::Controller::AttestationTrustStore
      sdk_root = ENV[SDK_ROOT_ENV]? ||
                 raise Matter::ConfigurationError.new("Missing pinned SDK root for reverse commissioning attestation")
      trust = Matter::Controller::AttestationTrustStore.matter_test_fixture
      trust.paa_certificates << File.read(File.join(sdk_root, SDK_PAA_CERT)).to_slice.dup
      signer_paths = Dir.glob(File.join(sdk_root, SDK_CD_CERT_GLOB))
      raise Matter::ConfigurationError.new("No SDK development CD signers found") if signer_paths.empty?
      signer_paths.each do |path|
        signer = OpenSSL::X509::Certificate.from_der(File.read(path).to_slice)
        extension = signer.extensions.find { |entry| entry.oid == "subjectKeyIdentifier" } ||
                    raise Matter::ConfigurationError.new("SDK CD signer has no subject key identifier")
        ski = extension.value.gsub(/[^0-9A-Fa-f]/, "").upcase
        unless ski.matches?(/\A[0-9A-F]{40}\z/)
          raise Matter::ConfigurationError.new("SDK CD signer has invalid subject key identifier")
        end
        trust.cd_signers[ski] = signer.public_key.as(OpenSSL::PKey::EC).public_key_bytes
      end
      trust
    end

    private def crystal_target? : Bool
      ENV["MATTER_REVERSE_CRYSTAL_TARGET"]? == "1"
    end

    # The manual code carries only a four-bit discriminator. Many other E2E
    # devices can share it, so the opt-in Crystal fixture pins the intended
    # target address while the commissioner still verifies its attestation.
    private def crystal_target_peer : Socket::IPAddress?
      return nil unless crystal_target?
      host = ENV["MATTER_REVERSE_CRYSTAL_TARGET_HOST"]? ||
             raise Matter::ConfigurationError.new("Missing approved Crystal reverse-commissioning target host")
      Socket::Addrinfo.udp(host, Matter::Transport::UDPTransport::MATTER_PORT,
        family: Socket::Family::INET6).first.ip_address
    end

    private def prepare_crystal_source(path : String) : Nil
      return unless crystal_target?
      store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
      return if store.load.fabric
      bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
        SOURCE_FABRIC_ID, SOURCE_CONTROLLER_ID, TEST_VENDOR_ID)
      store.save(Matter::Controller::State.new(fabric: bootstrap.fabric,
        commissioner_node_id: SOURCE_CONTROLLER_ID))
    end

    private def publish_test_window(window : Control::ReverseOpenCommissioningWindowResponse) : Nil
      return unless crystal_target?
      path = ENV["MATTER_REVERSE_WINDOW_PATH"]? ||
             raise Matter::ConfigurationError.new("Missing Crystal reverse-window handoff path")
      File.write(path, {
        "commissioning_timeout" => window.commissioning_timeout.to_i64,
        "verifier"              => window.pake_passcode_verifier.hexstring,
        "discriminator"         => window.discriminator.to_i64,
        "iterations"            => window.iterations.to_i64,
        "salt"                  => window.salt.hexstring,
      }.to_json)
    end

    protected def before_start : Nil
      state_path = ENV["MATTER_REVERSE_CONTROLLER_STATE"]? ||
                   raise Matter::ConfigurationError.new("Missing reverse-commissioning controller state")
      prepare_crystal_source(state_path)
      consent = ENV["MATTER_REVERSE_TEST_CONSENT"]? == "1"
      expected_product = crystal_target? ? TEST_CRYSTAL_TARGET_PRODUCT_ID : TEST_BRIDGE_PRODUCT_ID
      control = node.endpoint!(DEVICE_ENDPOINT_ID).get_cluster!(Control)
      control.configure_host(
        ->(approval : Control::ApprovalRequest) do
          spawn do
            sleep APPROVAL_DELAY
            approved = consent && approval.vendor_id == TEST_VENDOR_ID &&
                       approval.product_id == expected_product
            status = approved ? Matter::InteractionModel::StatusCode::Success : Matter::InteractionModel::StatusCode::Failure
            control.resolve_approval(approval, status)
            puts "Reverse commissioning approval #{approved ? "granted" : "denied"}: request=#{approval.request_id} VID=0x#{approval.vendor_id.to_s(16)} PID=0x#{approval.product_id.to_s(16)}"
          end
          nil
        end,
        ->(approval : Control::ApprovalRequest, _request : Control::CommissionNodeRequest) do
          pin = Matter::SetupPayload.generate_random_pin
          discriminator = Matter::SetupPayload.generate_random_discriminator
          salt = Random::Secure.random_bytes(SALT_LENGTH)
          pbkdf = Matter::Crypto::Spake2p::PbkdfParameters.new(ITERATIONS.to_i32, salt)
          verifier = Matter::Crypto::Spake2p.compute_passcode_verifier(
            Matter::Crypto::StandardCrypto.new, pbkdf, pin)
          window = Control::ReverseOpenCommissioningWindowResponse.new(
            WINDOW_TIMEOUT, verifier, discriminator, ITERATIONS, salt)
          publish_test_window(window)
          task = -> do
            puts "Reverse commissioning response sent: request=#{approval.request_id}"
            client = Matter::Controller::Client.new
            begin
              store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(state_path))
              commissioner = Matter::Controller::Commissioning::Commissioner.new(store, client,
                timeout: COMMISSION_TIMEOUT,
                attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
                  crystal_target? ? Matter::Controller::AttestationTrustStore.matter_test_fixture : sdk_attestation_trust))
              code = Matter::SetupPayload.generate_manual_code(discriminator, pin)
              commissioner.pairing_code(SOURCE_BRIDGE_NODE_ID, code, peer: crystal_target_peer,
                expected_identity: {approval.vendor_id, approval.product_id})
              puts "Reverse commissioning complete: request=#{approval.request_id} node=#{SOURCE_BRIDGE_NODE_ID}"
            ensure
              client.close
            end
          end
          Control::PreparedWindow.new(window, task).as(Control::PreparedWindow?)
        end
      )
      super
    end
  end
end

Examples.main("Matter Reverse Commissioning Aggregator") do
  ip_addresses = ENV["MATTER_REVERSE_IP_ADDRESS"]?.try do |address|
    [Socket::IPAddress.new(address, Matter::Network::UNSPECIFIED_PORT)]
  end
  MatterReverseCommissioning::Device.new(
    ip_addresses: ip_addresses,
    port: ENV["MATTER_REVERSE_PORT"]?.try(&.to_i?) || 5540)
end
