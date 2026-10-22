require "./support/console"
require "./support/main"

# Synthetic media navigation fixture. An actual media product should advertise
# its device type and related media clusters, and perform navigation in the
# callback before returning Success.
module MatterTargetNavigator
  alias Navigator = Matter::Cluster::TargetNavigator

  class Device < Matter::Device
    include Examples::Console

    TARGETS = [Navigator::TargetInfo.new(1_u8, "Home"),
               Navigator::TargetInfo.new(2_u8, "Settings")]

    identity vendor: "Spider-Gazelle", product: "Synthetic Target Navigator",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_target_navigator_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Navigator, target_list: TARGETS, current_target: 1_u8
    end

    protected def before_start : Nil
      node.get_cluster!(1_u16, Navigator).on_navigate do |_target, data|
        if data == "deny"
          Navigator::NavigationResult.new(Navigator::Status::NotAllowed)
        else
          Navigator::NavigationResult.new(Navigator::Status::Success, "ready")
        end
      end
      super
    end
  end
end

Examples.main("Synthetic Target Navigator") { MatterTargetNavigator::Device.new }
