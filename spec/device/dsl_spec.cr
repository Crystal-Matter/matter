require "../spec_helper"
require "../../src/matter/device"

# Exercises every `Matter::Device::DSL` declaration.
#
# `on(:switch, ...)` is declared before the endpoint that declares `:switch`
# and reaches across to endpoint 2's `:fan`: both only work because callbacks
# are wired once every endpoint has been built.
class DslSpecDevice < Matter::Device
  LIGHT_ENDPOINT = 1
  FAN_ENDPOINT   = 2

  getter states = [] of Bool
  getter fan_modes = [] of Matter::Cluster::FanControl::FanMode

  on(:switch, :state_changed) do |state|
    @states << state
    @fan_modes << fan.fan_mode
  end

  identity vendor: "Spider-Gazelle", product: "Crystal DSL",
    vendor_id: 0xFFF1_u16,
    product_id: 0x8123_u16,
    discriminator: 3841_u16,
    pin: 20202099_u32,
    device_type: Matter::DeviceType::ON_OFF_LIGHT,
    appearance: :satin,
    hardware_version: 7_u16,
    hardware_version_string: "7.0",
    software_version: 9_u32,
    software_version_string: "9.0.0",
    serial_number: "DSL-SERIAL",
    unique_id: "dsl-unique"

  storage :memory
  network :wifi

  endpoint LIGHT_ENDPOINT, device_type: Matter::DeviceType::ON_OFF_LIGHT do
    client_cluster 0x0554_u32
    cluster Matter::Cluster::OnOff, feature_map: :lighting, as: :switch
    cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example DSL")]
    cluster Matter::Cluster::Identify, identify_type: :visible_light
    cluster Matter::Cluster::Groups
  end

  endpoint FAN_ENDPOINT, device_type: Matter::DeviceType::FAN do
    cluster Matter::Cluster::FanControl, as: :fan
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
  end
end

# A bridge-shaped device: no clusters of its own, one template it adds
# endpoints from at runtime.
class DslSpecBridge < Matter::Device
  identity vendor: "Spider-Gazelle", product: "Crystal DSL Bridge",
    vendor_id: 0xFFF1_u16,
    product_id: 0x8124_u16,
    discriminator: 3842_u16,
    pin: 20202098_u32,
    device_type: Matter::DeviceType::ROOT_NODE

  storage yaml: "matter_dsl_bridge_storage.yml"

  endpoint 0, device_type: Matter::DeviceType::AGGREGATOR

  endpoint_template :bridged_light,
    device_type: [Matter::DeviceType::ON_OFF_LIGHT, Matter::DeviceType::BRIDGED_NODE],
    parameters: {name: String, unique_id: String} do
    client_cluster 0x0554_u32
    cluster Matter::Cluster::OnOff
    cluster Matter::Cluster::BridgedDeviceBasicInformation, node_label: name, unique_id: unique_id
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
  end

  endpoint_template :versioned_bridged_light,
    device_type: [Matter::DeviceType::ON_OFF_LIGHT, Matter::DeviceType::BRIDGED_NODE],
    parameters: {name: String, unique_id: String, configuration_version: Int64} do
    cluster Matter::Cluster::OnOff
    cluster Matter::Cluster::BridgedDeviceBasicInformation,
      node_label: name, unique_id: unique_id, configuration_version: configuration_version.to_u32
    cluster Matter::Cluster::Identify
    cluster Matter::Cluster::Groups
  end
end

module DslSpec
  # Bind an ephemeral UDP port so instances never collide.
  EPHEMERAL_PORT = 0

  def self.with_temp_file(& : String ->) : Nil
    path = File.join(Dir.tempdir, "matter-dsl-#{Random::Secure.hex(6)}.yml")
    yield path
  ensure
    File.delete?(path) if path
  end

  # Flushes and releases a device without `Responder#stop`, which logs a
  # socket error when the responder was never started (as in these specs).
  def self.stop(device : Matter::Device) : Nil
    device.message_handler.close
    device.persistence.close
    device.transport.close
  end

  def self.bridge(path : String) : DslSpecBridge
    DslSpecBridge.new(Matter::Storage::YamlFile.new(path), port: EPHEMERAL_PORT)
  end

  def self.endpoint_labels(device : Matter::Device) : Hash(UInt16, String)
    labels = {} of UInt16 => String
    device.endpoint_ids.each do |endpoint_id|
      endpoint = device.node.endpoint!(endpoint_id)
      labels[endpoint_id] = endpoint.get_cluster!(Matter::Cluster::BridgedDeviceBasicInformation).node_label
    end
    labels
  end

  def self.bridged_info(device : Matter::Device, endpoint_id : UInt16) : Matter::Cluster::BridgedDeviceBasicInformation
    device.node.get_cluster!(endpoint_id, Matter::Cluster::BridgedDeviceBasicInformation)
  end
end

describe Matter::Device::DSL do
  it "places declared client clusters in Descriptor.ClientList" do
    device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)
    descriptor = device.node.endpoint!(DslSpecDevice::LIGHT_ENDPOINT.to_u16).descriptor
    descriptor.client_list.should eq([0x0554_u32])
    descriptor.server_list.should_not contain(0x0554_u32)
    DslSpec.stop(device)
  end

  it "retains template client clusters when restoring a dynamic endpoint" do
    DslSpec.with_temp_file do |path|
      bridge = DslSpec.bridge(path)
      endpoint = bridge.add_endpoint(:bridged_light, name: "Light", unique_id: "light-1")
      endpoint.descriptor.client_list.should eq([0x0554_u32])
      DslSpec.stop(bridge)

      restored = DslSpec.bridge(path)
      restored.node.endpoint!(endpoint.number).descriptor.client_list.should eq([0x0554_u32])
      DslSpec.stop(restored)
    end
  end

  describe "identity" do
    it "answers every identity method from the declaration" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)

      device.device_name.should eq("Crystal DSL")
      device.product_name.should eq("Crystal DSL")
      device.vendor_name.should eq("Spider-Gazelle")
      device.vendor_id.should eq(0xFFF1_u16)
      device.product_id.should eq(0x8123_u16)
      device.discriminator.should eq(3841_u16)
      device.setup_pin.should eq(20202099_u32)
      device.primary_device_type_id.should eq(Matter::DeviceType::ON_OFF_LIGHT)
      device.hardware_version.should eq(7_u16)
      device.hardware_version_string.should eq("7.0")
      device.software_version.should eq(9_u32)
      device.software_version_string.should eq("9.0.0")
      device.serial_number.should eq("DSL-SERIAL")
      device.unique_id.should eq("dsl-unique")

      appearance = device.product_appearance.should_not be_nil
      appearance.finish.should eq(Matter::Cluster::BasicInformation::ProductFinish::Satin)
    end

    it "carries the declaration into BasicInformation" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)

      device.basic_info.vendor_name.should eq("Spider-Gazelle")
      device.basic_info.product_name.should eq("Crystal DSL")
      device.basic_info.serial_number.should eq("DSL-SERIAL")
      device.basic_info.unique_id.should eq("dsl-unique")
    end
  end

  describe "storage" do
    it "opens the declared backend and takes one from the caller" do
      DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT).persistence.backend.should be_a(Matter::Storage::Memory)

      backend = Matter::Storage::Memory.new
      DslSpecDevice.new(backend, port: DslSpec::EPHEMERAL_PORT).persistence.backend.should be(backend)
    end
  end

  describe "network" do
    it "passes a Wi-Fi device's fixed regulatory capability to General Commissioning" do
      indoor = Matter::Cluster::GeneralCommissioning::RegulatoryLocationType::Indoor
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT,
        regulatory_location_capability: indoor)

      device.general_commissioning.location_capability.should eq(indoor)
      device.general_commissioning.regulatory_config.should eq(indoor)
    end

    it "requires IndoorOutdoor regulatory capability on Ethernet-only devices" do
      indoor = Matter::Cluster::GeneralCommissioning::RegulatoryLocationType::Indoor
      expect_raises(Matter::ConfigurationError) do
        DslSpecBridge.new(Matter::Storage::Memory.new, port: DslSpec::EPHEMERAL_PORT,
          regulatory_location_capability: indoor)
      end
    end

    it "enables Terms and Conditions on root General Commissioning from device options" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      commissioning = device.general_commissioning
      commissioning.feature_map.terms_and_conditions?.should be_true
      commissioning.tc_min_required_version.should eq(2_u16)
      commissioning.tc_acknowledgements_required.should be_true
    end

    it "restores only committed Terms and Conditions acceptance from device storage" do
      storage = Matter::Storage::Memory.new
      device = DslSpecDevice.new(storage, port: DslSpec::EPHEMERAL_PORT,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      commissioning = device.general_commissioning
      commissioning.arm_failsafe(
        Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64),
        1_u8, false
      ).error_code.ok?.should be_true
      commissioning.set_tc_acknowledgements(
        Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16)
      ).error_code.ok?.should be_true
      device.persistence.save_cluster(commissioning).should be_true

      interrupted = DslSpecDevice.new(storage, port: DslSpec::EPHEMERAL_PORT,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      interrupted.general_commissioning.tc_acknowledgements_required?.should be_true

      commissioning.commissioning_complete(1_u8, true).error_code.ok?.should be_true
      device.persistence.save_cluster(commissioning).should be_true
      completed = DslSpecDevice.new(storage, port: DslSpec::EPHEMERAL_PORT,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      completed.general_commissioning.tc_acknowledgements_required?.should be_false
      completed.general_commissioning.tc_accepted_version.should eq(2_u16)
    end

    it "configures Network Commissioning for the declared network" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)
      network = device.node.get_cluster!(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::NetworkCommissioning)

      network.feature_map.wi_fi_network_interface?.should be_true
      # Ethernet diagnostics belong to an ethernet device only.
      device.node.get_cluster(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::EthernetNetworkDiagnostics).should be_nil
      device.node.get_cluster(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::WiFiNetworkDiagnostics).should_not be_nil
    end

    it "passes a platform backend to Network Commissioning" do
      backend = Matter::Network::TestBackend.new
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT, network_backend: backend)
      network = device.node.get_cluster!(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::NetworkCommissioning)

      network.backend.should be(backend)
    end

    it "updates General Commissioning Breadcrumb only after a successful network command" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT, network_backend: Matter::Network::TestBackend.new)
      network = device.node.get_cluster!(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::NetworkCommissioning)
      general = device.node.get_cluster!(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::GeneralCommissioning)

      successful = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "network".to_slice,
        credentials: "password".to_slice,
        breadcrumb: 42_u64
      )
      network.handle_add_or_update_wifi_network(successful, failsafe_armed: true).networking_status.should eq(
        Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success
      )
      general.breadcrumb.should eq(42_u64)

      rejected = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: Bytes.new(0),
        credentials: "password".to_slice,
        breadcrumb: 99_u64
      )
      network.handle_add_or_update_wifi_network(rejected, failsafe_armed: true).networking_status.should eq(
        Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::OutOfRange
      )
      general.breadcrumb.should eq(42_u64)
    end
  end

  describe "endpoint" do
    it "builds every declared endpoint with its device type" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)

      device.endpoint_ids.should eq([1_u16, 2_u16])
      device.node.endpoint!(1_u16).device_types.map(&.device_type_id.id).should eq([Matter::DeviceType::ON_OFF_LIGHT])
      device.node.endpoint!(2_u16).device_types.map(&.device_type_id.id).should eq([Matter::DeviceType::FAN])
      device.node.endpoint!(Matter::Node::ROOT_ENDPOINT_ID).descriptor.parts_list.should eq([1_u16, 2_u16])
    end

    it "adds every declared cluster to its endpoint" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)
      light = device.node.endpoint!(1_u16)

      light.has_cluster?(Matter::Cluster::OnOff::CLUSTER_ID).should be_true
      light.has_cluster?(Matter::Cluster::FixedLabel::CLUSTER_ID).should be_true
      light.has_cluster?(Matter::Cluster::Identify::CLUSTER_ID).should be_true
      light.has_cluster?(Matter::Cluster::Groups::CLUSTER_ID).should be_true
      light.get_cluster!(Matter::Cluster::Identify).identify_type.should eq(Matter::Cluster::Identify::IdentifyType::VisibleLight)
      light.get_cluster!(Matter::Cluster::FixedLabel).label_list.map(&.value).should eq(["Example DSL"])
    end

    it "generates a non-nil typed accessor per as:" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)

      device.switch.should be_a(Matter::Cluster::OnOff)
      device.switch.feature_map.lighting?.should be_true
      device.switch.should be(device.node.get_cluster!(1_u16, Matter::Cluster::OnOff))
      device.fan.should be(device.node.get_cluster!(2_u16, Matter::Cluster::FanControl))
    end
  end

  describe "on" do
    it "wires the callback, whatever order the declarations are in" do
      device = DslSpecDevice.new(port: DslSpec::EPHEMERAL_PORT)

      device.switch.on = true
      device.switch.on = false

      device.states.should eq([true, false])
      # The callback read endpoint 2's cluster, which is only reachable
      # because callbacks are wired after every endpoint is built.
      device.fan_modes.should eq([Matter::Cluster::FanControl::FanMode::Off] * 2)
    end
  end

  describe "endpoint_template" do
    it "declares no static endpoint of its own" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        bridge.endpoint_ids.should be_empty
        bridge.node.endpoint!(Matter::Node::ROOT_ENDPOINT_ID).device_types.map(&.device_type_id.id)
          .should eq([Matter::DeviceType::ROOT_NODE, Matter::DeviceType::AGGREGATOR])
        DslSpec.stop(bridge)
      end
    end

    it "builds an endpoint from the template parameters" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        endpoint = bridge.add_endpoint(:bridged_light, name: "Porch", unique_id: "porch-1")

        endpoint.number.should eq(1_u16)
        endpoint.device_types.map(&.device_type_id.id)
          .should eq([Matter::DeviceType::ON_OFF_LIGHT, Matter::DeviceType::BRIDGED_NODE])
        info = endpoint.get_cluster!(Matter::Cluster::BridgedDeviceBasicInformation)
        info.node_label.should eq("Porch")
        info.unique_id.should eq("porch-1")
        bridge.node.endpoint!(Matter::Node::ROOT_ENDPOINT_ID).descriptor.parts_list.should eq([1_u16])

        DslSpec.stop(bridge)
      end
    end

    it "refuses a template it does not declare" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        expect_raises(ArgumentError, /bridged_switch/) do
          bridge.add_endpoint(:bridged_switch, name: "Nope", unique_id: "nope")
        end
        DslSpec.stop(bridge)
      end
    end

    it "refuses a parameter of the wrong type" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        expect_raises(ArgumentError, /unique_id/) do
          bridge.add_endpoint(:bridged_light, name: "Porch", unique_id: 7)
        end
        DslSpec.stop(bridge)
      end
    end

    it "restores the endpoints and their cluster state after a restart" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        bridge.add_endpoint(:bridged_light, name: "Porch", unique_id: "porch-1")
        second = bridge.add_endpoint(:bridged_light, name: "Hall", unique_id: "hall-1")
        second.get_cluster!(Matter::Cluster::OnOff).on = true
        bridge.basic_info.increase_configuration_version
        DslSpec.stop(bridge)

        restarted = DslSpec.bridge(path)
        restarted.basic_info.configuration_version.should eq(2_u32)
        DslSpec.endpoint_labels(restarted).should eq({1_u16 => "Porch", 2_u16 => "Hall"})
        restarted.node.get_cluster!(1_u16, Matter::Cluster::BridgedDeviceBasicInformation).unique_id.should eq("porch-1")
        restarted.node.get_cluster!(2_u16, Matter::Cluster::BridgedDeviceBasicInformation).unique_id.should eq("hall-1")
        restarted.node.endpoint!(Matter::Node::ROOT_ENDPOINT_ID).descriptor.parts_list.should eq([1_u16, 2_u16])
        restarted.node.get_cluster!(1_u16, Matter::Cluster::OnOff).on?.should be_false
        restarted.node.get_cluster!(2_u16, Matter::Cluster::OnOff).on?.should be_true
        DslSpec.stop(restarted)
      end
    end

    it "advances one bridged ConfigurationVersion and the bridge root once" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        endpoint = bridge.add_endpoint(:versioned_bridged_light,
          name: "Porch", unique_id: "porch-1", configuration_version: 1_u32)

        bridge.increase_bridged_configuration_version(endpoint.number)
        DslSpec.bridged_info(bridge, endpoint.number).configuration_version.should eq(2_u32)
        bridge.basic_info.configuration_version.should eq(2_u32)
        DslSpec.stop(bridge)
      end
    end

    it "coalesces grouped bridged changes into one root increment" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        first = bridge.add_endpoint(:versioned_bridged_light,
          name: "Porch", unique_id: "porch-1", configuration_version: 1_u32)
        second = bridge.add_endpoint(:versioned_bridged_light,
          name: "Hall", unique_id: "hall-1", configuration_version: 1_u32)

        bridge.increase_bridged_configuration_version([first.number, second.number, first.number])
        DslSpec.bridged_info(bridge, first.number).configuration_version.should eq(2_u32)
        DslSpec.bridged_info(bridge, second.number).configuration_version.should eq(2_u32)
        bridge.basic_info.configuration_version.should eq(2_u32)
        DslSpec.stop(bridge)
      end
    end

    it "rejects an unversioned member before changing any grouped version" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        versioned = bridge.add_endpoint(:versioned_bridged_light,
          name: "Porch", unique_id: "porch-1", configuration_version: 1_u32)
        unversioned = bridge.add_endpoint(:bridged_light, name: "Hall", unique_id: "hall-1")

        expect_raises(Matter::ConfigurationError) do
          bridge.increase_bridged_configuration_version([versioned.number, unversioned.number])
        end
        DslSpec.bridged_info(bridge, versioned.number).configuration_version.should eq(1_u32)
        bridge.basic_info.configuration_version.should eq(1_u32)
        DslSpec.stop(bridge)
      end
    end

    it "persists both bridged and bridge versions through restart" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        endpoint = bridge.add_endpoint(:versioned_bridged_light,
          name: "Porch", unique_id: "porch-1", configuration_version: 1_u32)
        bridge.increase_bridged_configuration_version(endpoint.number)
        DslSpec.stop(bridge)

        restarted = DslSpec.bridge(path)
        DslSpec.bridged_info(restarted, endpoint.number).configuration_version.should eq(2_u32)
        restarted.basic_info.configuration_version.should eq(2_u32)
        DslSpec.stop(restarted)
      end
    end

    it "forgets an endpoint that was removed" do
      DslSpec.with_temp_file do |path|
        bridge = DslSpec.bridge(path)
        first = bridge.add_endpoint(:bridged_light, name: "Porch", unique_id: "porch-1")
        bridge.add_endpoint(:bridged_light, name: "Hall", unique_id: "hall-1")
        bridge.remove_endpoint(first.number).should be_true
        DslSpec.stop(bridge)

        restarted = DslSpec.bridge(path)
        DslSpec.endpoint_labels(restarted).should eq({2_u16 => "Hall"})
        DslSpec.stop(restarted)
      end
    end
  end
end

describe "device TCP opt-in" do
  it "uses a dual UDP/TCP transport only when requested" do
    require_udp_sockets!
    device = DslSpecDevice.new(port: 0, tcp_enabled: true)
    device.transport.should be_a(Matter::Transport::TcpEnabledTransport)
  ensure
    DslSpec.stop(device) if device
  end
end
