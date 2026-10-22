require "../spec_helper"
require "../../src/matter/device"

private class DeviceLoadTestDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Device Load Test",
    vendor_id: 0xFFF1_u16,
    product_id: 0x8128_u16,
    discriminator: 3848_u16,
    pin: 20202096_u32,
    device_type: Matter::DeviceType::ROOT_NODE

  storage :memory
end

describe Matter::Device do
  it "wires the mandatory DeviceLoadStatus read on a running device" do
    require_udp_sockets!
    device = DeviceLoadTestDevice.new(port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    diagnostics = device.node.get_cluster(Matter::Node::ROOT_ENDPOINT_ID,
      Matter::Cluster::GeneralDiagnostics).as(Matter::Cluster::GeneralDiagnostics)

    wire = read_tlv(diagnostics, Matter::Cluster::GeneralDiagnostics::ATTR_DEVICE_LOAD_STATUS, 1_u8)
    wire.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8])
    wire.as_structure.values.map(&.value).should eq([0_u16, 0_u16, 0_u32, 0_u32, 0_u32])

    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    device.message_handler.registry.add_subscription(Matter::Protocol::ActiveSubscription.new(
      subscription_id: 1_u32,
      min_interval: 0_u16,
      max_interval: 60_u16,
      peer: Socket::IPAddress.new("127.0.0.1", 5540),
      session: session,
      attribute_paths: [] of Matter::InteractionModel::AttributePath,
      exchange_id: 1_u16,
    ))
    on_fabric = read_tlv(diagnostics, Matter::Cluster::GeneralDiagnostics::ATTR_DEVICE_LOAD_STATUS, 1_u8).as_structure
    other_fabric = read_tlv(diagnostics, Matter::Cluster::GeneralDiagnostics::ATTR_DEVICE_LOAD_STATUS, 2_u8).as_structure
    on_fabric[0_u8].value.should eq(1_u16)
    on_fabric[1_u8].value.should eq(1_u16)
    other_fabric[1_u8].value.should eq(0_u16)
    on_fabric[2_u8].value.should eq(1_u32)
  ensure
    device.try(&.shutdown!)
  end
end
