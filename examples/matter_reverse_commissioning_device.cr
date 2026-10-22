require "./support/console"
require "./support/main"
require "../src/matter/controller"

# Opt-in SDK v1.6 reverse-commissioning fixture. Approval is restricted to the
# test bridge identity and requires explicit local consent from the harness.
module MatterReverseCommissioning
  class Device < Matter::Device
    include Examples::Console

    alias Control = Matter::Cluster::CommissionerControl

    TEST_VENDOR_ID         = 0xFFF1_u16
    TEST_BRIDGE_PRODUCT_ID = 0x8001_u16
    TEST_DEVICE_PRODUCT_ID = 0x1234_u16
    SOURCE_BRIDGE_NODE_ID  = 0xA103_u64
    APPROVAL_DELAY         = 100.milliseconds
    WINDOW_TIMEOUT         =  180_u16
    ITERATIONS             = 1000_u32
    SALT_LENGTH            =       32
    COMMISSION_TIMEOUT     = 90.seconds

    identity vendor: "Spider-Gazelle", product: "Reverse Commissioning Aggregator",
      vendor_id: TEST_VENDOR_ID,
      product_id: TEST_DEVICE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE,
      appearance: :matte

    storage yaml: "matter_reverse_commissioning_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Control
    end

    def console_notes : Array(String)
      ["Opt-in SDK reverse-commissioning fixture; no production approval policy"]
    end

    protected def before_start : Nil
      state_path = ENV["MATTER_REVERSE_CONTROLLER_STATE"]? ||
                   raise Matter::ConfigurationError.new("Missing reverse-commissioning controller state")
      consent = ENV["MATTER_REVERSE_TEST_CONSENT"]? == "1"
      control = node.endpoint!(1_u16).get_cluster!(Control)
      control.configure_host(
        ->(approval : Control::ApprovalRequest) do
          spawn do
            sleep APPROVAL_DELAY
            approved = consent && approval.vendor_id == TEST_VENDOR_ID &&
                       approval.product_id == TEST_BRIDGE_PRODUCT_ID
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
          task = -> do
            puts "Reverse commissioning response sent: request=#{approval.request_id}"
            client = Matter::Controller::Client.new
            begin
              store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(state_path))
              commissioner = Matter::Controller::Commissioning::Commissioner.new(store, client,
                timeout: COMMISSION_TIMEOUT,
                attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
                  Matter::Controller::AttestationTrustStore.matter_test_fixture))
              code = Matter::SetupPayload.generate_manual_code(discriminator, pin)
              commissioner.pairing_code(SOURCE_BRIDGE_NODE_ID, code,
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
