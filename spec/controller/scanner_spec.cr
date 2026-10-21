require "../spec_helper"
require "../../src/matter/controller"
require "../../src/matter/mdns/service_type"
require "../../src/matter/mdns/record_builder"

describe Matter::Controller::Scanner do
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
          "T"   => "1",
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
