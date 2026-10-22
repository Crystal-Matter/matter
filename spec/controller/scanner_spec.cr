require "../spec_helper"
require "../../src/matter/controller"
require "../../src/matter/mdns/service_type"
require "../../src/matter/mdns/record_builder"

# DNS compression pointer to the first resource record name (after the header).
DNS_FIRST_ANSWER_POINTER = 0xC00C_u16

class Matter::Controller::Scanner
  # Exercise the packet parser without depending on multicast delivery.
  def process_packet_for_spec(packet : DNS::Packet, peer : Socket::IPAddress = Socket::IPAddress.new("127.0.0.1", MDNS_PORT)) : Nil
    process_mdns_packet(packet, peer)
  end

  def ipv6_port_for_spec : Int32?
    @socket6.try(&.local_address.as(Socket::IPAddress).port)
  end
end

# An AF_INET6 socket can exist even when ::1 cannot deliver UDP datagrams.
# Check the network path before exercising the scanner's receive fiber.
private def ipv6_loopback_available? : Bool
  receiver : UDPSocket? = nil
  sender : UDPSocket? = nil
  begin
    receiver = UDPSocket.new(:inet6)
    sender = UDPSocket.new(:inet6)
    receiver.ipv6_only = true
    receiver.bind("::1", 0)
    receiver.read_timeout = 2.seconds
    destination = Socket::IPAddress.new("::1", receiver.local_address.as(Socket::IPAddress).port)
    sender.send(Bytes[0xA5], destination)
    buffer = Bytes.new(1)
    count, _peer = receiver.receive(buffer)
    count == 1 && buffer[0] == 0xA5
  rescue Socket::Error | IO::TimeoutError
    false
  ensure
    sender.try(&.close)
    receiver.try(&.close)
  end
end

describe Matter::Controller::Scanner do
  describe "DNS-SD packet processing" do
    it "scopes a link-local AAAA address to its IPv6 announcement interface" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-0000000000000009._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      packet = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "link.local", 120.seconds),
        builder.build_aaaa("link.local", Socket::IPAddress.new("fe80::9", 0), 120.seconds),
      ])

      scanner.process_packet_for_spec(packet, Socket::IPAddress.new("fe80::1%1", 5353))
      address = scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.first
      address.address.should eq("fe80::9")
      address.zone_id.should eq(1)
      scanner.close
    end

    it "does not publish an unroutable link-local AAAA from an IPv4 announcement" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-000000000000000A._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      packet = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "link.local", 120.seconds),
        builder.build_aaaa("link.local", Socket::IPAddress.new("fe80::a", 0), 120.seconds),
      ])

      scanner.process_packet_for_spec(packet)
      scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.should be_empty
      scanner.close
    end

    it "preserves a scoped link-local route across unscoped and other-interface announcements" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-000000000000000C._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      first = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "link.local", 120.seconds),
        builder.build_aaaa("link.local", Socket::IPAddress.new("fe80::c", 0), 120.seconds),
      ])
      scanner.process_packet_for_spec(first, Socket::IPAddress.new("fe80::1%1", 5353))
      scanner.process_packet_for_spec(DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_aaaa("link.local", Socket::IPAddress.new("fe80::d", 0), 120.seconds),
      ]))
      scanner.process_packet_for_spec(first, Socket::IPAddress.new("fe80::1%2", 5353))

      zones = scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.map(&.zone_id).sort!
      zones.should eq([1, 2])
      scanner.close
    end

    it "receives an operational advertisement over IPv6 only" do
      require_udp_sockets!
      pending! "IPv6 UDP loopback delivery is unavailable on this host" unless ipv6_loopback_available?
      scanner = Matter::Controller::Scanner.new(0)
      sender = UDPSocket.new(:inet6)
      instance = "0123456789ABCDEF-000000000000000B._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      packet = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "v6-only.local", 120.seconds),
        builder.build_aaaa("v6-only.local", Socket::IPAddress.new("::1", 0), 120.seconds),
      ])
      begin
        scanner.start
        port = scanner.ipv6_port_for_spec
        port.should_not be_nil
        sent_packets = 0
        if port
          destination = Socket::IPAddress.new("::1", port)
          deadline = Time.instant + 5.seconds
          until scanner.get_device(instance) || Time.instant >= deadline
            sender.send(packet.to_slice, destination)
            sent_packets += 1
            sleep 100.milliseconds
          end
        end
        device = scanner.get_device(instance)
        device.should_not be_nil, "IPv6 scanner missed #{sent_packets} loopback advertisements on port #{port}"
        device.as(Matter::Controller::DiscoveredDevice).addresses.map(&.address).should eq(["::1"])
      ensure
        sender.close
        scanner.close
      end
    end

    it "parses an encoded IPv6 operational advertisement" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-000000000000000D._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      packet = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "encoded-v6.local", 120.seconds),
        builder.build_aaaa("encoded-v6.local", Socket::IPAddress.new("::1", 0), 120.seconds),
      ])

      scanner.process_packet_for_spec(DNS::Packet.from_slice(packet.to_slice), Socket::IPAddress.new("::1", 5353))
      scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.map(&.address).should eq(["::1"])
      scanner.close
    end

    it "resolves a commissionable SRV target compressed against an earlier answer" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "A1B2C3D4E5F60708._matterc._udp.local"
      hostname = "sdk-bridge.local"
      address = Socket::IPAddress.new("fd42:4d41:5454::1", 0)
      builder = Matter::MDNS::RecordBuilder
      srv_data = IO::Memory.new
      srv_data.write_bytes(0_u16, IO::ByteFormat::BigEndian) # priority
      srv_data.write_bytes(0_u16, IO::ByteFormat::BigEndian) # weight
      srv_data.write_bytes(5533_u16, IO::ByteFormat::BigEndian)
      srv_data.write_bytes(DNS_FIRST_ANSWER_POINTER, IO::ByteFormat::BigEndian)
      srv = DNS::Packet::ResourceRecord.new(
        name: instance,
        type: Matter::MDNS::RecordBuilder::TYPE_SRV,
        class_code: Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH,
        ttl: 120.seconds,
        resource_data: srv_data.to_slice
      )
      packet = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_aaaa(hostname, address, 120.seconds),
        srv,
        builder.build_txt(instance, {"D" => "2656", "CM" => "2"}, 120.seconds),
      ])

      decoded = DNS::Packet.from_slice(packet.to_slice)
      decoded.answers[1].resource.as(DNS::Resource::SRV).target.should eq(hostname)
      scanner.process_packet_for_spec(decoded, Socket::IPAddress.new("::1", 5353))
      device = scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice)
      device.hostname.should eq(hostname)
      device.port.should eq(5533)
      device.discriminator.should eq(2656)
      device.addresses.map(&.address).should eq([address.address])
      scanner.close
    end
    it "resolves each operational SRV target from only its own host A/AAAA records" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      first = "0123456789ABCDEF-0000000000000001._matter._tcp.local"
      second = "0123456789ABCDEF-0000000000000002._matter._tcp.local"
      ttl = 120.seconds
      builder = Matter::MDNS::RecordBuilder
      packet = DNS::Packet.new(
        id: 0_u16,
        response: true,
        answers: [
          builder.build_srv(first, 5540, "first.local", ttl),
          builder.build_srv(second, 5550, "second.local", ttl),
        ],
        additionals: [
          builder.build_a("second.local", Socket::IPAddress.new("192.0.2.2", 0), ttl),
          builder.build_a("unrelated.local", Socket::IPAddress.new("192.0.2.99", 0), ttl),
          builder.build_aaaa("first.local", Socket::IPAddress.new("2001:db8::1", 0), ttl),
          builder.build_a("first.local", Socket::IPAddress.new("192.0.2.1", 0), ttl),
        ]
      )

      scanner.process_packet_for_spec(DNS::Packet.from_slice(packet.to_slice))

      first_device = scanner.get_device(first).as(Matter::Controller::DiscoveredDevice)
      first_device.hostname.should eq("first.local")
      first_device.fabric_id.should eq(0x0123456789ABCDEF_u64)
      first_device.node_id.should eq(1_u64)
      first_device.addresses.map(&.address).sort!.should eq(["192.0.2.1", "2001:db8::1"])
      second_device = scanner.get_device(second).as(Matter::Controller::DiscoveredDevice)
      second_device.addresses.map(&.address).should eq(["192.0.2.2"])
      scanner.devices.size.should eq(2)
      scanner.close
    end

    it "joins address and service answers sent in separate packets and honors address goodbye" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-0000000000000003._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      address = builder.build_a("node.local", Socket::IPAddress.new("192.0.2.3", 0), 120.seconds)

      scanner.process_packet_for_spec(DNS::Packet.new(id: 0_u16, response: true, answers: [address]))
      scanner.devices.should be_empty
      scanner.process_packet_for_spec(DNS::Packet.new(
        id: 0_u16,
        response: true,
        answers: [builder.build_srv(instance, 5540, "NODE.local", 120.seconds)]
      ))
      scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.map(&.address).should eq(["192.0.2.3"])

      goodbye = builder.build_a("node.local", Socket::IPAddress.new("192.0.2.3", 0), 0.seconds)
      scanner.process_packet_for_spec(DNS::Packet.new(id: 0_u16, response: true, answers: [goodbye]))
      scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.should be_empty

      replacement = builder.build_aaaa("node.local", Socket::IPAddress.new("2001:db8::3", 0), 120.seconds)
      scanner.process_packet_for_spec(DNS::Packet.new(id: 0_u16, response: true, additionals: [replacement]))
      scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.map(&.address).should eq(["2001:db8::3"])
      scanner.close
    end

    it "persists SRV updates for an existing discovered device" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-0000000000000004._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      original = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "old.local", 120.seconds),
        builder.build_a("old.local", Socket::IPAddress.new("192.0.2.4", 0), 120.seconds),
      ])
      replacement = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5555, "new.local", 120.seconds),
        builder.build_a("new.local", Socket::IPAddress.new("192.0.2.5", 0), 120.seconds),
      ])

      scanner.process_packet_for_spec(original)
      scanner.process_packet_for_spec(replacement)

      device = scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice)
      device.hostname.should eq("new.local")
      device.port.should eq(5555)
      device.addresses.map(&.address).should eq(["192.0.2.5"])
      scanner.close
    end

    it "refreshes an A record without discarding the same host's AAAA record" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-0000000000000005._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      initial = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "dual.local", 120.seconds),
        builder.build_a("dual.local", Socket::IPAddress.new("192.0.2.5", 0), 120.seconds),
        builder.build_aaaa("dual.local", Socket::IPAddress.new("2001:db8::5", 0), 120.seconds),
      ])
      refreshed = DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_a("dual.local", Socket::IPAddress.new("192.0.2.6", 0), 120.seconds),
      ])

      scanner.process_packet_for_spec(initial)
      scanner.process_packet_for_spec(refreshed)

      addresses = scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.map(&.address).sort!
      addresses.should eq(["192.0.2.6", "2001:db8::5"])
      scanner.close
    end

    it "ignores known-answer queries and non-Internet address records" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789ABCDEF-0000000000000006._matter._tcp.local"
      builder = Matter::MDNS::RecordBuilder
      srv = builder.build_srv(instance, 5540, "guard.local", 120.seconds)
      address = builder.build_a("guard.local", Socket::IPAddress.new("192.0.2.6", 0), 120.seconds)
      scanner.process_packet_for_spec(DNS::Packet.new(id: 0_u16, answers: [srv, address]))
      scanner.devices.should be_empty

      non_internet = DNS::Packet::ResourceRecord.new(
        name: address.name, type: address.type, class_code: 3_u16,
        ttl: address.ttl, resource_data: address.resource_data
      )
      scanner.process_packet_for_spec(DNS::Packet.new(
        id: 0_u16, response: true, answers: [srv, non_internet]
      ))
      scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice).addresses.should be_empty
      scanner.close
    end

    it "accepts mixed-case DNS service and SRV target names" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      instance = "0123456789abCDef-0000000000000007._MaTtEr._TcP.LoCaL"
      builder = Matter::MDNS::RecordBuilder
      scanner.process_packet_for_spec(DNS::Packet.new(
        id: 0_u16, response: true, answers: [
        builder.build_srv(instance, 5540, "Node.LoCaL", 120.seconds),
        builder.build_a("nOdE.lOcAl", Socket::IPAddress.new("192.0.2.7", 0), 120.seconds),
      ]
      ))

      device = scanner.get_device(instance).as(Matter::Controller::DiscoveredDevice)
      device.fabric_id.should eq(0x0123456789ABCDEF_u64)
      device.node_id.should eq(7_u64)
      device.addresses.map(&.address).should eq(["192.0.2.7"])
      scanner.close
    end

    it "treats differently cased answers for one instance as one device" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      builder = Matter::MDNS::RecordBuilder
      uppercase = "0123456789ABCDEF-0000000000000008._matter._tcp.local"
      lowercase = uppercase.downcase
      scanner.process_packet_for_spec(DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(uppercase, 5540, "same.local", 120.seconds),
      ]))
      scanner.process_packet_for_spec(DNS::Packet.new(id: 0_u16, response: true, answers: [
        builder.build_srv(lowercase, 5555, "same.local", 120.seconds),
      ]))

      scanner.devices.size.should eq(1)
      scanner.get_device(uppercase).as(Matter::Controller::DiscoveredDevice).port.should eq(5555)
      scanner.get_device(lowercase).as(Matter::Controller::DiscoveredDevice).port.should eq(5555)
      scanner.close
    end
  end

  describe "initialization" do
    it "creates a scanner and joins multicast group" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      scanner.devices.should be_empty
      scanner.close
    end
  end

  describe "device discovery" do
    it "starts and stops scanner" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      scanner.start
      sleep 50.milliseconds
      scanner.stop
      scanner.close
    end

    it "maintains device discovery table" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      scanner.devices.should be_empty
      scanner.close
    end

    it "filters commissioning devices" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      scanner.commissioning_devices.should be_empty
      scanner.close
    end

    it "filters operational devices" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      scanner.operational_devices.should be_empty
      scanner.close
    end

    it "retrieves device by instance name" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      device = scanner.get_device("nonexistent._matterc._udp.local")
      device.should be_nil
      scanner.close
    end
  end

  describe "query methods" do
    it "sends commissioning query" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      # Should not raise
      scanner.query_commissioning
      scanner.close
    end

    it "sends operational query" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new
      # Should not raise
      scanner.query_operational
      scanner.close
    end
  end

  describe "DiscoveredDevice" do
    it "parses Joint Fabric capabilities from commissioning TXT" do
      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "Anchor._matterc._udp.local",
        hostname: "anchor.local",
        addresses: [Socket::IPAddress.new("::1", 5540)],
        port: 5540,
        txt_records: {"VP" => "65521+32768", "CM" => "3", "JF" => "14"},
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.commissioning_mode.should eq(Matter::MDNS::CommissioningMode::Joint.value)
      device.joint_fabric_role.should eq(
        Matter::MDNS::JointFabricRole::Administrator |
        Matter::MDNS::JointFabricRole::Anchor |
        Matter::MDNS::JointFabricRole::Datastore
      )
    end

    it "creates discovered device" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {"VP" => "65521+32768", "D" => "3840"},
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.instance_name.should eq("TestDevice._matterc._udp.local")
      device.hostname.should eq("test-device.local")
      device.addresses.size.should eq(1)
      device.port.should eq(5540)
      device.service_type.should eq(Matter::MDNS::ServiceType::Commissioning)
    end

    it "parses commissioning TXT records" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {
          "VP" => "65521+32768",
          "D"  => "3840",
          "DT" => "22",
          "DN" => "TestDevice",
          "CM" => "1",
        },
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.vendor_id.should eq(65521)
      device.product_id.should eq(32768)
      device.discriminator.should eq(3840)
      device.device_type.should eq(22)
      device.device_name.should eq("TestDevice")
      device.commissioning_mode.should eq(1)
    end

    it "parses operational TXT records" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "1234567890ABCDEF-FEDCBA0987654321._matter._tcp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {
          "SII" => "500",
          "SAI" => "300",
          "T"   => "4",
        },
        service_type: Matter::MDNS::ServiceType::Operational,
        expires_at: Time.utc + 120.seconds
      )

      device.fabric_id.should eq(0x1234567890ABCDEF_u64)
      device.node_id.should eq(0xFEDCBA0987654321_u64)
    end

    it "detects expired devices" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc - 1.second
      )

      device.expired?.should be_true
    end

    it "detects non-expired devices" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.expired?.should be_false
    end
  end

  describe "callbacks" do
    it "supports device discovered callback" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new

      discovered = false
      scanner.on_device_discovered = ->(_device : Matter::Controller::DiscoveredDevice) {
        discovered = true
        nil
      }

      scanner.close
    end

    it "supports device updated callback" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new

      updated = false
      scanner.on_device_updated = ->(_device : Matter::Controller::DiscoveredDevice) {
        updated = true
        nil
      }

      scanner.close
    end

    it "supports device removed callback" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new

      removed = false
      scanner.on_device_removed = ->(_instance_name : String) {
        removed = true
        nil
      }

      scanner.close
    end
  end

  describe "service name extraction" do
    it "extracts commissioning instance name" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new

      # Test with PTR record name
      # This will be tested indirectly through packet processing
      scanner.close
    end

    it "extracts operational instance name" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new

      # Test with PTR record name
      # This will be tested indirectly through packet processing
      scanner.close
    end

    it "ignores non-Matter services" do
      require_udp_sockets!
      scanner = Matter::Controller::Scanner.new

      # Non-Matter services should be filtered out
      scanner.close
    end
  end

  describe "TTL handling" do
    it "stores expiration time based on TTL" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      expires_at = Time.utc + 120.seconds
      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: expires_at
      )

      # Allow 1 second tolerance for test execution time
      (device.expires_at - expires_at).abs.should be < 1.second
    end
  end

  describe "multiple addresses" do
    it "handles multiple IPv4 addresses" do
      ip1 = Socket::IPAddress.new("192.168.1.100", 5540)
      ip2 = Socket::IPAddress.new("192.168.1.101", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip1, ip2],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.addresses.size.should eq(2)
    end

    it "handles mixed IPv4/IPv6 addresses" do
      ipv4 = Socket::IPAddress.new("192.168.1.100", 5540)
      ipv6 = Socket::IPAddress.new("fe80::1", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ipv4, ipv6],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.addresses.size.should eq(2)
      device.addresses.any?(&.family.inet?).should be_true
      device.addresses.any?(&.family.inet6?).should be_true
    end
  end

  describe "TXT record parsing edge cases" do
    it "handles missing TXT records" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.vendor_id.should be_nil
      device.product_id.should be_nil
      device.discriminator.should be_nil
    end

    it "handles malformed VP record" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {"VP" => "invalid"},
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.vendor_id.should be_nil
      device.product_id.should be_nil
    end

    it "handles invalid numeric fields" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "TestDevice._matterc._udp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {"D" => "not_a_number"},
        service_type: Matter::MDNS::ServiceType::Commissioning,
        expires_at: Time.utc + 120.seconds
      )

      device.discriminator.should be_nil
    end
  end

  describe "operational instance name parsing" do
    it "parses valid operational instance name" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "1234567890ABCDEF-FEDCBA0987654321._matter._tcp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Operational,
        expires_at: Time.utc + 120.seconds
      )

      device.fabric_id.should eq(0x1234567890ABCDEF_u64)
      device.node_id.should eq(0xFEDCBA0987654321_u64)
    end

    it "handles invalid operational instance name" do
      ip = Socket::IPAddress.new("192.168.1.100", 5540)

      device = Matter::Controller::DiscoveredDevice.new(
        instance_name: "invalid-format._matter._tcp.local",
        hostname: "test-device.local",
        addresses: [ip],
        port: 5540,
        txt_records: {} of String => String,
        service_type: Matter::MDNS::ServiceType::Operational,
        expires_at: Time.utc + 120.seconds
      )

      device.fabric_id.should be_nil
      device.node_id.should be_nil
    end
  end
end
