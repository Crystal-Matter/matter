require "./support/console"
require "./support/main"

# Synthetic command-response fixture. A real media application installs a
# callback that forwards accepted key presses to its UI and can reject keys
# that are unavailable in its current state.
module MatterKeypadInput
  alias Keypad = Matter::Cluster::KeypadInput

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Keypad Input",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_keypad_input_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Keypad,
        feature_map: Keypad::Feature::NavigationKeyCodes |
                     Keypad::Feature::LocationKeys |
                     Keypad::Feature::NumberKeys,
        supported_keys: Keypad::CecKeyCode.values.reject(&.reserved?)
    end

    protected def before_start : Nil
      keypad = node.get_cluster!(1_u16, Keypad)
      keypad.on_send_key do |key|
        # Demonstrate a host rejection while still replying with a typed
        # SendKeyResponse, as required by the cluster protocol.
        key.power? ? Keypad::Status::InvalidKeyInCurrentState : Keypad::Status::Success
      end
      keypad.on_key_action do |key, action, fabric|
        puts "Keypad #{action}: #{key} on fabric #{fabric || "local"}"
      end
      super
    end
  end
end

Examples.main("Synthetic Keypad Input") { MatterKeypadInput::Device.new }
