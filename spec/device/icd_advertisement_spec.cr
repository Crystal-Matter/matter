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

  def operational_info_for_spec(fabric : Matter::Fabric) : Matter::MDNS::OperationalInfo
    operational_info_for(fabric)
  end
end

private def icd_spec_fabric : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: 0x1234_u64, fabric_index: 1_u8, node_id: 0x5678_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
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

  it "advertises ICD Management only when explicitly configured as an ICD" do
    configuration = Matter::Cluster::IcdManagement::Configuration.new(
      feature_map: Matter::Cluster::IcdManagement::Feature::CheckInProtocolSupport,
      idle_mode_duration: 60_u32,
      active_mode_duration: 3_000_u32,
      active_mode_threshold: 5_000_u16
    )
    device = AlwaysOnIcdSpecDevice.new(port: 0, icd_configuration: configuration)

    cluster = device.node.get_cluster(Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::IcdManagement)
    cluster.should_not be_nil
    cluster.as(Matter::Cluster::IcdManagement).feature_map
      .should eq(Matter::Cluster::IcdManagement::Feature::CheckInProtocolSupport)
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end

  it "passes the UAT trigger hint and instruction through device configuration" do
    configuration = Matter::Cluster::IcdManagement::Configuration.new(
      feature_map: Matter::Cluster::IcdManagement::Feature::UserActiveModeTrigger,
      user_active_mode_trigger_hint: 1_u32 << 2,
      user_active_mode_trigger_instruction: "Press the silver button")
    device = AlwaysOnIcdSpecDevice.new(port: 0, icd_configuration: configuration)
    cluster = device.icd_management.as(Matter::Cluster::IcdManagement)
    cluster.user_active_mode_trigger_hint.should eq(4_u32)
    cluster.user_active_mode_trigger_instruction.should eq("Press the silver button")
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end

  it "advertises SII/SAI only for explicit ICD operation" do
    fabric = icd_spec_fabric
    always_on = AlwaysOnIcdSpecDevice.new(port: 0)
    always_on.operational_info_for_spec(fabric).to_txt_records.has_key?("SII").should be_false

    config = Matter::Cluster::IcdManagement::Configuration.new(
      feature_map: Matter::Cluster::IcdManagement::Feature::CheckInProtocolSupport,
      idle_mode_duration: 60_u32, active_mode_duration: 3_000_u32)
    icd_device = AlwaysOnIcdSpecDevice.new(port: 0, icd_configuration: config)
    txt = icd_device.operational_info_for_spec(fabric).to_txt_records
    txt["SII"].should eq("60000")
    txt["SAI"].should eq("3000")
  ensure
    if always_on
      always_on.message_handler.close
      always_on.persistence.close
      always_on.transport.close
    end
    if icd_device
      icd_device.message_handler.close
      icd_device.persistence.close
      icd_device.transport.close
    end
  end
end
