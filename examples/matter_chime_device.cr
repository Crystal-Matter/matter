require "./support/console"
require "./support/main"

# Synthetic doorbell chime. A real host starts playback in the callback and
# returns success only when the selected sound has begun.
module MatterChime
  alias Chime = Matter::Cluster::Chime

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Doorbell Chime",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0556_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_chime_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Chime,
        sounds: [Chime::Sound.new(1_u8, "Classic"), Chime::Sound.new(2_u8, "Modern")],
        selected_chime: 1_u8
    end

    protected def before_start : Nil
      node.get_cluster!(1_u16, Chime).on_play do |_id|
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Doorbell Chime") { MatterChime::Device.new }
