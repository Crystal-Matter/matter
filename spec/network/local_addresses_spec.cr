require "../spec_helper"

describe Matter::Network do
  describe ".local_ip_addresses" do
    it "advertises a local IPv6 ULA without requiring a public IPv6 route" do
      candidates = [
        Socket::IPAddress.new("::1", 0),
        Socket::IPAddress.new("fd42:4d41:5454::2", 1234),
        Socket::IPAddress.new("192.168.1.20", 8080),
        Socket::IPAddress.new("0.0.0.0", 0),
      ]

      Matter::Network.select_local_ip_addresses(candidates).should eq([
        Socket::IPAddress.new("fd42:4d41:5454::2", 0),
        Socket::IPAddress.new("192.168.1.20", 0),
      ])
    end

    it "uses loopback only when there are no usable interface addresses" do
      candidates = [Socket::IPAddress.new("::1", 0), Socket::IPAddress.new("127.0.0.1", 0)]

      Matter::Network.select_local_ip_addresses(candidates).should eq([Matter::Network::LOOPBACK_ADDRESS])
    end

    it "returns active interface addresses with an unspecified port" do
      require_udp_sockets!

      addresses = Matter::Network.local_ip_addresses
      addresses.should_not be_empty

      pending! "no non-loopback interface in this environment" if addresses.all?(&.loopback?)

      addresses.each do |address|
        address.loopback?.should be_false
        address.port.should eq(Matter::Network::UNSPECIFIED_PORT)
      end
    end

    it "never returns duplicate addresses" do
      require_udp_sockets!

      addresses = Matter::Network.local_ip_addresses
      addresses.uniq.size.should eq(addresses.size)
    end
  end

  {% if flag?(:win32) %}
    describe ".local_ip_addresses_by_interface" do
      it "enumerates active Windows adapters by their real interface index" do
        require_udp_sockets!

        indexed = Matter::Network.local_ip_addresses_by_interface
        indexed.should_not be_empty
        local = Matter::Network.local_ip_addresses

        indexed.each do |index, addresses|
          index.should be > 0_u32
          addresses.should_not be_empty
          addresses.uniq.size.should eq(addresses.size)
          addresses.each do |address|
            address.loopback?.should be_false
            address.unspecified?.should be_false
            address.port.should eq(Matter::Network::UNSPECIFIED_PORT)
            local.should contain(address)
          end
        end
      end
    end
  {% end %}
end
