require "./support/console"
require "./support/main"

# Opt-in Crystal peer for the regular reverse-commissioning E2E. Its static
# test identity lets the host bind approval to attested VendorID/ProductID.
module MatterReverseTarget
  class Device < Matter::Device
    include Examples::Console

    TEST_VENDOR_ID  = 0xFFF1_u16
    TEST_PRODUCT_ID = 0x1235_u16

    identity vendor: "Spider-Gazelle", product: "Reverse Commissioning Target",
      vendor_id: TEST_VENDOR_ID,
      product_id: TEST_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ON_OFF_LIGHT,
      appearance: :satin

    storage yaml: "matter_reverse_target_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT do
      cluster Matter::Cluster::OnOff, feature_map: :lighting
    end
  end
end

Examples.main("Matter Reverse Commissioning Target") do
  MatterReverseTarget::Device.new
end
