require "dns"
require "log"
require "../mdns/service_type"
require "../mdns/record_builder"

{% unless flag?(:win32) %}
  lib LibC
    struct MatterIfNameIndex
      if_index : UInt32
      if_name : UInt8*
    end

    fun if_nameindex : MatterIfNameIndex*
    fun if_freenameindex(pointer : MatterIfNameIndex*) : Void
  end
{% end %}

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
        if match = @instance_name.match(/^([0-9a-f]{16})-([0-9a-f]{16})\._matter\._tcp\.local$/i)
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
      Log                    = ::Log.for("matter.controller.scanner")
      MDNS_PORT              = 5353
      MDNS_IPV4              = Socket::IPAddress.new("224.0.0.251", MDNS_PORT)
      MDNS_IPV6              = Socket::IPAddress.new("ff02::fb", MDNS_PORT)
      CACHE_FLUSH            = 0x8000_u16
      CLASS_MASK             = 0x7FFF_u16
      IPV6_LINK_LOCAL_MASK   = 0xFFC0_u16
      IPV6_LINK_LOCAL_PREFIX = 0xFE80_u16
      IPV6_MDNS_PREFIX       = 0xFF02_u16
      IPV6_MDNS_GROUP        = 0x00FB_u16

      private alias HostAddress = NamedTuple(address: Socket::IPAddress, expires_at: Time)

      @devices : Hash(String, DiscoveredDevice)          # Key: lowercase instance name
      @host_addresses : Hash(String, Array(HostAddress)) # Key: SRV target hostname
      @socket : UDPSocket
      @socket6 : UDPSocket?
      @ipv6_interface_ids : Array(UInt32)
      @running : Bool
      @receive_fiber : Fiber?
      @receive_fiber6 : Fiber?

      # Callback for discovered devices
      # Signature: (device : DiscoveredDevice) -> Nil
      property on_device_discovered : Proc(DiscoveredDevice, Nil)?

      # Callback for device updates
      # Signature: (device : DiscoveredDevice) -> Nil
      property on_device_updated : Proc(DiscoveredDevice, Nil)?

      # Callback for device removal (goodbye or expired)
      # Signature: (instance_name : String) -> Nil
      property on_device_removed : Proc(String, Nil)?

      def initialize(listen_port : Int32 = MDNS_PORT)
        @socket = UDPSocket.new
        @socket.reuse_address = true
        @socket.reuse_port = true
        @socket.bind("0.0.0.0", listen_port)
        @socket.read_timeout = 100.milliseconds

        # Join multicast groups
        begin
          @socket.join_group(MDNS_IPV4)
        rescue ex
          Log.warn(exception: ex) { "Could not join IPv4 multicast group" }
        end

        @socket6 = nil
        @ipv6_interface_ids = [] of UInt32
        begin
          socket6 = UDPSocket.new(:inet6)
          socket6.ipv6_only = true
          socket6.reuse_address = true
          socket6.reuse_port = true
          socket6.bind("::", listen_port)
          socket6.read_timeout = 100.milliseconds
          @ipv6_interface_ids = join_ipv6_interfaces(socket6)
          @socket6 = socket6
        rescue ex
          socket6.try(&.close)
          Log.warn(exception: ex) { "Could not create IPv6 mDNS scanner socket" }
        end

        @devices = Hash(String, DiscoveredDevice).new
        @host_addresses = Hash(String, Array(HostAddress)).new
        @running = false
        @receive_fiber = nil
        @receive_fiber6 = nil
      end

      # Start listening for mDNS announcements
      def start : Nil
        return if @running

        @running = true
        @receive_fiber = spawn do
          receive_loop(@socket)
        end
        if socket6 = @socket6
          @receive_fiber6 = spawn do
            receive_loop(socket6)
          end
        end

        # Start cleanup fiber
        spawn do
          cleanup_loop
        end
      end

      # Stop listening
      def stop : Nil
        @running = false
        sleep 200.milliseconds if @receive_fiber || @receive_fiber6
        @receive_fiber = nil
        @receive_fiber6 = nil
      end

      # Close scanner
      def close : Nil
        stop
        @socket.close unless @socket.closed?
        @socket6.try do |socket|
          socket.close unless socket.closed?
        end
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
        @devices[instance_name.downcase]?
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
        if socket6 = @socket6
          @ipv6_interface_ids.each do |interface_id|
            socket6.multicast_interface(interface_id)
            destination = Socket::IPAddress.v6(IPV6_MDNS_PREFIX, 0, 0, 0, 0, 0, 0, IPV6_MDNS_GROUP,
              port: MDNS_PORT, zone_id: interface_id.to_i)
            socket6.send(data, destination)
          rescue ex
            Log.debug(exception: ex) { "Error sending IPv6 mDNS query (service=#{service} interface=#{interface_id})" }
          end
        end
      end

      private def join_ipv6_interfaces(socket : UDPSocket) : Array(UInt32)
        ids = [] of UInt32
        {% unless flag?(:win32) %}
          pointer = LibC.if_nameindex
          unless pointer.null?
            begin
              entry = pointer
              until entry.value.if_index == 0 || entry.value.if_name.null?
                index = entry.value.if_index
                begin
                  request = LibC::Ipv6Mreq.new
                  request.ipv6mr_multiaddr = MDNS_IPV6.to_unsafe.as(LibC::SockaddrIn6*).value.sin6_addr
                  request.ipv6mr_interface = index
                  result = LibC.setsockopt(socket.fd, LibC::IPPROTO_IPV6, LibC::IPV6_JOIN_GROUP,
                    pointerof(request).as(Void*), sizeof(LibC::Ipv6Mreq).to_u32)
                  ids << index if result == 0
                rescue ex
                  Log.debug(exception: ex) { "Could not join IPv6 mDNS group on interface #{index}" }
                end
                entry += 1
              end
            ensure
              LibC.if_freenameindex(pointer)
            end
          end
        {% end %}
        if ids.empty?
          begin
            socket.join_group(MDNS_IPV6)
            ids << 0_u32
          rescue ex
            Log.warn(exception: ex) { "Could not join IPv6 multicast group" }
          end
        end
        ids
      end

      private def receive_loop(socket : UDPSocket) : Nil
        buffer = Bytes.new(9000) # Max DNS packet size
        last_peer : Socket::IPAddress? = nil
        last_data : Bytes? = nil

        while @running
          begin
            bytes_read, peer_address = socket.receive(buffer)
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
        # Known answers in a query are not a fresh advertisement.
        return unless packet.response? && packet.success?

        # Collect all records (answers + authorities + additionals)
        all_records = packet.answers + packet.authorities + packet.additionals

        # Address records belong to the SRV target host, not the service instance.
        # Cache them independently so a host reply arriving before or after its
        # SRV record can still resolve that instance.
        address_records = Hash(String, Array(DNS::Packet::ResourceRecord)).new
        records_by_instance = Hash(String, Array(DNS::Packet::ResourceRecord)).new

        all_records.each do |record|
          next unless (record.class_code & CLASS_MASK) == MDNS::RecordBuilder::CLASS_IN
          # Skip non-.local records
          next unless record.name.downcase.ends_with?(".local")

          if record.type == MDNS::RecordBuilder::TYPE_A || record.type == MDNS::RecordBuilder::TYPE_AAAA
            (address_records[record.name.downcase] ||= [] of DNS::Packet::ResourceRecord) << record
            next
          end

          # Extract instance name from record
          instance = extract_instance_name(record.name)
          next unless instance

          key = instance.downcase
          records_by_instance[key] ||= [] of DNS::Packet::ResourceRecord
          records_by_instance[key] << record
        end

        address_records.each do |hostname, records|
          update_host_addresses(hostname, records, peer)
        end

        # Process each instance's records
        records_by_instance.each_value do |records|
          process_instance_records(records)
        end

        refresh_device_addresses(address_records.keys)
      end

      private def refresh_device_addresses(hostnames : Array(String)) : Nil
        # Address-only answers also refresh services already pointing at that host.
        @devices.keys.each do |instance|
          device = @devices[instance]
          next unless hostnames.includes?(device.hostname.downcase)
          addresses = addresses_for_host(device.hostname)
          next if same_addresses?(device.addresses, addresses)

          device.addresses = addresses
          @devices[instance] = device
          @on_device_updated.try(&.call(device))
        end
      end

      private def same_addresses?(current : Array(Socket::IPAddress), updated : Array(Socket::IPAddress)) : Bool
        return false unless current.size == updated.size
        current.zip(updated).all? do |left, right|
          left.family == right.family && left.address == right.address && left.port == right.port &&
            left.zone_id == right.zone_id
        end
      end

      private def update_host_addresses(hostname : String, records : Array(DNS::Packet::ResourceRecord), peer : Socket::IPAddress) : Nil
        now = Time.utc
        addresses = (@host_addresses[hostname]? || [] of HostAddress).reject { |entry| entry[:expires_at] <= now }
        candidates = records.compact_map do |record|
          address = case record.type
                    when MDNS::RecordBuilder::TYPE_A    then parse_a_record(record)
                    when MDNS::RecordBuilder::TYPE_AAAA then parse_aaaa_record(record, peer)
                    end
          address ? {record: record, address: address} : nil
        end
        # Cache flush applies to a DNS record set (owner, type, class), so an
        # A refresh must leave this host's AAAA records intact, and vice versa.
        flush_addresses = candidates.select do |candidate|
          candidate[:record].ttl.total_seconds > 0 && (candidate[:record].class_code & CACHE_FLUSH) != 0
        end.map(&.[:address])
        addresses.reject! do |entry|
          flush_addresses.any? do |address|
            next false unless entry[:address].family == address.family
            # Link-local RRSets are interface-local. A reply received on one
            # interface must not erase a route learned on another interface.
            !address.family.inet6? || entry[:address].zone_id == address.zone_id
          end
        end

        candidates.each do |candidate|
          record = candidate[:record]
          address = candidate[:address]

          addresses.reject! do |entry|
            entry[:address].family == address.family && entry[:address].address == address.address &&
              entry[:address].zone_id == address.zone_id
          end
          addresses << {address: address, expires_at: now + record.ttl} if record.ttl.total_seconds > 0
        end

        if addresses.empty?
          @host_addresses.delete(hostname)
        else
          @host_addresses[hostname] = addresses
        end
      end

      private def addresses_for_host(hostname : String) : Array(Socket::IPAddress)
        now = Time.utc
        addresses = @host_addresses[hostname.downcase]?
        return [] of Socket::IPAddress unless addresses

        addresses.select { |entry| entry[:expires_at] > now }.map(&.[:address])
      end

      private def extract_instance_name(name : String) : String?
        normalized = name.downcase
        return name if normalized.ends_with?(".#{MDNS::ServiceNames::COMMISSIONING}")
        name if normalized.ends_with?(".#{MDNS::ServiceNames::OPERATIONAL}")
      end

      private def process_instance_records(records : Array(DNS::Packet::ResourceRecord)) : Nil
        # Extract information from records
        srv_record = records.find { |record| record.type == MDNS::RecordBuilder::TYPE_SRV }
        txt_record = records.find { |record| record.type == MDNS::RecordBuilder::TYPE_TXT }

        # Need at least SRV record to identify the service
        return unless srv_record

        instance = srv_record.name
        key = instance.downcase

        # Parse SRV record for port and hostname
        port, hostname = parse_srv_record(srv_record)
        return unless port && hostname

        # Parse TXT record
        txt_records = txt_record ? parse_txt_record(txt_record) : Hash(String, String).new

        addresses = addresses_for_host(hostname)

        # Determine service type
        service_type = if instance.downcase.ends_with?(MDNS::ServiceNames::COMMISSIONING)
                         MDNS::ServiceType::Commissioning
                       elsif instance.downcase.ends_with?(MDNS::ServiceNames::OPERATIONAL)
                         MDNS::ServiceType::Operational
                       else
                         return
                       end

        # Calculate expiration
        ttl = srv_record.ttl
        expires_at = Time.utc + ttl

        # Handle TTL=0 (goodbye packet)
        if ttl.total_seconds == 0
          if existing = @devices.delete(key)
            @on_device_removed.try(&.call(existing.instance_name))
          end
          return
        end

        # Update or create device
        if existing = @devices[key]?
          # Update existing device
          existing.hostname = hostname
          existing.addresses = addresses
          existing.port = port
          existing.txt_records = txt_records
          existing.expires_at = expires_at
          @devices[key] = existing
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

          @devices[key] = device
          @on_device_discovered.try(&.call(device))
        end
      end

      private def parse_srv_record(record : DNS::Packet::ResourceRecord) : Tuple(Int32?, String?)
        # Received DNS packets may compress the SRV target against a name
        # elsewhere in the packet. The DNS parser resolves that pointer while
        # it still has the complete message. Records constructed in memory
        # have no parsed resource, so decode their uncompressed data below.
        if parsed = record.resource.as?(DNS::Resource::SRV)
          return {parsed.port.to_i32, parsed.target}
        end

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

      private def parse_aaaa_record(record : DNS::Packet::ResourceRecord, peer : Socket::IPAddress) : Socket::IPAddress?
        return unless record.resource_data.size == 16

        # IPv6 address is 16 bytes
        # Convert to hex string representation
        parts = [] of String
        (0...16).step(2) do |i|
          part = (record.resource_data[i].to_u16 << 8) | record.resource_data[i + 1].to_u16
          parts << part.to_s(16)
        end

        # A link-local address is meaningful only on the interface that sent
        # the IPv6 mDNS response. IPv4 mDNS and an unscoped IPv6 peer cannot
        # establish that interface, so never publish an unroutable candidate.
        first = (record.resource_data[0].to_u16 << 8) | record.resource_data[1].to_u16
        link_local = (first & IPV6_LINK_LOCAL_MASK) == IPV6_LINK_LOCAL_PREFIX
        return if link_local && (!peer.family.inet6? || peer.zone_id == 0)
        fields = parts.map(&.to_u16(16))
        Socket::IPAddress.v6(fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], port: 0,
          zone_id: link_local ? peer.zone_id : 0)
      rescue
        nil
      end

      private def cleanup_loop : Nil
        while @running
          sleep 10.seconds

          expired_hosts = [] of String
          @host_addresses.reject! do |hostname, addresses|
            previous_size = addresses.size
            addresses.reject! { |entry| entry[:expires_at] <= Time.utc }
            expired_hosts << hostname if addresses.size != previous_size
            if addresses.empty?
              true
            else
              false
            end
          end

          # Remove expired devices
          @devices.reject! do |_instance, device|
            if device.expired?
              @on_device_removed.try(&.call(device.instance_name))
              true
            else
              false
            end
          end

          refresh_device_addresses(expired_hosts)
        end
      end
    end
  end
end
