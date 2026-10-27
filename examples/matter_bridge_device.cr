require "./support/console"
require "./support/main"

# Matter Bridge Device Example
#
# - Presents the root endpoint as an Aggregator and bridges non-Matter On/Off
#   devices on endpoints 1, 2, 3, ...
# - Bridged endpoints are declared once as an `endpoint_template` and added or
#   removed at runtime; the library persists their parameters, so they come
#   back after a restart
# - Each bridged endpoint is a Bridged Node + On/Off Light, with
#   BridgedDeviceBasicInformation, OnOff, Identify and Groups
module MatterBridge
  class Device < Matter::Device
    include Examples::Console

    BRIDGED_VENDOR_NAME            = "Bridged Vendor"
    BRIDGED_HARDWARE_VERSION       = 1_u16
    BRIDGED_HARDWARE_VERSION_LABEL = "1.0"
    BRIDGED_SOFTWARE_VERSION       = 1_u32
    BRIDGED_SOFTWARE_VERSION_LABEL = "1.0.0"

    # How many lights a bridge with no stored devices starts with.
    INITIAL_DEVICES = 1..2

    # Random bytes behind a bridged device's unique id.
    UNIQUE_ID_BYTES = 4

    ALL_LIGHTS_ACTION_ID        = 1_u16
    ALL_LIGHTS_ENDPOINT_LIST_ID = 1_u16

    identity vendor: "Spider-Gazelle", product: "Crystal Bridge",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE,
      appearance: :matte

    storage yaml: "matter_bridge_storage.yml"

    # The bridge has no static endpoints of its own: the root endpoint is the
    # aggregator its bridged endpoints hang off.
    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::Actions
    end

    endpoint_template :bridged_light,
      device_type: [Matter::DeviceType::ON_OFF_LIGHT, Matter::DeviceType::BRIDGED_NODE],
      parameters: {name: String, unique_id: String} do
      cluster Matter::Cluster::OnOff
      cluster Matter::Cluster::BridgedDeviceBasicInformation,
        vendor_name: BRIDGED_VENDOR_NAME,
        product_name: name,
        node_label: name,
        unique_id: unique_id,
        hardware_version: BRIDGED_HARDWARE_VERSION,
        hardware_version_string: BRIDGED_HARDWARE_VERSION_LABEL,
        software_version: BRIDGED_SOFTWARE_VERSION,
        software_version_string: BRIDGED_SOFTWARE_VERSION_LABEL
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      # Groups is a mandatory server cluster of the On/Off Light device type
      # (Matter Device Library 4.1, On/Off Light), so every bridged endpoint
      # carries one.
      cluster Matter::Cluster::Groups
    end

    def console_notes : Array(String)
      ["Bridges non-Matter On/Off devices to Matter"]
    end

    def state_details : Nil
      puts "  Bridged Devices: #{bridged_endpoints.size}"
      list_devices
    end

    def status_details : Nil
      puts "  Bridged Devices: #{bridged_endpoints.size}"
      list_devices
    end

    def commands : Array(Tuple(String, String))
      [
        {"add", "Add a new bridged On/Off device"},
        {"remove <n>", "Remove the bridged device on endpoint n"},
        {"list", "List all bridged devices with their states"},
        {"toggle <n>", "Toggle the device on endpoint n"},
        {"on <n>", "Turn on the device on endpoint n"},
        {"off <n>", "Turn off the device on endpoint n"},
        {"reachable <n>", "Toggle reachability of the device on endpoint n"},
      ]
    end

    def handle_command(name : String, argument : String?) : Bool
      case name
      when "add"       then add_bridged_device
      when "list"      then list_devices
      when "remove"    then with_endpoint(argument) { |endpoint| remove_bridged_device(endpoint) }
      when "toggle"    then with_endpoint(argument) { |endpoint| on_off(endpoint).toggle }
      when "on"        then with_endpoint(argument) { |endpoint| on_off(endpoint).on = true }
      when "off"       then with_endpoint(argument) { |endpoint| on_off(endpoint).on = false }
      when "reachable" then with_endpoint(argument) { |endpoint| toggle_reachable(endpoint) }
      else                  return false
      end
      true
    end

    protected def before_start : Nil
      if bridged_endpoints.empty?
        count = rand(INITIAL_DEVICES)
        puts "Creating #{count} initial bridged device(s)..."
        count.times { add_bridged_device }
      else
        puts "Restored #{bridged_endpoints.size} bridged device(s) from storage"
      end

      bridged_endpoints.each { |endpoint| watch(endpoint) }
      configure_actions
      actions.on_execute do |_action, command, _invoke_id, _parameter|
        if command.instant_action?
          bridged_endpoints.each { |endpoint| on_off(endpoint).toggle }
          Matter::InteractionModel::Status.success
        else
          Matter::InteractionModel::Status.invalid_command
        end
      end
      puts ""
      super
    end

    # Every bridged endpoint, in endpoint order.
    def bridged_endpoints : Array(Matter::Endpoint)
      endpoint_ids.compact_map { |endpoint_id| node.endpoint(endpoint_id) }
    end

    def add_bridged_device : Matter::Endpoint
      endpoint_id = next_endpoint_id
      endpoint = add_endpoint(
        :bridged_light,
        name: "Bridged Light #{endpoint_id}",
        unique_id: "bridged-#{endpoint_id}-#{Random::Secure.hex(UNIQUE_ID_BYTES)}"
      )

      watch(endpoint)
      configure_actions
      puts "  Added: Endpoint #{endpoint.number} - #{label(endpoint)}"
      endpoint
    end

    def remove_bridged_device(endpoint : Matter::Endpoint) : Nil
      name = label(endpoint)
      remove_endpoint(endpoint.number)
      configure_actions
      puts "  Removed: Endpoint #{endpoint.number} - #{name}"
    end

    private def watch(endpoint : Matter::Endpoint) : Nil
      number = endpoint.number
      info = bridged_info(endpoint)
      on_off(endpoint).on_state_changed do |state|
        notify "  [Endpoint #{number}] #{info.node_label} is now: #{state ? "ON" : "OFF"}"
      end
    end

    private def toggle_reachable(endpoint : Matter::Endpoint) : Nil
      info = bridged_info(endpoint)
      info.reachable = !info.reachable?
      puts "  Endpoint #{endpoint.number} reachability: #{info.reachable? ? "REACHABLE" : "UNREACHABLE"}"
    end

    private def list_devices : Nil
      endpoints = bridged_endpoints
      if endpoints.empty?
        puts "  No bridged devices"
        return
      end

      endpoints.each do |endpoint|
        state = on_off(endpoint).on_off? ? "ON" : "OFF"
        reachable = bridged_info(endpoint).reachable? ? "" : " [UNREACHABLE]"
        puts "  Endpoint #{endpoint.number}: #{label(endpoint)} - #{state}#{reachable}"
      end
    end

    private def with_endpoint(argument : String?, & : Matter::Endpoint -> Nil) : Nil
      endpoint_id = argument.try(&.to_u16?)
      unless endpoint_id
        puts "  Invalid endpoint number: #{argument}"
        return
      end

      endpoint = node.endpoint(endpoint_id) if endpoint_id != Matter::Node::ROOT_ENDPOINT_ID
      unless endpoint
        puts "  No device on endpoint #{endpoint_id}"
        return
      end

      yield endpoint
    end

    private def on_off(endpoint : Matter::Endpoint) : Matter::Cluster::OnOff
      endpoint.get_cluster!(Matter::Cluster::OnOff)
    end

    private def actions : Matter::Cluster::Actions
      node.endpoint!(Matter::Node::ROOT_ENDPOINT_ID).get_cluster!(Matter::Cluster::Actions)
    end

    private def configure_actions : Nil
      endpoints = bridged_endpoints.map(&.number)
      if endpoints.empty?
        actions.action_list = [] of Matter::Cluster::Actions::Action
        actions.endpoint_lists = [] of Matter::Cluster::Actions::EndpointList
        return
      end
      actions.endpoint_lists = [Matter::Cluster::Actions::EndpointList.new(
        ALL_LIGHTS_ENDPOINT_LIST_ID, "All bridged lights",
        Matter::Cluster::Actions::EndpointListType::Zone, endpoints)]
      actions.action_list = [Matter::Cluster::Actions::Action.new(
        ALL_LIGHTS_ACTION_ID, "Toggle all lights", Matter::Cluster::Actions::ActionType::Scene,
        ALL_LIGHTS_ENDPOINT_LIST_ID, Matter::Cluster::Actions::CommandBits::InstantAction,
        Matter::Cluster::Actions::ActionState::Inactive)]
    end

    private def bridged_info(endpoint : Matter::Endpoint) : Matter::Cluster::BridgedDeviceBasicInformation
      endpoint.get_cluster!(Matter::Cluster::BridgedDeviceBasicInformation)
    end

    private def label(endpoint : Matter::Endpoint) : String
      bridged_info(endpoint).node_label
    end
  end
end

Examples.main("Matter Bridge Device") { MatterBridge::Device.new }
