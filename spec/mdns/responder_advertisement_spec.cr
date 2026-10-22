require "../spec_helper"
require "../support/mdns_responder_helpers"

describe Matter::MDNS::Responder do
  describe "initialization" do
    it "creates a responder with default settings" do
      require_udp_sockets!
      responder = Matter::MDNS::Responder.new
      responder.port.should eq(5353)
      responder.hostname.should eq("matter-device.local")
      responder.ip_addresses.should be_empty
    end

    it "creates a responder with custom settings" do
      require_udp_sockets!
      ip = Socket::IPAddress.new("192.168.1.100", 0)
      responder = Matter::MDNS::Responder.new(
        port: 5540,
        hostname: "my-device.local",
        ip_addresses: [ip]
      )

      responder.port.should eq(5540)
      responder.hostname.should eq("my-device.local")
      responder.ip_addresses.size.should eq(1)
    end
  end

  describe "commissioning advertisement" do
    it "advertises commissioning service" do
      require_udp_sockets!
      ip = Socket::IPAddress.new("192.168.1.100", 0)
      responder = Matter::MDNS::Responder.new(
        hostname: "test-device.local",
        ip_addresses: [ip]
      )

      info = Matter::MDNS::CommissioningInfo.new(
        device_name: "TestDevice",
        vendor_id: 0xFFF1_u16,
        product_id: 0x8000_u16,
        discriminator: 3840_u16,
        device_type: 0x0016_u32,
        commissioning_mode: Matter::MDNS::CommissioningMode::Basic
      )

      # Should not raise
      responder.advertise_commissioning(info, port: 5540)
    end

    it "includes correct TXT records" do
      info = Matter::MDNS::CommissioningInfo.new(
        device_name: "TestDevice",
        vendor_id: 0xFFF1_u16,
        product_id: 0x8000_u16,
        discriminator: 3840_u16,
        device_type: 0x0016_u32,
        commissioning_mode: Matter::MDNS::CommissioningMode::Basic,
        pairing_hint: 0x01_u16,
        pairing_instruction: "Scan QR code"
      )

      txt_records = info.to_txt_records
      txt_records["VP"].should eq("65521+32768")
      txt_records["D"].should eq("3840")
      txt_records["CM"].should eq("1")
      txt_records["DT"].should eq("22")
      txt_records["DN"].should eq("TestDevice")
      txt_records["PH"].should eq("1")
      txt_records["PI"].should eq("Scan QR code")
    end

    it "advertises a Joint Commissioning Method window and JF roles" do
      info = Matter::MDNS::CommissioningInfo.new(
        device_name: "Anchor",
        vendor_id: 0xFFF1_u16,
        product_id: 0x8000_u16,
        discriminator: 3840_u16,
        device_type: 0x0016_u32,
        commissioning_mode: Matter::MDNS::CommissioningMode::Joint,
        joint_fabric_role: Matter::MDNS::JointFabricRole::Administrator |
                           Matter::MDNS::JointFabricRole::Anchor |
                           Matter::MDNS::JointFabricRole::Datastore
      )

      info.to_txt_records["CM"].should eq("3")
      info.to_txt_records["JF"].should eq("14")
      info.to_txt_records["VP"].should eq("65521+32768")
    end
  end

  describe "operational advertisement" do
    it "advertises operational service" do
      require_udp_sockets!
      ip = Socket::IPAddress.new("192.168.1.100", 0)
      responder = Matter::MDNS::Responder.new(
        hostname: "test-device.local",
        ip_addresses: [ip]
      )

      info = Matter::MDNS::OperationalInfo.new(
        compressed_fabric_id: compressed_fabric_id_bytes(0x0000000000000001_u64),
        node_id: 0x0000000000000001_u64,
        session_idle_interval: 500_u32,
        session_active_interval: 300_u32,
        tcp_supported: false
      )

      # Should not raise
      responder.advertise_operational(info, port: 5540)
    end

    it "includes correct TXT records for operational" do
      info = Matter::MDNS::OperationalInfo.new(
        compressed_fabric_id: compressed_fabric_id_bytes(0x0000000000000001_u64),
        node_id: 0x0000000000000001_u64,
        session_idle_interval: 500_u32,
        session_active_interval: 300_u32,
        tcp_supported: true
      )

      txt_records = info.to_txt_records
      txt_records["SII"].should eq("500")
      txt_records["SAI"].should eq("300")
      txt_records["T"].should eq("4")
    end

    it "omits TCP flag when not supported" do
      info = Matter::MDNS::OperationalInfo.new(
        compressed_fabric_id: compressed_fabric_id_bytes(0x0000000000000001_u64),
        node_id: 0x0000000000000001_u64,
        tcp_supported: false
      )

      txt_records = info.to_txt_records
      txt_records.has_key?("T").should be_false
    end
  end

  describe "service names" do
    it "generates correct commissioning instance name" do
      instance = Matter::MDNS::ServiceNames.commissioning_instance("DD200C20D25AE5F7")
      instance.should eq("DD200C20D25AE5F7._matterc._udp.local")
    end

    it "generates correct operational instance name" do
      # Create compressed fabric ID as bytes
      compressed_fabric_id = Bytes.new(8)
      IO::ByteFormat::BigEndian.encode(0x1234567890ABCDEF_u64, compressed_fabric_id)

      instance = Matter::MDNS::ServiceNames.operational_instance(
        compressed_fabric_id,
        0xFEDCBA0987654321_u64
      )
      instance.should eq("1234567890ABCDEF-FEDCBA0987654321._matter._tcp.local")
    end

    it "generates correct hostname from MAC address" do
      hostname = Matter::MDNS::ServiceNames.hostname("AA:BB:CC:DD:EE:FF")
      hostname.should eq("AABBCCDDEEFF.local")
    end

    it "generates vendor subtype" do
      subtype = Matter::MDNS::ServiceNames.vendor_subtype(0xFFF1_u16)
      subtype.should eq("_V65521._sub._matterc._udp.local")
    end

    it "generates device type subtype" do
      subtype = Matter::MDNS::ServiceNames.device_type_subtype(0x0016_u32)
      subtype.should eq("_T22._sub._matterc._udp.local")
    end

    it "generates short discriminator subtype" do
      # Discriminator 3840 (0x0F00) -> short is (0x0F00 >> 8) & 0x0F = 0x0F
      subtype = Matter::MDNS::ServiceNames.short_discriminator_subtype(3840_u16)
      subtype.should eq("_S15._sub._matterc._udp.local")
    end

    it "generates long discriminator subtype" do
      # Discriminator 3840 (0x0F00) -> long is 0x0F00 & 0x0FFF = 0x0F00 = 3840
      subtype = Matter::MDNS::ServiceNames.long_discriminator_subtype(3840_u16)
      subtype.should eq("_L3840._sub._matterc._udp.local")
    end
  end

  describe "IPv6 support" do
    it "handles IPv6 addresses" do
      require_udp_sockets!
      ipv6 = Socket::IPAddress.new("fe80::1", 0)
      responder = Matter::MDNS::Responder.new(
        hostname: "test-device.local",
        ip_addresses: [ipv6]
      )

      info = Matter::MDNS::CommissioningInfo.new(
        device_name: "TestDevice",
        vendor_id: 0xFFF1_u16,
        product_id: 0x8000_u16,
        discriminator: 3840_u16,
        device_type: 0x0016_u32
      )

      # Should not raise
      responder.advertise_commissioning(info, port: 5540)
    end

    it "handles mixed IPv4/IPv6 addresses" do
      require_udp_sockets!
      ipv4 = Socket::IPAddress.new("192.168.1.100", 0)
      ipv6 = Socket::IPAddress.new("fe80::1", 0)

      responder = Matter::MDNS::Responder.new(
        hostname: "test-device.local",
        ip_addresses: [ipv4, ipv6]
      )

      info = Matter::MDNS::CommissioningInfo.new(
        device_name: "TestDevice",
        vendor_id: 0xFFF1_u16,
        product_id: 0x8000_u16,
        discriminator: 3840_u16,
        device_type: 0x0016_u32
      )

      # Should not raise
      responder.advertise_commissioning(info, port: 5540)
    end
  end

  describe "goodbye announcement" do
    it "sends goodbye for commissioning service" do
      require_udp_sockets!
      ip = Socket::IPAddress.new("192.168.1.100", 0)
      responder = Matter::MDNS::Responder.new(
        hostname: "test-device.local",
        ip_addresses: [ip]
      )

      # Should not raise
      responder.send_goodbye(
        Matter::MDNS::ServiceType::Commissioning,
        "TestDevice._matterc._udp.local"
      )
    end

    it "sends goodbye for operational service" do
      require_udp_sockets!
      ip = Socket::IPAddress.new("192.168.1.100", 0)
      responder = Matter::MDNS::Responder.new(
        hostname: "test-device.local",
        ip_addresses: [ip]
      )

      # Should not raise
      responder.send_goodbye(
        Matter::MDNS::ServiceType::Operational,
        "1-1._matter._tcp.local"
      )
    end
  end

  describe "announcement burst" do
    it "repeats the commissioning announcement ANNOUNCEMENT_BURST_COUNT times" do
      require_udp_sockets!
      responder = recording_responder(burst_interval: 10.milliseconds)
      responder.advertise_commissioning(commissioning_info(2048_u16), port: 5540)

      # First announcement is sent synchronously
      responder.sent.size.should eq(1)

      wait_for(200.milliseconds) { responder.sent.size == Matter::MDNS::Responder::ANNOUNCEMENT_BURST_COUNT }
      responder.sent.size.should eq(Matter::MDNS::Responder::ANNOUNCEMENT_BURST_COUNT)
      responder.sent.map { |packet| ptr_records(packet).map(&.name) }.uniq!.size.should eq(1)
    end

    it "repeats the operational announcement ANNOUNCEMENT_BURST_COUNT times" do
      require_udp_sockets!
      responder = recording_responder(burst_interval: 10.milliseconds)
      info = Matter::MDNS::OperationalInfo.new(compressed_fabric_id: Bytes.new(8, 0x11_u8), node_id: 1_u64)
      responder.advertise_operational(info, port: 5540)

      responder.sent.size.should eq(1)
      wait_for(200.milliseconds) { responder.sent.size == Matter::MDNS::Responder::ANNOUNCEMENT_BURST_COUNT }
      responder.sent.size.should eq(Matter::MDNS::Responder::ANNOUNCEMENT_BURST_COUNT)
    end

    it "cancels the burst on stop_commissioning" do
      require_udp_sockets!
      responder = recording_responder(burst_interval: 10.milliseconds)
      responder.advertise_commissioning(commissioning_info(2048_u16), port: 5540)
      responder.stop_commissioning

      # announcement + goodbye only; no further burst announcements
      sleep 50.milliseconds
      responder.sent.size.should eq(2)
      responder.sent.last.answers.map(&.ttl).should eq([0.seconds])
    end
  end

  describe "lifecycle" do
    it "starts and stops responder" do
      require_udp_sockets!
      responder = Matter::MDNS::Responder.new

      responder.start
      sleep 50.milliseconds
      responder.stop
    end

    it "can be closed" do
      require_udp_sockets!
      responder = Matter::MDNS::Responder.new
      responder.start
      responder.close

      # Sockets should be closed (if present); allow a brief delay for the receive loops to unwind.
      deadline = Time.monotonic + 200.milliseconds
      loop do
        closed4 = responder.socket_ipv4.try(&.closed?) || responder.socket_ipv4.nil?
        closed6 = responder.socket_ipv6.try(&.closed?) || responder.socket_ipv6.nil?
        break if (closed4 && closed6) || Time.monotonic >= deadline
        sleep 10.milliseconds
      end

      if sock4 = responder.socket_ipv4
        sock4.closed?.should be_true
      end
      if sock6 = responder.socket_ipv6
        sock6.closed?.should be_true
      end
    end
  end
end
