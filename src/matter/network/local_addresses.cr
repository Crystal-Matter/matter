require "socket"

{% unless flag?(:win32) %}
  # getifaddrs is available on the Unix platforms supported by Crystal. The
  # first four fields of ifaddrs have the same layout on Linux and BSD/macOS.
  lib LibInterfaceAddresses
    struct Ifaddrs
      ifa_next : Ifaddrs*
      ifa_name : UInt8*
      ifa_flags : UInt32
      ifa_addr : LibC::Sockaddr*
    end

    fun getifaddrs(result : Void*) : Int32
    fun freeifaddrs(result : Void*) : Void
    fun if_nametoindex(name : UInt8*) : UInt32
  end
{% end %}

module Matter
  module Network
    # Used as a fallback when the platform cannot enumerate interfaces.
    IPV6_ROUTE_PROBE = Socket::IPAddress.new("2606:4700:4700::1111", 53)
    IPV4_ROUTE_PROBE = Socket::IPAddress.new("8.8.8.8", 80)

    LOOPBACK_ADDRESS = Socket::IPAddress.new("127.0.0.1", 0)
    UNSPECIFIED_PORT = 0

    {% unless flag?(:win32) %}
      INTERFACE_UP       =  0x1_u32
      INTERFACE_LOOPBACK =  0x8_u32
      INTERFACE_RUNNING  = 0x40_u32
    {% end %}

    # Enumerate addresses assigned to active local interfaces. Matter mDNS is
    # local-network discovery, so a public internet route is not required.
    def self.local_ip_addresses : Array(Socket::IPAddress)
      {% if flag?(:win32) %}
        select_local_ip_addresses(route_probe_addresses)
      {% else %}
        select_local_ip_addresses(interface_addresses)
      {% end %}
    end

    # Preserve the interface identity needed for link-local IPv6 multicast on
    # Unix. Windows currently exposes the addresses under the default index
    # only; its responder keeps default-interface IPv6 multicast behavior.
    # Addresses are normalized in the same way as local_ip_addresses so an
    # advertiser can match its configured address list against this map.
    def self.local_ip_addresses_by_interface : Hash(UInt32, Array(Socket::IPAddress))
      {% if flag?(:win32) %}
        {0_u32 => local_ip_addresses}
      {% else %}
        interface_addresses_by_index
      {% end %}
    end

    # Keep every usable local address so IPv6-only, dual-stack, and multihomed
    # networks can discover the device. Prefer IPv6 with a non-link-local scope,
    # then IPv4, then link-local addresses. The caller advertises all of them.
    def self.select_local_ip_addresses(candidates : Array(Socket::IPAddress)) : Array(Socket::IPAddress)
      addresses = candidates.reject { |address| address.loopback? || address.unspecified? }
        .map { |address| Socket::IPAddress.new(address.address, UNSPECIFIED_PORT) }
        .uniq!
      addresses.sort_by! do |address|
        if address.family.inet6?
          address.link_local? ? 2 : 0
        else
          address.link_local? ? 3 : 1
        end
      end

      if addresses.empty?
        Log.warn { "no usable network interface found, falling back to #{LOOPBACK_ADDRESS.address}" }
        addresses << LOOPBACK_ADDRESS
      end
      addresses
    end

    {% unless flag?(:win32) %}
      private def self.interface_addresses_by_index : Hash(UInt32, Array(Socket::IPAddress))
        addresses = Hash(UInt32, Array(Socket::IPAddress)).new do |hash, index|
          hash[index] = [] of Socket::IPAddress
        end
        result_holder = Pointer(Pointer(LibInterfaceAddresses::Ifaddrs)).malloc(1)
        result_holder.value = Pointer(LibInterfaceAddresses::Ifaddrs).null
        if LibInterfaceAddresses.getifaddrs(result_holder.as(Void*)) != 0
          Log.warn { "unable to enumerate indexed network interfaces: #{Errno.value}" }
          return addresses
        end

        current = result_holder.value
        until current.null?
          interface = current.value
          active = interface.ifa_flags & (INTERFACE_UP | INTERFACE_RUNNING) == (INTERFACE_UP | INTERFACE_RUNNING)
          loopback = interface.ifa_flags & INTERFACE_LOOPBACK != 0
          if active && !loopback && (sockaddr = interface.ifa_addr) && !interface.ifa_name.null?
            family = sockaddr.value.sa_family
            if family == LibC::AF_INET || family == LibC::AF_INET6
              index = LibInterfaceAddresses.if_nametoindex(interface.ifa_name)
              if index > 0
                address = Socket::IPAddress.from(sockaddr)
                unless address.loopback? || address.unspecified?
                  normalized = Socket::IPAddress.new(address.address, UNSPECIFIED_PORT)
                  addresses[index] << normalized unless addresses[index].includes?(normalized)
                end
              end
            end
          end
          current = interface.ifa_next
        end
        addresses
      ensure
        if result_holder
          result = result_holder.value
          LibInterfaceAddresses.freeifaddrs(result) unless result.null?
        end
      end

      private def self.interface_addresses : Array(Socket::IPAddress)
        result_holder = Pointer(Pointer(LibInterfaceAddresses::Ifaddrs)).malloc(1)
        result_holder.value = Pointer(LibInterfaceAddresses::Ifaddrs).null
        if LibInterfaceAddresses.getifaddrs(result_holder.as(Void*)) != 0
          Log.warn { "unable to enumerate local network interfaces: #{Errno.value}" }
          return route_probe_addresses
        end

        addresses = [] of Socket::IPAddress
        result = result_holder.value
        current = result
        while current
          break if current.null?
          interface = current.value
          active = interface.ifa_flags & (INTERFACE_UP | INTERFACE_RUNNING) == (INTERFACE_UP | INTERFACE_RUNNING)
          loopback = interface.ifa_flags & INTERFACE_LOOPBACK != 0
          if active && !loopback && (sockaddr = interface.ifa_addr)
            family = sockaddr.value.sa_family
            if family == LibC::AF_INET || family == LibC::AF_INET6
              addresses << Socket::IPAddress.from(sockaddr)
            end
          end
          current = interface.ifa_next
        end
        addresses
      ensure
        if result_holder
          result = result_holder.value
          LibInterfaceAddresses.freeifaddrs(result) unless result.null?
        end
      end
    {% end %}

    private def self.route_probe_addresses : Array(Socket::IPAddress)
      {IPV6_ROUTE_PROBE, IPV4_ROUTE_PROBE}.compact_map { |probe| outbound_address(probe) }
    end

    private def self.outbound_address(probe : Socket::IPAddress) : Socket::IPAddress?
      socket = UDPSocket.new(probe.family)
      socket.connect(probe)
      Socket::IPAddress.new(socket.local_address.address, UNSPECIFIED_PORT)
    rescue error : IO::Error
      Log.warn(exception: error) { "unable to determine the local #{probe.family} address" }
      nil
    ensure
      socket.try &.close
    end
  end
end
