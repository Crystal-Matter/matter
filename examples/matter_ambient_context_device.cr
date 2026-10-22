require "./support/console"
require "./support/main"

# Synthetic Matter 1.6 Ambient Context Sensing fixture. A host supplies
# classified observations; the test hook is enabled only when explicitly set.
module MatterAmbientContext
  class Device < Matter::Device
    include Examples::Console

    alias Ambient = Matter::Cluster::AmbientContextSensing

    @hook_active = false

    identity vendor: "Spider-Gazelle", product: "Synthetic Ambient Context",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_ambient_context_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Ambient,
        supported_activity_tags: [
          Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown),
          Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking),
        ],
        hold_time: 30_u16,
        as: :ambient
    end

    protected def on_started : Nil
      super
      if path = ENV["MATTER_AMBIENT_CONTEXT_HOOK_PATH"]?
        @hook_active = true
        spawn { poll_hook(path) }
      end
    end

    protected def on_shutdown : Nil
      @hook_active = false
      super
    end

    private def poll_hook(path : String) : Nil
      while @hook_active
        if File.exists?(path)
          nonce = File.read(path).strip
          File.delete(path)
          if nonce.starts_with?("walking:")
            ambient.observe_human_activity(Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking))
            File.write("#{path}.ack", nonce)
          end
        end
        sleep 100.milliseconds
      end
    end
  end
end

Examples.main("Synthetic Ambient Context Sensor") { MatterAmbientContext::Device.new }
