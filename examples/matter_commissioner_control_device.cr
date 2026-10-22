require "./support/console"
require "./support/main"

# Opt-in interoperability fixture. The reverse window parameters are synthetic:
# there is no target node or actual reverse commissioning behind this example.
module MatterCommissionerControl
  class Device < Matter::Device
    include Examples::Console

    alias Control = Matter::Cluster::CommissionerControl

    TEST_VENDOR_ID  = 0xFFF1_u16
    TEST_PRODUCT_ID = 0x1234_u16
    APPROVAL_DELAY  = 100.milliseconds

    identity vendor: "Spider-Gazelle", product: "Synthetic Commissioner Control",
      vendor_id: TEST_VENDOR_ID,
      product_id: TEST_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE,
      appearance: :matte

    storage yaml: "matter_commissioner_control_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Control
    end

    def console_notes : Array(String)
      ["Synthetic Commissioner Control Aggregator for E2E only"]
    end

    protected def before_start : Nil
      control = node.get_cluster(Control) || raise Matter::ConfigurationError.new("Commissioner Control fixture is missing its root cluster")
      control.configure_host(
        ->(approval : Control::ApprovalRequest) do
          spawn do
            # Let the InvokeResponse leave before the result event is emitted.
            sleep APPROVAL_DELAY
            result = if approval.vendor_id == TEST_VENDOR_ID && approval.product_id == TEST_PRODUCT_ID
                       Matter::InteractionModel::StatusCode::Success
                     else
                       Matter::InteractionModel::StatusCode::Failure
                     end
            control.resolve_approval(approval, result)
          end
          nil
        end,
        ->(_approval : Control::ApprovalRequest, _request : Control::CommissionNodeRequest) do
          response = Control::ReverseOpenCommissioningWindowResponse.new(
            180_u16, Bytes.new(97, 0_u8), 3840_u16, 1000_u32, Bytes.new(16, 0_u8)
          )
          Control::PreparedWindow.new(response, -> { nil }).as(Control::PreparedWindow?)
        end
      )
      super
    end
  end
end

Examples.main("Synthetic Commissioner Control Aggregator") do
  MatterCommissionerControl::Device.new
end
