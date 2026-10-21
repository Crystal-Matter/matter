require "dns"
require "log"
require "../mdns/service_type"
require "../mdns/record_builder"

module Matter
  module Controller
    # Discovered Matter device information
    struct DiscoveredDevice
      property instance_name : String
      property hostname : String
      property addresses : Array(Socket::IPAddress)
      property port : Int32
      property txt_records : Hash(String, String)
      property service_type : MDNS::ServiceType
      property expires_at : Time

      # Commissioning-specific fields
      property vendor_id : UInt16?
      property product_id : UInt16?
      property discriminator : UInt16?
      property device_type : UInt32?
      property device_name : String?
      property commissioning_mode : UInt8?
      property joint_fabric_role : MDNS::JointFabricRole?

      # Operational-specific fields
      property fabric_id : UInt64?
      property node_id : UInt64?

      def initialize(
        @instance_name : String,
        @hostname : String,
        @addresses : Array(Socket::IPAddress),
        @port : Int32,
        @txt_records : Hash(String, String),
        @service_type : MDNS::ServiceType,
        @expires_at : Time,
      )
        parse_txt_records
      end

      # Parse TXT records into structured fields
      private def parse_txt_records : Nil
        case @service_type
        when .commissioning?
          parse_commissioning_txt
        when .operational?
          parse_operational_txt
        end
      end

      private def parse_commissioning_txt : Nil
        # VP=<vendor-id>+<product-id>
        if vp = @txt_records["VP"]?
          parts = vp.split('+')
          @vendor_id = parts[0]?.try(&.to_u16?)
          @product_id = parts[1]?.try(&.to_u16?)
        end

        @discriminator = @txt_records["D"]?.try(&.to_u16?)
        @device_type = @txt_records["DT"]?.try(&.to_u32?)
        @device_name = @txt_records["DN"]?
        @commissioning_mode = @txt_records["CM"]?.try(&.to_u8?)
        @joint_fabric_role = @txt_records["JF"]?.try(&.to_u8?).try do |value|
          MDNS::JointFabricRole.from_value?(value)
        end
      end

      private def parse_operational_txt : Nil
        # Try to parse fabric_id and node_id from instance name
        # Format: <fabric-id>-<node-id>._matter._tcp.local
        if match = @instance_name.match(/^([0-9A-F]+)-([0-9A-F]+)\./)
          @fabric_id = match[1].to_u64?(16)
          @node_id = match[2].to_u64?(16)
        end
      end

      # Check if device has expired
      def expired? : Bool
        Time.utc >= @expires_at
      end
    end

    # mDNS Scanner for discovering Matter devices
    #
    # Handles:
    # - Listening to all mDNS traffic
    # - Maintaining device discovery table
    # - Processing unsolicited announcements
    # - Sending queries for specific services
    class Scanner
      Log       = ::Log.for("matter.controller.scanner")
      MDNS_PORT = 5353
      MDNS_IPV4 = Socket::IPAddress.new("224.0.0.251", MDNS_PORT)
      MDNS_IPV6 = Socket::IPAddress.new("ff02::fb", MDNS_PORT)

      @devices : Hash(String, DiscoveredDevice) # Key: instance name
      @socket : UDPSocket
      @running : Bool
      @receive_fiber : Fiber?

      # Callback for discovered devices
      # Signature: (device : DiscoveredDevice) -> Nil
      property on_device_discovered : Proc(DiscoveredDevice, Nil)?

      # Callback for device updates
      # Signature: (device : DiscoveredDevice) -> Nil
      property on_device_updated : Proc(DiscoveredDevice, Nil)?

      # Callback for device removal (goodbye or expired)
      # Signature: (instance_name : String) -> Nil
      property on_device_removed : Proc(String, Nil)?

      def initialize
        @socket = UDPSocket.new
        @socket.reuse_address = true
        @socket.reuse_port = true
        @socket.bind("0.0.0.0", MDNS_PORT)
        @socket.read_timeout = 100.milliseconds

        # Join multicast groups
        begin
          @socket.join_group(MDNS_IPV4)
        rescue ex
          Log.warn(exception: ex) { "Could not join IPv4 multicast group" }
        end

        @devices = Hash(String, DiscoveredDevice).new
        @running = false
        @receive_fiber = nil
      end

      # Start listening for mDNS announcements
      def start : Nil
        return if @running

        @running = true
        @receive_fiber = spawn do
          receive_loop
        end

        # Start cleanup fiber
        spawn do
          cleanup_loop
        end
      end

      # Stop listening
      def stop : Nil
        @running = false
        sleep 200.milliseconds if @receive_fiber
        @receive_fiber = nil
      end

      # Close scanner
      def close : Nil
        stop
        @socket.close unless @socket.closed?
      end

      # Query for commissioning devices
      def query_commissioning : Nil
        query_service(MDNS::ServiceNames::COMMISSIONING)
      end

      # Query for operational devices
      def query_operational : Nil
        query_service(MDNS::ServiceNames::OPERATIONAL)
      end

      # Get all discovered devices
      def devices : Array(DiscoveredDevice)
        @devices.values
      end

      # Get commissioning devices
      def commissioning_devices : Array(DiscoveredDevice)
        @devices.values.select(&.service_type.commissioning?)
      end

      # Get operational devices
      def operational_devices : Array(DiscoveredDevice)
        @devices.values.select(&.service_type.operational?)
      end

      # Get device by instance name
      def get_device(instance_name : String) : DiscoveredDevice?
        @devices[instance_name]?
      end

      private def query_service(service : String) : Nil
        # Build PTR query for service
        question = DNS::Packet::Question.new(
          name: service,
          type: MDNS::RecordBuilder::TYPE_PTR,
          class_code: MDNS::RecordBuilder::CLASS_IN
        )

        packet = DNS::Packet.new(
          id: Random.rand(UInt16),
          questions: [question]
        )

        data = packet.to_slice

        # Send multicast query
        begin
          @socket.send(data, MDNS_IPV4)
        rescue ex
          Log.error(exception: ex) { "Error sending mDNS query (service=#{service})" }
        end
      end

      private def receive_loop : Nil
        buffer = Bytes.new(9000) # Max DNS packet size
        last_peer : Socket::IPAddress? = nil
        last_data : Bytes? = nil

        while @running
          begin
            bytes_read, peer_address = @socket.receive(buffer)
            next if bytes_read == 0

            last_peer = peer_address
            last_data = buffer[0, bytes_read]
            packet = DNS::Packet.from_slice(last_data)
            process_mdns_packet(packet, peer_address)
          rescue IO::TimeoutError
            # Normal - continue
          rescue ex : Exception
            peer = last_peer ? last_peer.to_s : "unknown"
            Log.debug(exception: ex) { "Error receiving mDNS packet (peer=#{peer} bytes=#{last_data.try(&.size) || 0})" }
          end
        end
      end

      private def process_mdns_packet(packet : DNS::Packet, peer : Socket::IPAddress) : Nil
        # Collect all records (answers + authorities + additionals)
        all_records = packet.answers + packet.authorities + packet.additionals

        # Group records by instance name
        records_by_instance = Hash(String, Array(DNS::Packet::ResourceRecord)).new

        all_records.each do |record|
          # Skip non-.local records
          next unless record.name.ends_with?(".local")

          # Extract instance name from record
          instance = extract_instance_name(record.name)
          next unless instance

          records_by_instance[instance] ||= [] of DNS::Packet::ResourceRecord
          records_by_instance[instance] << record
        end

        # Process each instance's records
        records_by_instance.each do |instance, records|
          process_instance_records(instance, records)
        end
      end

      private def extract_instance_name(name : String) : String?
        # Check if this is a service instance name
        if name.includes?(MDNS::ServiceNames::COMMISSIONING)
          return name if name.ends_with?(MDNS::ServiceNames::COMMISSIONING)
        elsif name.includes?(MDNS::ServiceNames::OPERATIONAL)
          return name if name.ends_with?(MDNS::ServiceNames::OPERATIONAL)
        end

        nil
      end

      private def process_instance_records(instance : String, records : Array(DNS::Packet::ResourceRecord)) : Nil
        # Extract information from records
        srv_record = records.find { |record| record.type == MDNS::RecordBuilder::TYPE_SRV }
        txt_record = records.find { |record| record.type == MDNS::RecordBuilder::TYPE_TXT }
        a_records = records.select { |record| record.type == MDNS::RecordBuilder::TYPE_A }
        aaaa_records = records.select { |record| record.type == MDNS::RecordBuilder::TYPE_AAAA }

        # Need at least SRV record to identify the service
        return unless srv_record

        # Parse SRV record for port and hostname
        port, hostname = parse_srv_record(srv_record)
        return unless port && hostname

        # Parse TXT record
        txt_records = txt_record ? parse_txt_record(txt_record) : Hash(String, String).new

        # Collect IP addresses
        addresses = [] of Socket::IPAddress
        a_records.each do |record|
          if addr = parse_a_record(record)
            addresses << addr
          end
        end
        aaaa_records.each do |record|
          if addr = parse_aaaa_record(record)
            addresses << addr
          end
        end

        # Determine service type
        service_type = if instance.includes?(MDNS::ServiceNames::COMMISSIONING)
                         MDNS::ServiceType::Commissioning
                       elsif instance.includes?(MDNS::ServiceNames::OPERATIONAL)
                         MDNS::ServiceType::Operational
                       else
                         return
                       end

        # Calculate expiration
        ttl = srv_record.ttl
        expires_at = Time.utc + ttl

        # Handle TTL=0 (goodbye packet)
        if ttl.total_seconds == 0
          if @devices.has_key?(instance)
            @devices.delete(instance)
            @on_device_removed.try(&.call(instance))
          end
          return
        end

        # Update or create device
        if existing = @devices[instance]?
          # Update existing device
          existing.hostname = hostname
          existing.addresses = addresses
          existing.port = port
          existing.txt_records = txt_records
          existing.expires_at = expires_at
          @on_device_updated.try(&.call(existing))
        else
          # Create new device
          device = DiscoveredDevice.new(
            instance_name: instance,
            hostname: hostname,
            addresses: addresses,
            port: port,
            txt_records: txt_records,
            service_type: service_type,
            expires_at: expires_at
          )

          @devices[instance] = device
          @on_device_discovered.try(&.call(device))
        end
      end

      private def parse_srv_record(record : DNS::Packet::ResourceRecord) : Tuple(Int32?, String?)
        io = IO::Memory.new(record.resource_data)

        begin
          io.read_bytes(UInt16, IO::ByteFormat::BigEndian) # priority (unused)
          io.read_bytes(UInt16, IO::ByteFormat::BigEndian) # weight (unused)
          port = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)

          # Parse target domain name
          hostname = DNS::Resource.read_labels(io)

          {port.to_i32, hostname}
        rescue
          {nil, nil}
        end
      end

      private def parse_txt_record(record : DNS::Packet::ResourceRecord) : Hash(String, String)
        txt_records = Hash(String, String).new
        io = IO::Memory.new(record.resource_data)

        while io.pos < record.resource_data.size
          begin
            length = io.read_byte
            break unless length && length > 0

            txt = Bytes.new(length)
            io.read_fully(txt)

            # Parse key=value
            txt_str = String.new(txt)
            if match = txt_str.match(/^([^=]+)=(.*)$/)
              txt_records[match[1]] = match[2]
            end
          rescue
            break
          end
        end

        txt_records
      end

      private def parse_a_record(record : DNS::Packet::ResourceRecord) : Socket::IPAddress?
        return unless record.resource_data.size == 4

        # IPv4 address is 4 bytes
        ip_bytes = record.resource_data
        ip_str = "#{ip_bytes[0]}.#{ip_bytes[1]}.#{ip_bytes[2]}.#{ip_bytes[3]}"
        Socket::IPAddress.new(ip_str, 0)
      rescue
        nil
      end

      private def parse_aaaa_record(record : DNS::Packet::ResourceRecord) : Socket::IPAddress?
        return unless record.resource_data.size == 16

        # IPv6 address is 16 bytes
        # Convert to hex string representation
        parts = [] of String
        (0...16).step(2) do |i|
          part = (record.resource_data[i].to_u16 << 8) | record.resource_data[i + 1].to_u16
          parts << part.to_s(16)
        end

        ip_str = parts.join(":")
        Socket::IPAddress.new(ip_str, 0)
      rescue
        nil
      end

      private def cleanup_loop : Nil
        while @running
          sleep 10.seconds

          # Remove expired devices
          @devices.reject! do |instance, device|
            if device.expired?
              @on_device_removed.try(&.call(instance))
              true
            else
              false
            end
          end
        end
      end
    end
  end
end
