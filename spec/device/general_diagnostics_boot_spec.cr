require "../spec_helper"
require "../../src/matter/device"

private class GeneralDiagnosticsBootDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Boot Event Test",
    vendor_id: 0xFFF1_u16,
    product_id: 0x8127_u16,
    discriminator: 3847_u16,
    pin: 20202095_u32,
    device_type: Matter::DeviceType::ROOT_NODE

  storage :memory
end

describe Matter::Device do
  it "journals the configured GeneralDiagnostics BootReason when the device starts" do
    require_udp_sockets!
    device = GeneralDiagnosticsBootDevice.new(port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
    diagnostics = device.node.get_cluster(Matter::Node::ROOT_ENDPOINT_ID,
      Matter::Cluster::GeneralDiagnostics).as(Matter::Cluster::GeneralDiagnostics)
    diagnostics.boot_reason = Matter::Cluster::GeneralDiagnostics::BootReason::SoftwareReset

    device.start

    events = device.node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: Matter::Cluster::GeneralDiagnostics::CLUSTER_ID,
      event: Matter::Cluster::GeneralDiagnostics::EVENT_BOOT_REASON,
    )])
    events.size.should eq(1)
    Matter::Cluster::GeneralDiagnostics::Events::BootReasonEvent.from_tlv(events.first.data).boot_reason
      .should eq(Matter::Cluster::GeneralDiagnostics::BootReason::SoftwareReset)
  ensure
    device.try(&.shutdown!)
  end
end
