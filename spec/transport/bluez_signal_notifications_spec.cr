require "../spec_helper"
require "../../src/matter/transport/bluez_signal_notifications"

private class FakeBluezSignalSource
  include Matter::Transport::Bluez::SignalSource
  getter calls = [] of String
  property? fail_start = false
  property? fail_stop = false
  property burst_count = 0
  @callback : Proc(Bytes, Nil)?
  @pending = [] of Bytes

  def subscribe_values(path : String, &callback : Bytes -> Nil) : UInt32
    @calls << "subscribe #{path}"
    @callback = callback
    7_u32
  end

  def start_notify(path : String) : Nil
    @calls << "start #{path}"
    raise Matter::TransportError.new("BlueZ StartNotify failed") if @fail_start
    @callback.try(&.call(Bytes[0x65, 0x6c]))
    @burst_count.times { @callback.try(&.call(Bytes[0x01])) }
  end

  def stop_notify(path : String) : Nil
    @calls << "stop #{path}"
    raise Matter::TransportError.new("BlueZ StopNotify failed") if @fail_stop
  end

  def unsubscribe_values(subscription_id : UInt32) : Nil
    @calls << "unsubscribe #{subscription_id}"
    @callback = nil
  end

  def dispatch_pending : Nil
    if frame = @pending.shift?
      @callback.try(&.call(frame))
    end
  end

  def queue(frame : Bytes) : Nil
    @pending << frame
  end
end

private class FallbackBluezBus < Matter::Transport::Bluez::Bus
  getter? disconnected = false

  def initialize(@source : FakeBluezSignalSource)
  end

  def start_scan(service_uuid : String) : Nil
  end

  def stop_scan : Nil
  end

  def devices : Array(Matter::Transport::Bluez::Device)
    [] of Matter::Transport::Bluez::Device
  end

  def connect_device(path : String) : Nil
  end

  def services(device_path : String) : Array(Matter::Transport::Bluez::Service)
    [Matter::Transport::Bluez::Service.new("#{device_path}/service1", Matter::Transport::Bluez::SERVICE_UUID)]
  end

  def characteristics(service_path : String) : Array(Matter::Transport::Bluez::Characteristic)
    [
      Matter::Transport::Bluez::Characteristic.new("#{service_path}/c1", Matter::Transport::Bluez::C1_UUID),
      Matter::Transport::Bluez::Characteristic.new("#{service_path}/c2", Matter::Transport::Bluez::C2_UUID),
    ]
  end

  def write(characteristic_path : String, frame : Bytes) : Nil
    Matter::Transport::BtpCodec.decode_handshake_request(frame)
    response = Matter::Transport::BtpCodec.encode_handshake_response(
      Matter::Transport::BtpCodec::HandshakeResponse.new(4_u8, 20_u16, 4_u8))
    @source.queue(response)
  end

  def subscribe(characteristic_path : String) : Matter::Transport::Bluez::Notifications
    Matter::Transport::Bluez::SignalNotifications.open(@source, characteristic_path)
  end

  def disconnect_device(path : String) : Nil
    @disconnected = true
  end
end

describe Matter::Transport::Bluez::SignalNotifications do
  it "negotiates a BTP channel through the StartNotify C2 path" do
    source = FakeBluezSignalSource.new
    bus = FallbackBluezBus.new(source)
    device = Matter::Transport::Bluez::Device.new(
      "/org/bluez/hci0/dev_AA", "AA:BB:CC:DD:EE:FF", Bytes.new(0))
    transport = Matter::Transport::Bluez::Central.new(bus).open(device, timeout_span: 100.milliseconds)
    transport.close
    bus.disconnected?.should be_true
    source.calls.should contain("start /org/bluez/hci0/dev_AA/service1/c2")
  end

  it "subscribes before StartNotify and preserves successive C2 frames" do
    path = "/org/bluez/hci0/dev_AA/service1/c2"
    source = FakeBluezSignalSource.new
    notifications = Matter::Transport::Bluez::SignalNotifications.open(source, path)
    source.calls.should eq(["subscribe #{path}", "start #{path}"])
    notifications.read(20.milliseconds).should eq(Bytes[0x65, 0x6c])
    source.queue(Bytes[0x01, 0x02])
    notifications.read(20.milliseconds).should eq(Bytes[0x01, 0x02])
    notifications.close
    source.calls.last(2).should eq(["stop #{path}", "unsubscribe 7"])
  end

  it "unsubscribes when StartNotify fails" do
    path = "/org/bluez/hci0/dev_AA/service1/c2"
    source = FakeBluezSignalSource.new
    source.fail_start = true
    expect_raises(Matter::TransportError) do
      Matter::Transport::Bluez::SignalNotifications.open(source, path)
    end
    source.calls.should eq(["subscribe #{path}", "start #{path}", "unsubscribe 7"])
  end

  it "delivers duplicate C2 values as distinct indications" do
    source = FakeBluezSignalSource.new
    notifications = Matter::Transport::Bluez::SignalNotifications.open(
      source, "/org/bluez/hci0/dev_AA/service1/c2")
    notifications.read(20.milliseconds)
    source.queue(Bytes[0x01, 0x02])
    source.queue(Bytes[0x01, 0x02])
    notifications.read(20.milliseconds).should eq(Bytes[0x01, 0x02])
    notifications.read(20.milliseconds).should eq(Bytes[0x01, 0x02])
    notifications.close
  end

  it "unsubscribes even if StopNotify fails" do
    source = FakeBluezSignalSource.new
    source.fail_stop = true
    notifications = Matter::Transport::Bluez::SignalNotifications.open(
      source, "/org/bluez/hci0/dev_AA/service1/c2")
    expect_raises(Matter::TransportError) { notifications.close }
    source.calls.last.should eq("unsubscribe 7")
  end

  it "fails a session when C2 indications overflow the bounded queue" do
    source = FakeBluezSignalSource.new
    source.burst_count = 200
    notifications = Matter::Transport::Bluez::SignalNotifications.open(
      source, "/org/bluez/hci0/dev_AA/service1/c2")
    expect_raises(Matter::TransportError, /overflowed/) do
      notifications.read(20.milliseconds)
    end
    notifications.close
  end
end
