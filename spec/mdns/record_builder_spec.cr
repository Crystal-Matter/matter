require "../spec_helper"
require "../../src/matter/mdns/record_builder"

describe Matter::MDNS::RecordBuilder do
  describe "PTR record" do
    it "builds PTR record without cache-flush" do
      record = Matter::MDNS::RecordBuilder.build_ptr(
        service: "_matterc._udp.local",
        instance: "TestDevice._matterc._udp.local",
        ttl: 120.seconds,
        cache_flush: false
      )

      record.name.should eq("_matterc._udp.local")
      record.type.should eq(Matter::MDNS::RecordBuilder::TYPE_PTR)
      record.class_code.should eq(Matter::MDNS::RecordBuilder::CLASS_IN)
      record.ttl.should eq(120.seconds)
      record.resource_data.should_not be_empty
    end

    it "builds PTR record with cache-flush" do
      record = Matter::MDNS::RecordBuilder.build_ptr(
        service: "_matterc._udp.local",
        instance: "TestDevice._matterc._udp.local",
        ttl: 120.seconds,
        cache_flush: true
      )

      record.class_code.should eq(Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH)
    end

    it "encodes instance name in resource data" do
      record = Matter::MDNS::RecordBuilder.build_ptr(
        service: "_matterc._udp.local",
        instance: "Test._matterc._udp.local",
        ttl: 120.seconds
      )

      # Resource data should contain encoded domain name
      # Format: length-byte + label + ... + 0x00
      record.resource_data.should_not be_empty
      record.resource_data[0].should eq(4) # "Test" has 4 characters
    end
  end

  describe "SRV record" do
    it "builds SRV record" do
      record = Matter::MDNS::RecordBuilder.build_srv(
        instance: "TestDevice._matterc._udp.local",
        port: 5540,
        target: "test-device.local",
        ttl: 120.seconds
      )

      record.name.should eq("TestDevice._matterc._udp.local")
      record.type.should eq(Matter::MDNS::RecordBuilder::TYPE_SRV)
      record.class_code.should eq(Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH)
      record.ttl.should eq(120.seconds)
    end

    it "encodes priority, weight, port correctly" do
      record = Matter::MDNS::RecordBuilder.build_srv(
        instance: "Test._matterc._udp.local",
        port: 5540,
        target: "test.local",
        ttl: 120.seconds,
        priority: 10_u16,
        weight: 20_u16
      )

      io = IO::Memory.new(record.resource_data)
      priority = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
      weight = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
      port = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)

      priority.should eq(10)
      weight.should eq(20)
      port.should eq(5540)
    end

    it "always uses cache-flush for SRV" do
      record = Matter::MDNS::RecordBuilder.build_srv(
        instance: "Test._matterc._udp.local",
        port: 5540,
        target: "test.local",
        ttl: 120.seconds
      )

      # Cache-flush bit should be set (0x8001)
      record.class_code.should eq(0x8001_u16)
    end
  end

  describe "TXT record" do
    it "builds TXT record with multiple entries" do
      txt_records = {
        "VP" => "65521+32768",
        "D"  => "3840",
        "CM" => "1",
      }

      record = Matter::MDNS::RecordBuilder.build_txt(
        instance: "TestDevice._matterc._udp.local",
        txt_records: txt_records,
        ttl: 120.seconds
      )

      record.name.should eq("TestDevice._matterc._udp.local")
      record.type.should eq(Matter::MDNS::RecordBuilder::TYPE_TXT)
      record.class_code.should eq(Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH)
      record.ttl.should eq(120.seconds)
    end

    it "encodes key=value pairs correctly" do
      txt_records = {
        "VP" => "65521+32768",
        "D"  => "3840",
      }

      record = Matter::MDNS::RecordBuilder.build_txt(
        instance: "Test._matterc._udp.local",
        txt_records: txt_records,
        ttl: 120.seconds
      )

      # TXT records format: length + "key=value"
      io = IO::Memory.new(record.resource_data)

      # Read first record
      length1 = io.read_byte.as(UInt8)
      txt1 = Bytes.new(length1)
      io.read_fully(txt1)
      txt1_str = String.new(txt1)

      # Should be one of the two entries
      (txt1_str == "VP=65521+32768" || txt1_str == "D=3840").should be_true
    end

    it "handles empty TXT records" do
      record = Matter::MDNS::RecordBuilder.build_txt(
        instance: "Test._matterc._udp.local",
        txt_records: {} of String => String,
        ttl: 120.seconds
      )

      # Empty TXT record should have single 0 byte
      record.resource_data.size.should eq(1)
      record.resource_data[0].should eq(0)
    end

    it "always uses cache-flush for TXT" do
      record = Matter::MDNS::RecordBuilder.build_txt(
        instance: "Test._matterc._udp.local",
        txt_records: {"key" => "value"},
        ttl: 120.seconds
      )

      record.class_code.should eq(0x8001_u16)
    end
  end

  describe "A record" do
    it "builds A record for IPv4 address" do
      ip = Socket::IPAddress.new("192.168.1.100", 0)

      record = Matter::MDNS::RecordBuilder.build_a(
        hostname: "test-device.local",
        ip: ip,
        ttl: 120.seconds
      )

      record.name.should eq("test-device.local")
      record.type.should eq(Matter::MDNS::RecordBuilder::TYPE_A)
      record.class_code.should eq(Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH)
      record.ttl.should eq(120.seconds)
    end

    it "encodes IPv4 address correctly" do
      ip = Socket::IPAddress.new("192.168.1.100", 0)

      record = Matter::MDNS::RecordBuilder.build_a(
        hostname: "test.local",
        ip: ip,
        ttl: 120.seconds
      )

      # IPv4 address should be 4 bytes
      record.resource_data.size.should eq(4)
      record.resource_data[0].should eq(192)
      record.resource_data[1].should eq(168)
      record.resource_data[2].should eq(1)
      record.resource_data[3].should eq(100)
    end

    it "raises error for non-IPv4 address" do
      ipv6 = Socket::IPAddress.new("fe80::1", 0)

      expect_raises(ArgumentError, "IP address must be IPv4") do
        Matter::MDNS::RecordBuilder.build_a(
          hostname: "test.local",
          ip: ipv6,
          ttl: 120.seconds
        )
      end
    end

    it "always uses cache-flush for A" do
      ip = Socket::IPAddress.new("192.168.1.100", 0)

      record = Matter::MDNS::RecordBuilder.build_a(
        hostname: "test.local",
        ip: ip,
        ttl: 120.seconds
      )

      record.class_code.should eq(0x8001_u16)
    end
  end

  describe "AAAA record" do
    it "encodes loopback and scoped link-local IPv6 addresses" do
      loopback = Matter::MDNS::RecordBuilder.build_aaaa("node.local", Socket::IPAddress.new("::1", 0), 120.seconds)
      loopback.resource_data.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])

      scoped = Matter::MDNS::RecordBuilder.build_aaaa("node.local", Socket::IPAddress.new("fe80::1%1", 0), 120.seconds)
      scoped.resource_data.should eq(Bytes[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    end

    it "builds AAAA record for IPv6 address" do
      ip = Socket::IPAddress.new("fe80::1", 0)

      record = Matter::MDNS::RecordBuilder.build_aaaa(
        hostname: "test-device.local",
        ip: ip,
        ttl: 120.seconds
      )

      record.name.should eq("test-device.local")
      record.type.should eq(Matter::MDNS::RecordBuilder::TYPE_AAAA)
      record.class_code.should eq(Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH)
      record.ttl.should eq(120.seconds)
    end

    it "encodes IPv6 address correctly" do
      ip = Socket::IPAddress.new("fe80::1", 0)

      record = Matter::MDNS::RecordBuilder.build_aaaa(
        hostname: "test.local",
        ip: ip,
        ttl: 120.seconds
      )

      # IPv6 address should be 16 bytes
      record.resource_data.size.should eq(16)
    end

    it "raises error for non-IPv6 address" do
      ipv4 = Socket::IPAddress.new("192.168.1.100", 0)

      expect_raises(ArgumentError, "IP address must be IPv6") do
        Matter::MDNS::RecordBuilder.build_aaaa(
          hostname: "test.local",
          ip: ipv4,
          ttl: 120.seconds
        )
      end
    end

    it "always uses cache-flush for AAAA" do
      ip = Socket::IPAddress.new("fe80::1", 0)

      record = Matter::MDNS::RecordBuilder.build_aaaa(
        hostname: "test.local",
        ip: ip,
        ttl: 120.seconds
      )

      record.class_code.should eq(0x8001_u16)
    end
  end

  describe "NSEC record" do
    it "builds NSEC record" do
      types = [
        Matter::MDNS::RecordBuilder::TYPE_A,
        Matter::MDNS::RecordBuilder::TYPE_SRV,
        Matter::MDNS::RecordBuilder::TYPE_TXT,
      ]

      record = Matter::MDNS::RecordBuilder.build_nsec(
        name: "test-device.local",
        next_domain: "test-device.local",
        types: types,
        ttl: 120.seconds
      )

      record.name.should eq("test-device.local")
      record.type.should eq(47_u16) # NSEC type
      record.class_code.should eq(Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH)
      record.ttl.should eq(120.seconds)
    end

    it "encodes type bitmap correctly" do
      types = [1_u16, 12_u16, 16_u16] # A, PTR, TXT

      record = Matter::MDNS::RecordBuilder.build_nsec(
        name: "test.local",
        next_domain: "test.local",
        types: types,
        ttl: 120.seconds
      )

      # NSEC resource data contains:
      # - Next domain name (encoded)
      # - Window block (1 byte)
      # - Bitmap length (1 byte)
      # - Bitmap (variable)
      record.resource_data.should_not be_empty
    end
  end

  describe "cache-flush bit" do
    it "uses CLASS_IN for non-cache-flush records" do
      Matter::MDNS::RecordBuilder::CLASS_IN.should eq(0x0001_u16)
    end

    it "uses CLASS_IN_CACHE_FLUSH for unique records" do
      Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH.should eq(0x8001_u16)
    end

    it "cache-flush bit is high bit of class field" do
      cache_flush_bit = Matter::MDNS::RecordBuilder::CLASS_IN_CACHE_FLUSH & 0x8000
      cache_flush_bit.should eq(0x8000_u16)
    end
  end

  describe "domain name encoding" do
    it "encodes simple domain name" do
      # This is tested indirectly through PTR record
      record = Matter::MDNS::RecordBuilder.build_ptr(
        service: "_test._tcp.local",
        instance: "device._test._tcp.local",
        ttl: 120.seconds
      )

      # Should encode: 6device5_test4_tcp5local0
      # Length bytes: [6, ...], then [5, ...], etc.
      record.resource_data[0].should eq(6) # "device" length
    end

    it "encodes multi-label domain name" do
      record = Matter::MDNS::RecordBuilder.build_ptr(
        service: "_test._tcp.local",
        instance: "my-device._test._tcp.local",
        ttl: 120.seconds
      )

      # First label should be "my-device" (9 characters)
      record.resource_data[0].should eq(9)
    end

    it "terminates with null byte" do
      record = Matter::MDNS::RecordBuilder.build_ptr(
        service: "_test._tcp.local",
        instance: "a._test._tcp.local",
        ttl: 120.seconds
      )

      # Last byte should be 0 (null terminator)
      record.resource_data[-1].should eq(0)
    end
  end
end
