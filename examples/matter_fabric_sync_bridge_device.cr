require "./support/console"
require "./support/main"
require "../src/matter/controller"

# An opt-in bridge to an actual Matter switch. The bridge controller identity
# and verified target binding are provisioned separately by the host. Each
# command needs a fresh, one-use consent file supplied by the local operator.
module MatterFabricSyncBridge
  TARGET_ENDPOINT_ID     =      1_u16
  TARGET_FABRIC_INDEX    =       1_u8
  TARGET_NODE_ID         = 0xB801_u64
  CONTROLLER_STATE_ENV   = "MATTER_FABRIC_SYNC_CONTROLLER_STATE"
  CONSENT_PATH_ENV       = "MATTER_FABRIC_SYNC_CONSENT_PATH"
  CONSENT_REQUEST_SUFFIX = ".request"
  STATUS_POLL_INTERVAL   = 30.seconds

  class Device < Matter::Device
    include Examples::Console

    alias BridgeCluster = Matter::Cluster::BridgedAdministratorCommissioning
    alias Host = Matter::Controller::BridgedCommissioningHost

    @host : Host? = nil

    identity vendor: "Spider-Gazelle", product: "Fabric Sync Bridge",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_fabric_sync_bridge_storage.yml"

    endpoint Matter::Node::ROOT_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR

    endpoint TARGET_ENDPOINT_ID,
      device_type: [Matter::DeviceType::ON_OFF_LIGHT, Matter::DeviceType::BRIDGED_NODE] do
      cluster Matter::Cluster::OnOff
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::BridgedDeviceBasicInformation,
        product_name: "Remote Matter Switch", unique_id: "fabric-sync-switch"
      cluster Matter::Cluster::EcosystemInformation
      cluster BridgeCluster, TARGET_FABRIC_INDEX, TARGET_NODE_ID,
        ->(target_fabric : UInt8, target_node : UInt64, caller_fabric : UInt8, caller_node : UInt64, request : Matter::Cluster::AdministratorCommissioning::OpenCommissioningWindowRequest) do
          host.open(target_fabric, target_node, caller_fabric, caller_node, request)
        end,
        ->(target_fabric : UInt8, target_node : UInt64, caller_fabric : UInt8, caller_node : UInt64) do
          host.revoke(target_fabric, target_node, caller_fabric, caller_node)
        end,
        as: :bridged_administrator_commissioning
    end

    def console_notes : Array(String)
      ["Opt-in real Matter target bridge; each command requires local consent"]
    end

    private def host : Host
      @host ||= begin
        state_path = ENV[CONTROLLER_STATE_ENV]? ||
                     raise Matter::ConfigurationError.new("Missing fabric-sync controller state path")
        consent_path = ENV[CONSENT_PATH_ENV]? ||
                       raise Matter::ConfigurationError.new("Missing fabric-sync consent path")
        caller_fabric = ->(index : UInt8) do
          fabric_table.get_fabric(index).try { |fabric| {fabric.fabric_id, fabric.root_public_key} }
        end
        consent = ->(caller : Host::CallerIdentity, target_node : UInt64, operation : Symbol) do
          expected = caller.consent_token(target_node, operation)
          approved = File.exists?(consent_path) && File.read(consent_path).strip == expected
          if approved
            File.delete?(consent_path)
            File.delete?(consent_path + CONSENT_REQUEST_SUFFIX)
          else
            File.write(consent_path + CONSENT_REQUEST_SUFFIX, expected)
          end
          approved
        end
        Host.new(Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(state_path)),
          bridged_administrator_commissioning, caller_fabric, consent)
      end
    end

    protected def on_started : Nil
      super
      spawn { refresh_remote_window }
      every(STATUS_POLL_INTERVAL) { refresh_remote_window }
    end

    private def refresh_remote_window : Nil
      configured = host
      message_handler.registry.synchronize { configured.refresh } if configured.bound?
    rescue ex
      ::Log.for("matter.fabric_sync_bridge").warn(exception: ex) { "Could not observe bridged target window" }
    end
  end
end

Examples.main("Fabric Sync Bridge") { MatterFabricSyncBridge::Device.new }
