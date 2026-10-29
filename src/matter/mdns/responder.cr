require "dns"
require "./responder_interface"
require "./service_type"
require "./record_builder"
require "../network/constants"
require "../network/local_addresses"

module Matter
  module MDNS
    # mDNS Responder for advertising Matter services
    #
    # Handles:
    # - Service advertisement (announcements)
    # - Query responses
    # - Using Authority Section for authoritative records
    class Responder
      include ResponderInterface
      MDNS_PORT        = 5353
      MDNS_IPV4        = Socket::IPAddress.new("224.0.0.251", MDNS_PORT)
      MDNS_IPV6_HOST   = "ff02::fb"
      MDNS_IPV6        = Socket::IPAddress.new(MDNS_IPV6_HOST, MDNS_PORT)
      MDNS_RESPONSE_ID = 0_u16

      DEFAULT_TTL           = 120.seconds
      ANNOUNCEMENT_INTERVAL = 30.seconds # Re-announce services every 30 seconds

      # A newly (re)advertised service is announced this many times, this far apart,
      # so controllers that missed the first multicast still pick it up quickly.
      ANNOUNCEMENT_BURST_COUNT    = 3
      ANNOUNCEMENT_BURST_INTERVAL = 1.second

      # DNS QTYPE matching any record type (RFC 1035 §3.2.3)
      QTYPE_ANY = 255_u16

      # {service_type, port, txt_records, commissioning_info, hostname}
      alias AdvertisedService = {ServiceType, Int32, Hash(String, String), CommissioningInfo?, String}

      getter socket_ipv4 : UDPSocket?
      getter socket_ipv6 : UDPSocket?
      getter port : Int32
      getter hostname : String
      getter ip_addresses : Array(Socket::IPAddress)
      getter announcement_burst_interval : Time::Span

      @running : Bool
      @ipv6_interface_ids : Array(UInt32)
      @interface_addresses : Hash(UInt32, Array(Socket::IPAddress))
      @ipv6_send_mutex : Mutex

      # Currently advertised services (for responding to queries), keyed by instance name
      @advertised_services : Hash(String, AdvertisedService)
      @commissioning_instance_id : String? = nil

      # In-flight announcement bursts, keyed by instance name. Closing the channel
      # cancels the burst.
      @announcement_bursts : Hash(String, Channel(Nil))

      # Callback for received queries
      # Signature: (query : DNS::Packet, peer_address : Socket::IPAddress) -> Nil
      property on_query : Proc(DNS::Packet, Socket::IPAddress, Nil)?

      def initialize(
        @port : Int32 = MDNS_PORT,
        @hostname : String = "matter-device.local",
        @ip_addresses : Array(Socket::IPAddress) = [] of Socket::IPAddress,
        @announcement_burst_interval : Time::Span = ANNOUNCEMENT_BURST_INTERVAL,
      )
        # Create IPv4 socket
        @socket_ipv4 = begin
          sock = UDPSocket.new(:inet)
          sock.reuse_address = true
          sock.reuse_port = true
          sock.bind("0.0.0.0", MDNS_PORT)

          # Set multicast options
          sock.multicast_loopback = true # Allow receiving our own packets (needed for testing)
          sock.multicast_hops = 255      # TTL for multicast packets

          sock
        rescue ex
          Log.warn(exception: ex) { "Failed to create IPv4 socket" }
          nil
        end

        # Create IPv6 socket
        @socket_ipv6 = begin
          sock = UDPSocket.new(:inet6)
          sock.reuse_address = true
          sock.reuse_port = true
          sock.bind("::", MDNS_PORT)

          # Set multicast options
          sock.multicast_loopback = true # Allow receiving our own packets (needed for testing)
          sock.multicast_hops = 255      # TTL for multicast packets

          sock
        rescue ex
          Log.warn(exception: ex) { "Failed to create IPv6 socket" }
          nil
        end

        @running = false
        @ipv6_interface_ids = [] of UInt32
        @interface_addresses = Hash(UInt32, Array(Socket::IPAddress)).new
        @ipv6_send_mutex = Mutex.new

        # Ensure at least one socket was created successfully
        raise Matter::TransportError.new("Failed to create any mDNS socket") if @socket_ipv4.nil? && @socket_ipv6.nil?
        @advertised_services = Hash(String, AdvertisedService).new
        @announcement_bursts = Hash(String, Channel(Nil)).new
      end

      # The commissioning info currently being advertised, if any.
      def advertised_commissioning_info : CommissioningInfo?
        @advertised_services.each_value do |(service_type, _, _, commissioning_info, _)|
          return commissioning_info if service_type.commissioning?
        end
        nil
      end

      # Returns the current commissioning DNS-SD instance name (e.g. `DD200C20D25AE5F7._matterc._udp.local`)
      # if commissioning is currently being advertised.
      def commissioning_instance_name : String?
        if instance_id = @commissioning_instance_id
          ServiceNames.commissioning_instance(instance_id)
        end
      end

      # Updates the default commissioning target hostname (SRV target) and re-announces
      # any active commissioning advertisements without changing the commissioning
      # instance name.
      def update_commissioning_hostname(hostname : String) : Nil
        normalized = hostname.strip
        raise ArgumentError.new("hostname must be non-empty") if normalized.empty?

        @hostname = normalized

        # Update any existing commissioning services and re-announce them so controllers
        # see the new SRV target/AAAA records.
        @advertised_services.each do |instance, (service_type, port, txt_records, commissioning_info, _)|
          next unless service_type.commissioning?

          service = {service_type, port, txt_records, commissioning_info, normalized}
          @advertised_services[instance] = service
          send_announcement(service_records(instance, service))
        end
      end

      # Start listening for mDNS queries
      def start : Nil
        return if @running

        @running = true
        @interface_addresses = Network.local_ip_addresses_by_interface

        # Join IPv4 multicast group and start receive loop
        if sock4 = @socket_ipv4
          begin
            sock4.join_group(MDNS_IPV4)
            Log.debug { "Joined IPv4 mDNS multicast group 224.0.0.251" }

            spawn do
              receive_loop_ipv4(sock4)
            end
          rescue ex
            Log.warn(exception: ex) { "Could not join IPv4 multicast group" }
          end
        end

        # Join IPv6 multicast group and start receive loop
        if sock6 = @socket_ipv6
          @ipv6_interface_ids = join_ipv6_interfaces(sock6)
          unless @ipv6_interface_ids.empty?
            spawn do
              receive_loop_ipv6(sock6)
            end
          end
        end

        # Start periodic announcement loop
        spawn do
          periodic_announcement_loop
        end
      end

      # Stop listening
      def stop : Nil
        @running = false
        cancel_announcement_bursts

        # Leave IPv4 multicast group
        if sock4 = @socket_ipv4
          begin
            sock4.leave_group(MDNS_IPV4)
          rescue ex
            Log.warn(exception: ex) { "Error leaving IPv4 multicast group" }
          ensure
            begin
              sock4.close unless sock4.closed?
            rescue ex
              Log.warn(exception: ex) { "Error closing IPv4 socket" }
            end
          end
        end

        # Leave IPv6 multicast group
        if sock6 = @socket_ipv6
          begin
            # Closing the socket drops every per-interface membership.
            sock6.leave_group(MDNS_IPV6) if @ipv6_interface_ids == [0_u32]
          rescue ex
            Log.warn(exception: ex) { "Error leaving IPv6 multicast group" }
          ensure
            begin
              sock6.close unless sock6.closed?
            rescue ex
              Log.warn(exception: ex) { "Error closing IPv6 socket" }
            end
          end
        end
        @ipv6_interface_ids.clear
      end

      private def join_ipv6_interfaces(socket : UDPSocket) : Array(UInt32)
        ids = [] of UInt32
        @interface_addresses.each do |index, addresses|
          next unless addresses.any?(&.family.inet6?)
          begin
            request = LibC::Ipv6Mreq.new
            request.ipv6mr_multiaddr = MDNS_IPV6.to_unsafe.as(LibC::SockaddrIn6*).value.sin6_addr
            request.ipv6mr_interface = index
            result = join_ipv6_group(socket, request)
            if result == 0
              ids << index
            else
              {% if flag?(:win32) %}
                Log.debug { "Could not join IPv6 mDNS group on interface #{index}: Winsock error #{LibC.WSAGetLastError}" }
              {% else %}
                Log.debug { "Could not join IPv6 mDNS group on interface #{index}: #{Errno.value}" }
              {% end %}
            end
          rescue ex
            Log.debug(exception: ex) { "Could not join IPv6 mDNS group on interface #{index}" }
          end
        end
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

      private def join_ipv6_group(socket : UDPSocket, request : LibC::Ipv6Mreq) : Int32
        {% if flag?(:win32) %}
          LibC.setsockopt(socket.fd, LibC::IPPROTO_IPV6, LibC::IPV6_JOIN_GROUP,
            pointerof(request).as(LibC::Char*), sizeof(LibC::Ipv6Mreq).to_i32)
        {% else %}
          LibC.setsockopt(socket.fd, LibC::IPPROTO_IPV6, LibC::IPV6_JOIN_GROUP,
            pointerof(request).as(Void*), sizeof(LibC::Ipv6Mreq).to_u32)
        {% end %}
      end

      # Close responder
      def close : Nil
        stop
      end

      # Periodic announcement loop - re-announces all services every ANNOUNCEMENT_INTERVAL
      private def periodic_announcement_loop : Nil
        while @running
          sleep ANNOUNCEMENT_INTERVAL
          reannounce_all_services if @running
        end
      rescue ex
        Log.error(exception: ex) { "Error in periodic announcement loop (running=#{@running} advertised_services=#{@advertised_services.size})" }
      end

      # Re-announce all currently advertised services
      private def reannounce_all_services : Nil
        return if @advertised_services.empty?

        Log.debug { "Re-announcing #{@advertised_services.size} service(s)" }

        @advertised_services.each do |instance, service|
          send_announcement(service_records(instance, service))
        rescue ex
          Log.warn(exception: ex) { "Failed to re-announce service #{instance}" }
        end
      end

      # Announce a service now and repeat the announcement ANNOUNCEMENT_BURST_COUNT
      # times in total, ANNOUNCEMENT_BURST_INTERVAL apart. Any burst already running
      # for the instance is cancelled first.
      private def announce_burst(instance : String, records : Array(DNS::Packet::ResourceRecord)) : Nil
        cancel_announcement_burst(instance)
        send_announcement(records)

        cancel = Channel(Nil).new
        @announcement_bursts[instance] = cancel

        spawn do
          (ANNOUNCEMENT_BURST_COUNT - 1).times do
            select
            when cancel.receive?
              break
            when timeout(@announcement_burst_interval)
              send_announcement(records)
            end
          end
        ensure
          @announcement_bursts.delete(instance) if @announcement_bursts[instance]?.same?(cancel)
        end
      end

      private def cancel_announcement_burst(instance : String) : Nil
        @announcement_bursts.delete(instance).try(&.close)
      end

      private def cancel_announcement_bursts : Nil
        @announcement_bursts.each_value(&.close)
        @announcement_bursts.clear
      end

      # Advertise commissioning service
      def advertise_commissioning(
        info : CommissioningInfo,
        port : Int32 = 5540,
        ttl : Time::Span = 120.seconds,
      ) : Nil
        commissioning_instance_id = @commissioning_instance_id ||= Hex.node_id(Random::Secure.rand(UInt64))
        instance = ServiceNames.commissioning_instance(commissioning_instance_id)

        # Track this service for query responses
        service = {ServiceType::Commissioning, port, info.to_txt_records, info, @hostname}
        @advertised_services[instance] = service

        announce_burst(instance, service_records(instance, service, ttl))
      end

      # Advertise operational service
      def advertise_operational(
        info : OperationalInfo,
        port : Int32 = 5540,
        ttl : Time::Span = 120.seconds,
      ) : Nil
        instance = ServiceNames.operational_instance(info.compressed_fabric_id, info.node_id)

        # Track this service for query responses
        service = {ServiceType::Operational, port, info.to_txt_records, nil, operational_hostname(info)}
        @advertised_services[instance] = service

        announce_burst(instance, service_records(instance, service, ttl))
      end

      # Stop all commissioning advertisements
      def stop_commissioning : Nil
        # Find and remove all commissioning services
        commissioning_instances = @advertised_services.select { |_, v| v[0] == ServiceType::Commissioning }.keys
        commissioning_instances.each do |instance|
          Log.info { "Stopping commissioning advertisement for: #{instance}" }
          send_goodbye(ServiceType::Commissioning, instance)
        end
        @commissioning_instance_id = nil
      end

      # Stop all operational advertisements
      def stop_operational_advertisement : Nil
        # Find and remove all operational services
        operational_instances = @advertised_services.select { |_, v| v[0] == ServiceType::Operational }.keys
        operational_instances.each do |instance|
          Log.info { "Stopping operational advertisement for: #{instance}" }
          send_goodbye(ServiceType::Operational, instance)
        end
      end

      # Send goodbye announcement (TTL=0) to remove service
      def send_goodbye(service_type : ServiceType, instance : String) : Nil
        service = ServiceNames.service_name(service_type)

        # Remove from advertised services
        cancel_announcement_burst(instance)
        @advertised_services.delete(instance)

        # Build PTR record with TTL=0
        ptr = RecordBuilder.build_ptr(service, instance, 0.seconds)

        packet = DNS::Packet.new(
          id: 0_u16,
          response: true,
          authoritative_answer: true,
          answers: [ptr]
        )

        send_multicast(packet)
      end

      # Respond to a specific query
      def respond_to_query(query : DNS::Packet, service_type : ServiceType, instance : String, port : Int32, txt_records : Hash(String, String)) : Nil
        respond_to_query(query, service_type, instance, port, txt_records, @hostname)
      end

      # Respond to a specific query with explicit hostname (SRV target).
      def respond_to_query(query : DNS::Packet, service_type : ServiceType, instance : String, port : Int32, txt_records : Hash(String, String), hostname : String) : Nil
        service = ServiceNames.service_name(service_type)

        # Check if query is asking for our service
        matches = query.questions.any? do |question|
          question.name == service || question.name == instance || question.name == hostname
        end

        return unless matches

        records = build_service_records(
          service: service,
          instance: instance,
          port: port,
          txt_records: txt_records,
          ttl: DEFAULT_TTL,
          hostname: hostname
        )

        send_announcement(records)
      end

      # Every name a controller may browse (PTR query) to find a commissioning
      # service: the service itself plus the Matter discovery subtypes
      # (_V<vendor>, _T<device type>, _S<short>, _L<long discriminator>, _CM).
      private def commissioning_browse_names(service : String, info : CommissioningInfo) : Array(String)
        [
          service,
          ServiceNames.vendor_subtype(info.vendor_id),
          ServiceNames.device_type_subtype(info.device_type),
          ServiceNames.short_discriminator_subtype(info.discriminator),
          ServiceNames.long_discriminator_subtype(info.discriminator),
          ServiceNames.commissioning_mode_subtype,
        ]
      end

      # Names a PTR query may use to browse for an advertised service.
      private def browse_names(service : AdvertisedService) : Array(String)
        service_type, _, _, commissioning_info, _ = service
        service_name = ServiceNames.service_name(service_type)
        return [service_name] unless commissioning_info
        commissioning_browse_names(service_name, commissioning_info)
      end

      # DNS names compare case-insensitively (RFC 6762 §16).
      private def dns_name_matches?(name : String, other : String) : Bool
        name.compare(other, case_insensitive: true).zero?
      end

      # All records (PTR/SRV/TXT/A/AAAA) describing an advertised service.
      private def service_records(instance : String, service : AdvertisedService, ttl : Time::Span = DEFAULT_TTL) : Array(DNS::Packet::ResourceRecord)
        service_type, port, txt_records, commissioning_info, hostname = service
        service_name = ServiceNames.service_name(service_type)

        if commissioning_info
          build_commissioning_records(
            info: commissioning_info,
            service: service_name,
            instance: instance,
            port: port,
            txt_records: txt_records,
            ttl: ttl,
            hostname: hostname
          )
        else
          build_service_records(
            service: service_name,
            instance: instance,
            port: port,
            txt_records: txt_records,
            ttl: ttl,
            hostname: hostname
          )
        end
      end

      private def build_commissioning_records(
        info : CommissioningInfo,
        service : String,
        instance : String,
        port : Int32,
        txt_records : Hash(String, String),
        ttl : Time::Span,
        hostname : String,
      ) : Array(DNS::Packet::ResourceRecord)
        records = [] of DNS::Packet::ResourceRecord
        browse_names = commissioning_browse_names(service, info)

        # PTR records from _services._dns-sd._udp.local to the service and all subtypes (for browse lists)
        browse_names.each do |name|
          records << RecordBuilder.build_ptr(ServiceNames::SERVICE_DISCOVERY, name, ttl)
        end

        # PTR records from service and subtypes -> instance (for service and subtype browsing)
        browse_names.each do |name|
          records << RecordBuilder.build_ptr(name, instance, ttl)
        end

        # SRV record: instance -> hostname:port
        records << RecordBuilder.build_srv(instance, port, hostname, ttl)

        # TXT record: instance metadata
        records << RecordBuilder.build_txt(instance, txt_records, ttl)

        # A/AAAA records: hostname -> IP addresses
        @ip_addresses.each do |ip|
          case ip.family
          when .inet?
            records << RecordBuilder.build_a(hostname, ip, ttl)
          when .inet6?
            records << RecordBuilder.build_aaaa(hostname, ip, ttl)
          end
        end

        records
      end

      private def build_service_records(
        service : String,
        instance : String,
        port : Int32,
        txt_records : Hash(String, String),
        ttl : Time::Span,
        hostname : String,
      ) : Array(DNS::Packet::ResourceRecord)
        records = [] of DNS::Packet::ResourceRecord

        # PTR record: service -> instance
        records << RecordBuilder.build_ptr(service, instance, ttl)

        # SRV record: instance -> hostname:port (goes in authorities)
        records << RecordBuilder.build_srv(instance, port, hostname, ttl)

        # TXT record: instance metadata (goes in authorities)
        records << RecordBuilder.build_txt(instance, txt_records, ttl)

        # A/AAAA records: hostname -> IP addresses (go in additionals)
        @ip_addresses.each do |ip|
          case ip.family
          when .inet?
            records << RecordBuilder.build_a(hostname, ip, ttl)
          when .inet6?
            records << RecordBuilder.build_aaaa(hostname, ip, ttl)
          end
        end

        records
      end

      private def send_announcement(records : Array(DNS::Packet::ResourceRecord)) : Nil
        # Split records into appropriate sections
        ptr_records = records.select { |record| record.type == RecordBuilder::TYPE_PTR }
        additional_records = records.select { |record| record.type != RecordBuilder::TYPE_PTR }

        # Build mDNS announcement packet per RFC 6763
        # PTR records in Answer Section
        # SRV, TXT, A, AAAA records in Additional Records Section
        # Authority Section should be empty for mDNS
        packet = DNS::Packet.new(
          id: 0_u16,
          response: true,
          authoritative_answer: true, # Critical: We are authoritative
          answers: ptr_records,
          authorities: [] of DNS::Packet::ResourceRecord, # Empty per RFC 6763
          additionals: additional_records                 # SRV, TXT, A, AAAA all go here
        )

        send_multicast(packet)
      end

      private def send_multicast(packet : DNS::Packet) : Nil
        data = packet.to_slice
        Log.debug { "Sending mDNS packet: #{data.size} bytes, #{packet.answers.size} answers, #{packet.authorities.size} authorities, #{packet.additionals.size} additionals" }

        # Send to IPv4 multicast
        if sock4 = @socket_ipv4
          begin
            source = ipv4_multicast_source
            outgoing = source ? packet_for_ipv4_source(packet, source) : packet_with_addresses(packet, [] of Socket::IPAddress)
            unless outgoing.answers.empty? && outgoing.authorities.empty? && outgoing.additionals.empty?
              bytes_sent = sock4.send(outgoing.to_slice, MDNS_IPV4)
              Log.trace { "Sent #{bytes_sent} bytes to IPv4 multicast 224.0.0.251:5353" }
            end
          rescue ex
            Log.error(exception: ex) { "Error sending IPv4 multicast" }
          end
        end

        # Send to IPv6 multicast
        if sock6 = @socket_ipv6
          interface_ids = @ipv6_interface_ids.empty? ? [0_u32] : @ipv6_interface_ids
          @ipv6_send_mutex.synchronize do
            interface_ids.each do |index|
              outgoing = index == 0 ? packet : packet_for_interface(packet, index)
              next if outgoing.answers.empty? && outgoing.authorities.empty? && outgoing.additionals.empty?
              # Crystal permits zone IDs only on link-local unicast addresses.
              # IPV6_MULTICAST_IF selects this link-local multicast route.
              sock6.multicast_interface(index) if index > 0
              bytes_sent = sock6.send(outgoing.to_slice, MDNS_IPV6)
              Log.trace { "Sent #{bytes_sent} bytes to IPv6 multicast on interface #{index}" }
            rescue ex
              Log.error(exception: ex) { "Error sending IPv6 multicast on interface #{index}" }
            end
          end
        end
      end

      # Never advertise an interface's link-local AAAA on another interface:
      # the scanner scopes a link-local answer to the interface it arrived on.
      private def packet_for_interface(packet : DNS::Packet, index : UInt32) : DNS::Packet
        addresses = @interface_addresses[index]? || [] of Socket::IPAddress
        permitted = addresses.select { |ip| @ip_addresses.any?(&.address.==(ip.address)) }
        packet_with_addresses(packet, permitted)
      end

      # IPv4 multicast uses the OS-selected outgoing interface. On Unix the
      # address map supplies that interface's A/AAAA records. On Windows, or
      # when interface enumeration failed, answer with the selected IPv4 A
      # only rather than leaking other interfaces' address records.
      protected def packet_for_ipv4_source(packet : DNS::Packet, source : Socket::IPAddress) : DNS::Packet
        @interface_addresses.each do |index, addresses|
          if index > 0 && addresses.any?(&.address.==(source.address))
            return packet_for_interface(packet, index)
          end
        end
        packet_with_addresses(packet, [source])
      end

      private def ipv4_multicast_source : Socket::IPAddress?
        probe = UDPSocket.new(:inet)
        probe.connect(MDNS_IPV4)
        Socket::IPAddress.new(probe.local_address.address, Network::UNSPECIFIED_PORT)
      rescue error : IO::Error
        Log.debug(exception: error) { "Could not determine outgoing IPv4 mDNS interface" }
        nil
      ensure
        probe.try(&.close)
      end

      private def packet_with_addresses(packet : DNS::Packet,
                                        permitted : Array(Socket::IPAddress)) : DNS::Packet
        allowed_data = permitted.map do |ip|
          if ip.family.inet6?
            RecordBuilder.build_aaaa("interface.local", ip, DEFAULT_TTL).resource_data
          else
            RecordBuilder.build_a("interface.local", ip, DEFAULT_TTL).resource_data
          end
        end
        filter = ->(records : Array(DNS::Packet::ResourceRecord)) do
          records.select do |record|
            !record.type.in?(RecordBuilder::TYPE_A, RecordBuilder::TYPE_AAAA) ||
              allowed_data.any?(&.==(record.resource_data))
          end
        end
        DNS::Packet.new(id: MDNS_RESPONSE_ID, response: true, authoritative_answer: true,
          answers: filter.call(packet.answers), authorities: filter.call(packet.authorities),
          additionals: filter.call(packet.additionals))
      end

      # IPv4 receive loop
      private def receive_loop_ipv4(sock : UDPSocket) : Nil
        buffer = Bytes.new(9000) # Max DNS packet size
        data = nil

        while @running
          begin
            bytes_read, peer_address = sock.receive(buffer)
            next if bytes_read == 0

            data = buffer[0, bytes_read]
            packet = DNS::Packet.from_slice(data)

            # Only process queries (not responses)
            next if packet.response?

            # Call user callback if set
            @on_query.try(&.call(packet, peer_address))

            # Process query and respond if it matches our services
            process_query(packet)
          rescue IO::TimeoutError
            # Normal - continue
          rescue ex : Exception
            Log.debug(exception: ex) { "Error receiving IPv4 mDNS packet (bytes=#{data.try(&.size) || 0})" } if @running
          end
        end
      end

      # IPv6 receive loop
      private def receive_loop_ipv6(sock : UDPSocket) : Nil
        buffer = Bytes.new(9000) # Max DNS packet size
        data = nil

        while @running
          begin
            bytes_read, peer_address = sock.receive(buffer)
            next if bytes_read == 0

            data = buffer[0, bytes_read]
            packet = DNS::Packet.from_slice(data)

            # Only process queries (not responses)
            next if packet.response?

            # Call user callback if set
            @on_query.try(&.call(packet, peer_address))

            # Process query and respond if it matches our services
            process_query(packet)
          rescue IO::TimeoutError
            # Normal - continue
          rescue ex : Exception
            Log.debug(exception: ex) { "Error receiving IPv6 mDNS packet (bytes=#{data.try(&.size) || 0})" } if @running
          end
        end
      end

      # Answer every question in `query` that concerns an advertised service:
      # service/subtype browsing (PTR), instance details (SRV/TXT) and host
      # addresses (A/AAAA).
      def process_query(query : DNS::Packet) : Nil
        query.questions.each do |question|
          Log.debug { "Processing question: name=#{question.name}, type=#{question.type}" }
          # Check for service type queries (PTR or ANY)
          if question.type == RecordBuilder::TYPE_PTR || question.type == QTYPE_ANY
            check_service_query(question.name)

            if question.type == QTYPE_ANY
              # For ANY queries, also check if it's an instance-specific query and/or
              # a hostname query.
              check_instance_query(question.name)
              if hostname = advertised_hostname_for(question.name)
                send_hostname_response(hostname)
              end
            end
          elsif question.type.in?(RecordBuilder::TYPE_SRV, RecordBuilder::TYPE_TXT)
            # Specific instance queries (SRV/TXT) use the full instance name as the query name.
            check_instance_query(question.name)
          elsif question.type.in?(RecordBuilder::TYPE_A, RecordBuilder::TYPE_AAAA)
            # Hostname queries (A/AAAA) use the SRV target hostname as the query name.
            if hostname = advertised_hostname_for(question.name)
              send_hostname_response(hostname)
            end
          else
            # Fallback: if we see unexpected QTYPEs but the name matches a hostname,
            # return the hostname records anyway.
            if hostname = advertised_hostname_for(question.name)
              send_hostname_response(hostname)
            end
          end
        end
      end

      # Answer a browse (PTR) query naming an advertised service or one of its subtypes.
      private def check_service_query(query_name : String) : Nil
        @advertised_services.each do |instance, service|
          next unless browse_names(service).any? { |name| dns_name_matches?(name, query_name) }

          Log.debug { "Query matches our service: #{query_name}, sending response for instance: #{instance}" }
          send_announcement(service_records(instance, service))
        end
      end

      # Answer a query naming an advertised instance directly.
      private def check_instance_query(query_name : String) : Nil
        @advertised_services.each do |instance, service|
          next unless dns_name_matches?(instance, query_name)

          send_announcement(service_records(instance, service))
        end
      end

      private def advertised_hostname_for(name : String) : String?
        @advertised_services.each_value do |(_, _, _, _, hostname)|
          return hostname if dns_name_matches?(hostname, name)
        end
        nil
      end

      private def operational_hostname(info : OperationalInfo) : String
        fabric_hex = info.compressed_fabric_id.hexstring.upcase
        node_hex = Hex.node_id(info.node_id)
        "#{fabric_hex}-#{node_hex}.local"
      end

      private def send_hostname_response(hostname : String) : Nil
        # Send A/AAAA records for the requested hostname
        records = [] of DNS::Packet::ResourceRecord

        @ip_addresses.each do |ip|
          case ip.family
          when .inet?
            records << RecordBuilder.build_a(hostname, ip, DEFAULT_TTL)
          when .inet6?
            records << RecordBuilder.build_aaaa(hostname, ip, DEFAULT_TTL)
          end
        end

        return if records.empty?

        packet = DNS::Packet.new(
          id: 0_u16,
          response: true,
          authoritative_answer: true,
          answers: records
        )

        send_multicast(packet)
      end
    end
  end
end
