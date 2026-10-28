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
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
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
  device = MatterSwitch::Device.new(ip_addresses: ip_addresses,
    groupcast_listener: ENV["MATTER_GROUPCAST_LISTENER"]? == "1",
    groupcast_sender: ENV["MATTER_GROUPCAST_SENDER"]? == "1",
    groupcast_per_group: ENV["MATTER_GROUPCAST_PER_GROUP"]? == "1",
    groupcast_max_mcast_addr_count: ENV["MATTER_GROUPCAST_MAX_MCAST_ADDR_COUNT"]?.try(&.to_u16))
  if max_fail_safe = ENV["MATTER_SWITCH_MAX_CUMULATIVE_FAILSAFE_SECONDS"]?.try(&.to_u16)
    device.general_commissioning.max_cumulative_failsafe_seconds = max_fail_safe
  end
  if ENV["MATTER_SWITCH_E2E_DIAGNOSTIC_LOG"]? == "1"
    device.node.get_cluster!(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::DiagnosticLogs)
      .log("E2E BDX diagnostic log " + "L" * 1100)
  end
  if drop_path = ENV["MATTER_SWITCH_E2E_DROP_REMOVE_FABRIC_RESPONSE"]?
    device.message_handler.on_im_response_packet = ->(request_message : Matter::Codec::MessageCodec::Message, response_type : UInt8, _packet : Bytes) do
      remove_fabric_request = if response_type == Matter::InteractionModel::MessageType::InvokeResponse.value
                                if request = Matter::Protocol::IMHandler.parse_invoke_request(request_message.payload)
                                  if request.invoke_requests.size == 1
                                    path = request.invoke_requests.first.command_path
                                    path.endpoint == Matter::Node::ROOT_ENDPOINT_ID &&
                                    path.cluster == Matter::Cluster::OperationalCredentials::CLUSTER_ID &&
                                    path.command == Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC
                                  else
                                    false
                                  end
                                else
                                  false
                                end
                              else
                                false
                              end

      if remove_fabric_request
        count_path = "#{drop_path}.count"
        count = (File.exists?(count_path) ? File.read(count_path).to_i? : nil) || 0
        count += 1
        File.write(count_path, count.to_s)
        if File.exists?("#{drop_path}.armed")
          File.delete("#{drop_path}.armed")
          File.write("#{drop_path}.dropped", count.to_s)
          true
        else
          false
        end
      else
        false
      end
    end
  end
  device
end
