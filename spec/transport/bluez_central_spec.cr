require "../spec_helper"
require "../../src/matter/transport/bluez_central"

private class FakeBluezNotifications < Matter::Transport::Bluez::Notifications
  getter? closed = false
  getter mtu : Int32?
  @frames : Array(Bytes)

  def initialize(@frames : Array(Bytes), @mtu : Int32? = 23)
  end

  def read(timeout_span : Time::Span) : Bytes?
    if frame = @frames.shift?
      return frame
    end
    sleep(timeout_span)
    nil
  end

  def close : Nil
    @closed = true
  end
end

private class FakeBluezBus < Matter::Transport::Bluez::Bus
  getter calls = [] of String
  getter notifications : FakeBluezNotifications
  property devices : Array(Matter::Transport::Bluez::Device)
  property services : Array(Matter::Transport::Bluez::Service)
  property characteristics : Array(Matter::Transport::Bluez::Characteristic)
  getter writes = [] of Bytes

  def initialize(@notifications : FakeBluezNotifications)
    @devices = [] of Matter::Transport::Bluez::Device
    @services = [] of Matter::Transport::Bluez::Service
    @characteristics = [] of Matter::Transport::Bluez::Characteristic
  end

  def start_scan(service_uuid : String) : Nil
    @calls << "scan #{service_uuid}"
  end

  def stop_scan : Nil
    @calls << "stop scan"
  end

  def connect_device(path : String) : Nil
    @calls << "connect #{path}"
  end

  def services(device_path : String) : Array(Matter::Transport::Bluez::Service)
    @services
  end

  def characteristics(service_path : String) : Array(Matter::Transport::Bluez::Characteristic)
    @characteristics
  end

  def write(characteristic_path : String, frame : Bytes) : Nil
    @calls << "write #{characteristic_path}"
    @writes << frame.dup
  end

  def subscribe(characteristic_path : String) : Matter::Transport::Bluez::Notifications
    @calls << "subscribe #{characteristic_path}"
    @notifications
  end

  def disconnect_device(path : String) : Nil
    @calls << "disconnect #{path}"
  end
end

describe Matter::Transport::Bluez::Central do
  it "discovers a Matter advertisement by discriminator and negotiates C1/C2" do
    response = Matter::Transport::BtpCodec.encode_handshake_response(
      Matter::Transport::BtpCodec::HandshakeResponse.new(4_u8, 20_u16, 4_u8))
    notifications = FakeBluezNotifications.new([response])
    bus = FakeBluezBus.new(notifications)
    bus.devices = [Matter::Transport::Bluez::Device.new(
      "/org/bluez/hci0/dev_AA", "AA:BB:CC:DD:EE:FF",
      Bytes[0x00, 0x34, 0x02, 0xF1, 0xFF, 0x01, 0x80, 0x00])]
    bus.services = [Matter::Transport::Bluez::Service.new(
      "/org/bluez/hci0/dev_AA/service1", Matter::Transport::Bluez::SERVICE_UUID)]
    bus.characteristics = [
      Matter::Transport::Bluez::Characteristic.new(
        "/org/bluez/hci0/dev_AA/service1/c1", Matter::Transport::Bluez::C1_UUID),
      Matter::Transport::Bluez::Characteristic.new(
        "/org/bluez/hci0/dev_AA/service1/c2", Matter::Transport::Bluez::C2_UUID),
    ]
    central = Matter::Transport::Bluez::Central.new(bus)
    device = central.discover(0x234_u16, timeout_span: 100.milliseconds)
    device.address.should eq("AA:BB:CC:DD:EE:FF")
    transport = central.open(device, timeout_span: 100.milliseconds)
    bus.calls.should eq([
      "scan #{Matter::Transport::Bluez::SERVICE_UUID}", "stop scan",
      "connect /org/bluez/hci0/dev_AA",
      "write /org/bluez/hci0/dev_AA/service1/c1",
      "subscribe /org/bluez/hci0/dev_AA/service1/c2",
    ])
    Matter::Transport::BtpCodec.decode_handshake_request(bus.writes.first)
      .versions.should eq([4_u8])
    transport.close
    notifications.closed?.should be_true
    bus.calls.last.should eq("disconnect /org/bluez/hci0/dev_AA")
  end

  it "ignores unrelated advertisements while scanning" do
    bus = FakeBluezBus.new(FakeBluezNotifications.new([] of Bytes))
    bus.devices = [Matter::Transport::Bluez::Device.new(
      "/org/bluez/hci0/dev_AA", "AA:BB:CC:DD:EE:FF",
      Bytes[0x00, 0x35, 0x02, 0xF1, 0xFF, 0x01, 0x80, 0x00])]
    central = Matter::Transport::Bluez::Central.new(bus)
    expect_raises(Matter::TimeoutError) do
      central.discover(0x234_u16, timeout_span: 1.millisecond)
    end
    bus.calls.last.should eq("stop scan")
  end

  it "disconnects when the Matter GATT characteristics do not appear" do
    bus = FakeBluezBus.new(FakeBluezNotifications.new([] of Bytes))
    bus.services = [Matter::Transport::Bluez::Service.new(
      "/org/bluez/hci0/dev_AA/service1", Matter::Transport::Bluez::SERVICE_UUID)]
    device = Matter::Transport::Bluez::Device.new(
      "/org/bluez/hci0/dev_AA", "AA:BB:CC:DD:EE:FF", Bytes.new(0))
    expect_raises(Matter::TimeoutError) do
      Matter::Transport::Bluez::Central.new(bus).open(device, timeout_span: 1.millisecond)
    end
    bus.calls.should eq([
      "connect /org/bluez/hci0/dev_AA",
      "disconnect /org/bluez/hci0/dev_AA",
    ])
  end
end
