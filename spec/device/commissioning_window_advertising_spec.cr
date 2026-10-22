require "../spec_helper"
require "../../src/matter/device"

# Minimal device exposing a fixed discriminator for commissioning-window specs
class CommissioningWindowTestDevice < Matter::Device
  DEVICE_DISCRIMINATOR = 3840_u16

  def initialize
    super(Matter::Storage::Memory.new)
  end

  def device_name : String
    "Window Test Device"
  end

  def vendor_id : UInt16
    0xFFF1_u16
  end

  def product_id : UInt16
    0x8000_u16
  end

  def discriminator : UInt16
    DEVICE_DISCRIMINATOR
  end

  def setup_pin : UInt32
    20202021_u32
  end

  def primary_device_type_id : UInt32
    Matter::DeviceType::ROOT_NODE
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    [] of Matter::Cluster::Base
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {} of UInt16 => UInt32
  end
end

# The advertising callback the device installs on its AdministratorCommissioning cluster
private def start_advertising(device : Matter::Device) : Proc(UInt16?, Matter::MDNS::CommissioningMode, Nil)
  device.administrator_commissioning.on_start_commissioning_advertising || raise "advertising callback not installed"
end

private def advertised_info(device : Matter::Device) : Matter::MDNS::CommissioningInfo
  device.responder.advertised_commissioning_info || raise "no commissioning advertisement"
end

describe "Device commissioning window advertising" do
  it "advertises the device discriminator for a basic window" do
    require_udp_sockets!
    device = CommissioningWindowTestDevice.new

    start_advertising(device).call(nil, Matter::MDNS::CommissioningMode::Basic)

    info = advertised_info(device)
    info.discriminator.should eq(CommissioningWindowTestDevice::DEVICE_DISCRIMINATOR)
    info.commissioning_mode.should eq(Matter::MDNS::CommissioningMode::Basic)
    device.responder.stop_commissioning
  end

  it "advertises the requested discriminator for an enhanced window" do
    require_udp_sockets!
    device = CommissioningWindowTestDevice.new

    start_advertising(device).call(1234_u16, Matter::MDNS::CommissioningMode::Enhanced)

    info = advertised_info(device)
    info.discriminator.should eq(1234_u16)
    info.commissioning_mode.should eq(Matter::MDNS::CommissioningMode::Enhanced)
    device.responder.stop_commissioning
  end

  it "closes the enhanced window after CommissioningComplete" do
    device = CommissioningWindowTestDevice.new
    window = device.administrator_commissioning
    window.open_enhanced_window(900_u16, 1_u8, 0xFFF1_u16)
    window.window_open?.should be_true

    failsafe = device.general_commissioning.failsafe
    failsafe.arm(60_u16, 0_u64, 1_u8, pase_session: false).ok?.should be_true
    failsafe.complete(1_u8, case_session: true).ok?.should be_true

    window.window_open?.should be_false
  end

  it "closes the enhanced window when the commissioning failsafe rolls back" do
    device = CommissioningWindowTestDevice.new
    window = device.administrator_commissioning
    window.open_enhanced_window(900_u16, 1_u8, 0xFFF1_u16)
    window.window_open?.should be_true

    failsafe = device.general_commissioning.failsafe
    failsafe.arm(60_u16, 0_u64, 1_u8, pase_session: false).ok?.should be_true
    failsafe.expire

    window.window_open?.should be_false
  end
end
