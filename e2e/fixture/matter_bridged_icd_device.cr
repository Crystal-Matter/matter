require "../../examples/support/console"
require "../../examples/support/main"

# Test-only bridge. A file in the shared E2E volume represents a check-in from
# an external intermittent device and carries the duration that device
# confirmed. The bridge never invents a wake-up or a promised duration.
module MatterBridgedIcdFixture
  alias BridgedInfo = Matter::Cluster::BridgedDeviceBasicInformation

  class Device < Matter::Device
    include Examples::Console

    @hook_active = false

    identity vendor: "Spider-Gazelle", product: "Synthetic Bridged ICD",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0571_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_bridged_icd_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
    end

    endpoint 1, device_type: Matter::DeviceType::BRIDGED_NODE do
      cluster BridgedInfo, unique_id: "synthetic-icd-1", node_label: "Synthetic ICD",
        keep_active_adapter: ->(_duration : UInt32) do
          path = ENV["MATTER_BRIDGED_ICD_HOOK_PATH"]?
          path ? File.read(path).strip.to_u32?.as(UInt32?) : nil
        end
    end

    protected def on_started : Nil
      super
      if path = ENV["MATTER_BRIDGED_ICD_HOOK_PATH"]?
        @hook_active = true
        spawn { poll_external_checkin(path) }
      end
    end

    protected def on_shutdown : Nil
      @hook_active = false
      super
    end

    private def poll_external_checkin(path : String) : Nil
      while @hook_active
        if File.exists?(path)
          info = node.get_cluster!(1_u16, BridgedInfo)
          promised = info.bridged_device_became_active
          File.delete(path)
          File.write("#{path}.ack", promised ? promised.to_s : "none")
        end
        sleep 100.milliseconds
      end
    end
  end
end

Examples.main("Synthetic Bridged ICD") { MatterBridgedIcdFixture::Device.new }
