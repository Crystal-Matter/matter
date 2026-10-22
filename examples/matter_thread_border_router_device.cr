require "./support/console"
require "./support/main"

# Synthetic wire fixture. It does not provide a radio, an OpenThread stack,
# or the Border Router device type; real hosts must implement Backend.
module MatterThreadBorderRouter
  alias Router = Matter::Cluster::ThreadBorderRouterManagement

  class MemoryBackend < Router::Backend
    @active : Bytes? = nil
    @pending : Bytes? = nil
    @enabled = false

    def border_router_name : String
      "Crystal synthetic router"
    end

    def border_agent_id : Bytes
      Bytes.new(16, 0xa5_u8)
    end

    def thread_version : UInt16
      4_u16
    end

    def interface_enabled? : Bool
      @enabled
    end

    def active_dataset : Bytes?
      @active.try(&.dup)
    end

    def pending_dataset : Bytes?
      @pending.try(&.dup)
    end

    # This synthetic backend has no radio-specific constraints. The cluster
    # still checks required TLVs and lengths; physical hosts use their stack.
    def valid_dataset?(dataset : Bytes, pending : Bool) : Bool
      true
    end

    def activate_active_dataset(dataset : Bytes, deadline : Time::Span) : Bool
      return false unless deadline > Time::Span.zero
      @active = dataset.dup
      @enabled = true
      true
    end

    def apply_pending_dataset(dataset : Bytes) : Bool
      @pending = dataset.dup
      true
    end

    def restore(active : Bytes?, pending : Bytes?, interface_enabled : Bool) : Nil
      @active = active.try(&.dup)
      @pending = pending.try(&.dup)
      @enabled = interface_enabled
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Thread Border Router",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_thread_border_router_storage.yml"

    protected def before_start : Nil
      return super if node.has_endpoint?(1_u16)
      commissioning = node.get_cluster(Matter::Cluster::GeneralCommissioning) ||
                      raise Matter::ConfigurationError.new("General Commissioning is missing")
      router = Router.new(Matter::DataType::EndpointNumber.new(1_u16),
        MemoryBackend.new, commissioning, feature_map: Router::Feature::PanChange)
      add_endpoint(1_u16, Matter::DeviceType::AGGREGATOR, [router.as(Matter::Cluster::Base)])
      super
    end
  end
end

Examples.main("Synthetic Thread Border Router") { MatterThreadBorderRouter::Device.new }
