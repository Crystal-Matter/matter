require "../spec_helper"
require "../../src/matter/device"

private class AlwaysOnIcdSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Always-On Test",
    vendor_id: 0xFFF1_u16,
    product_id: 0x8125_u16,
    discriminator: 3843_u16,
    pin: 20202097_u32,
    device_type: Matter::DeviceType::ROOT_NODE

  storage :memory
end

describe Matter::Device do
  it "does not advertise ICD Management on an always-on device" do
    device = AlwaysOnIcdSpecDevice.new(port: 0)

    device.node.get_cluster(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::IcdManagement).should be_nil
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end
end
