require "./support/console"
require "./support/main"

# Synthetic host-backed Low Power fixture. The counter records a physical
# transition only after its Sleep command response is transmitted.
module MatterLowPower
  DEVICE_ENDPOINT_ID = 1_u16

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Low Power",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_low_power_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::LowPower
      cluster Matter::Cluster::Identify
    end

    @sleep_requests = 0

    protected def before_start : Nil
      if cleanup_path = ENV["MATTER_LOW_POWER_REQUEST_PATH"]?
        File.delete(cleanup_path) if File.exists?(cleanup_path)
      end
      node.get_cluster!(DEVICE_ENDPOINT_ID, Matter::Cluster::LowPower).configure_host(
        -> { Matter::InteractionModel::Status.success },
        -> do
          @sleep_requests += 1
          if acknowledgement_path = ENV["MATTER_LOW_POWER_REQUEST_PATH"]?
            File.write(acknowledgement_path, @sleep_requests.to_s)
          end
          nil
        end)
      super
    end
  end
end

Examples.main("Crystal Low Power") { MatterLowPower::Device.new }
