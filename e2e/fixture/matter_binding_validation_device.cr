require "../../examples/support/console"
require "../../examples/support/main"

# A Binding client endpoint for official chip-tool TargetStruct write/read tests.
# This fixture does not originate commands through the configured bindings.
module MatterBindingValidationFixture
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Binding Test Switch",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ON_OFF_LIGHT_SWITCH

    storage yaml: "matter_binding_validation_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT_SWITCH do
      cluster Matter::Cluster::Identify, identify_type: :none
      cluster Matter::Cluster::Binding
    end
  end
end

Examples.main("Matter Binding Validation Fixture") do
  MatterBindingValidationFixture::Device.new(groupcast_sender: true)
end
