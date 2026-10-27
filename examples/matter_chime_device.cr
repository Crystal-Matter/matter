require "./support/console"
require "./support/main"

# Synthetic doorbell chime. A real host starts playback in the callback and
# returns success only when the selected sound has begun.
module MatterChime
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x0556_u16

  alias Chime = Matter::Cluster::Chime

  SOUNDS = [Chime::Sound.new(1_u8, "Classic"), Chime::Sound.new(2_u8, "Modern")]

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Doorbell Chime",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_chime_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Chime,
        sounds: SOUNDS,
        selected_chime: SOUNDS.first.chime_id
    end

    protected def before_start : Nil
      node.get_cluster!(DEVICE_ENDPOINT_ID, Chime).on_play do |_id|
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Doorbell Chime") { MatterChime::Device.new }
