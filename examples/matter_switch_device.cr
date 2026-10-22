require "./support/console"
require "./support/main"

# Matter Switch Device Example
#
# - Presents as an On/Off Light (endpoint 1)
# - Persists state in a single YAML storage file
# - Supports commissioning and operational modes
# - Works with real Matter controllers (iPhone, chip-tool, etc.)

module MatterSwitch
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Switch",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ON_OFF_LIGHT,
      appearance: :satin

    storage yaml: "matter_switch_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT do
      cluster Matter::Cluster::OnOff, feature_map: :lighting, as: :switch
      # FixedLabel is optional, but can help controllers show a friendly name for this endpoint.
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example Switch")]
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::ScenesManagement
    end

    on(:switch, :state_changed) do |state|
      notify "Switch is now: #{state ? "ON" : "OFF"}", "Data version: #{switch.data_version}"
      if state && ENV["MATTER_GROUPCAST_FORWARD_ON"]? == "1" &&
         switch.request_command_active? && switch.request_is_case_session?
        send_groupcast_invoke_for_request(switch,
          Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)
      end
    end

    def console_notes : Array(String)
      ["Device Type: On/Off Light"]
    end

    def state_details : Nil
      puts "  Switch: #{switch.on_off? ? "ON" : "OFF"}"
      puts "  Data Version: #{switch.data_version}"
    end

    def status_details : Nil
      puts "  Switch State: #{switch.on_off? ? "ON" : "OFF"}"
      puts "  Data Version: #{switch.data_version}"
    end

    def commands : Array(Tuple(String, String))
      [
        {"toggle", "Toggle the switch between on and off"},
        {"on", "Turn the switch on"},
        {"off", "Turn the switch off"},
      ]
    end

    def handle_command(name : String, argument : String?) : Bool
      case name
      when "toggle" then switch.toggle
      when "on"     then switch.on = true
      when "off"    then switch.on = false
      else               return false
      end
      true
    end
  end
end

Examples.main("Matter Switch Device") do
  ip_addresses = ENV["MATTER_SWITCH_IP_ADDRESS"]?.try do |address|
    [Socket::IPAddress.new(address, Matter::Network::UNSPECIFIED_PORT)]
  end
  MatterSwitch::Device.new(ip_addresses: ip_addresses,
    groupcast_listener: ENV["MATTER_GROUPCAST_LISTENER"]? == "1",
    groupcast_sender: ENV["MATTER_GROUPCAST_SENDER"]? == "1")
end
