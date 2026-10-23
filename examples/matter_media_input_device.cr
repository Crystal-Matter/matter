require "./support/console"
require "./support/main"

# Synthetic input selector. A real media host routes the chosen source and
# presents input-status overlays via the callbacks.
module MatterMediaInput
  alias Input = Matter::Cluster::MediaInput

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Media Input",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_media_input_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Input,
        feature_map: Input::Feature::NameUpdates,
        input_list: [
          Input::InputInfo.new(1_u8, Input::InputType::Hdmi, "HDMI 1", "Game console"),
          Input::InputInfo.new(2_u8, Input::InputType::Hdmi, "HDMI 2", "Streaming box"),
        ],
        current_input: 1_u8
    end

    protected def before_start : Nil
      input = node.get_cluster!(1_u16, Input)
      input.on_select_input { |_index| Matter::InteractionModel::Status.success }
      input.on_input_status { |_visible| Matter::InteractionModel::Status.success }
      super
    end
  end
end

Examples.main("Synthetic Media Input") { MatterMediaInput::Device.new }
