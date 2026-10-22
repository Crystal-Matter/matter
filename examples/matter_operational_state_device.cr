require "./support/console"
require "./support/main"

# Synthetic wire fixture for the generic cluster. Aggregator is used only as a
# test container; this fixture is not an appliance device-type claim.
module MatterOperationalState
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Operational State",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_operational_state_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::OperationalState,
        supported_commands: Matter::Cluster::OperationalState::Command.values,
        phase_list: ["wash", "rinse"], current_phase: 0_u8, countdown_time: 120_u32
    end

    protected def before_start : Nil
      state = node.endpoint!(1_u16).get_cluster!(Matter::Cluster::OperationalState)
      state.on_command do |_command|
        Matter::Cluster::OperationalState::ErrorState.new(Matter::Cluster::OperationalState::NO_ERROR)
      end
      super
    end
  end
end

Examples.main("Synthetic Operational State") { MatterOperationalState::Device.new }
