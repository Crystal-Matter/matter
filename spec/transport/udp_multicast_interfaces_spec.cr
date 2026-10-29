require "../spec_helper"
require "../../src/matter/transport/udp_transport"

private class MultihomedMulticastCapture < Matter::Transport::UDPTransport
  getter sent = [] of Tuple(UInt32, Bytes, Socket::IPAddress)
  property failing_interface : UInt32? = nil

  def initialize
    super(port: 0)
  end

  protected def ipv6_multicast_interface_ids : Array(UInt32)
    [2_u32, 3_u32]
  end

  protected def send_on_multicast_interface(data : Bytes | Slice(UInt8),
                                            destination : Socket::IPAddress,
                                            index : UInt32) : Nil
    raise IO::Error.new("unavailable interface") if index == @failing_interface
    @sent << {index, data.to_slice.dup, destination}
  end
end

describe Matter::Transport::UDPTransport do
  it "sends the same group datagram on every active IPv6 interface" do
    require_udp_sockets!
    transport = MultihomedMulticastCapture.new
    payload = Bytes[1, 2, 3]
    destination = Matter::Transport::GroupMulticast.iana_address

    transport.send_raw(payload, destination)

    transport.sent.map(&.[0]).should eq([2_u32, 3_u32])
    transport.sent.map(&.[1]).should eq([payload, payload])
    transport.sent.map(&.[2]).should eq([destination, destination])
  ensure
    transport.try(&.close)
  end

  it "reaches other interfaces when one multicast interface is unavailable" do
    require_udp_sockets!
    transport = MultihomedMulticastCapture.new
    transport.failing_interface = 2_u32

    transport.send_raw(Bytes[4, 5], Matter::Transport::GroupMulticast.iana_address)

    transport.sent.map(&.[0]).should eq([3_u32])
  ensure
    transport.try(&.close)
  end
end
