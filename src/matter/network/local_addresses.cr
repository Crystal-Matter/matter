require "socket"

{% if flag?(:win32) %}
  # IP Helper exposes the adapter's IPv6 interface index, which is required
  # to join and send link-local multicast on every active Windows interface.
  @[Link("iphlpapi")]
  lib LibWindowsAdapters
    PHYSICAL_ADDRESS_MAX_LENGTH = 8

    struct SocketAddress
      address : LibC::Sockaddr*
      length : Int32
    end

    struct UnicastAddress
      length : UInt32
      flags : UInt32
      next_address : UnicastAddress*
      address : SocketAddress
    end

    struct AdapterAddress
      length : UInt32
      if_index : UInt32
      next_adapter : AdapterAddress*
      adapter_name : UInt8*
      first_unicast_address : UnicastAddress*
      first_anycast_address : Void*
      first_multicast_address : Void*
      first_dns_server_address : Void*
      dns_suffix : UInt16*
      description : UInt16*
      friendly_name : UInt16*
      physical_address : StaticArray(UInt8, PHYSICAL_ADDRESS_MAX_LENGTH)
      physical_address_length : UInt32
      flags : UInt32
      mtu : UInt32
      if_type : UInt32
      oper_status : UInt32
      ipv6_if_index : UInt32
    end

    fun GetAdaptersAddresses(family : UInt32, flags : UInt32, reserved : Void*,
                             addresses : AdapterAddress*, size : UInt32*) : UInt32
  end
{% else %}
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

    {% if flag?(:win32) %}
      WINDOWS_ADAPTER_BUFFER_BYTES     = 15 * 1024
      WINDOWS_ADAPTER_BUFFER_MAX_BYTES = 1024 * 1024
      WINDOWS_ADAPTER_BUFFER_RETRIES   =          3
      WINDOWS_ADAPTER_DEFAULT_FLAGS    =      0_u32
      WINDOWS_ADAPTER_BUFFER_OVERFLOW  =    111_u32
      WINDOWS_ADAPTER_SUCCESS          =      0_u32
      WINDOWS_ADAPTER_OPER_STATUS_UP   =      1_u32
      WINDOWS_ADAPTER_TYPE_LOOPBACK    =     24_u32
      WINDOWS_ADAPTER_NO_MULTICAST     = 0x0010_u32
    {% else %}
      INTERFACE_UP       =  0x1_u32
      INTERFACE_LOOPBACK =  0x8_u32
      INTERFACE_RUNNING  = 0x40_u32
    {% end %}

    # Enumerate addresses assigned to active local interfaces. Matter mDNS is
    # local-network discovery, so a public internet route is not required.
    def self.local_ip_addresses : Array(Socket::IPAddress)
      {% if flag?(:win32) %}
        indexed = local_ip_addresses_by_interface.values.flatten
        select_local_ip_addresses(indexed.empty? ? route_probe_addresses : indexed)
      {% else %}
        select_local_ip_addresses(interface_addresses)
      {% end %}
    end

    # Preserve the interface identity needed for link-local IPv6 multicast.
    # Addresses are normalized in the same way as local_ip_addresses so an
    # advertiser can match its configured address list against this map.
    def self.local_ip_addresses_by_interface : Hash(UInt32, Array(Socket::IPAddress))
      {% if flag?(:win32) %}
        windows_interface_addresses_by_index
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

    {% if flag?(:win32) %}
      private def self.windows_interface_addresses_by_index : Hash(UInt32, Array(Socket::IPAddress))
        addresses = Hash(UInt32, Array(Socket::IPAddress)).new do |hash, index|
          hash[index] = [] of Socket::IPAddress
        end
        size = WINDOWS_ADAPTER_BUFFER_BYTES.to_u32
        buffer = Bytes.new(size.to_i)
        attempts = 0
        loop do
          result = LibWindowsAdapters.GetAdaptersAddresses(LibC::AF_UNSPEC.to_u32, WINDOWS_ADAPTER_DEFAULT_FLAGS,
            Pointer(Void).null, buffer.to_unsafe.as(LibWindowsAdapters::AdapterAddress*), pointerof(size))
          case result
          when WINDOWS_ADAPTER_SUCCESS
            break
          when WINDOWS_ADAPTER_BUFFER_OVERFLOW
            attempts += 1
            if attempts >= WINDOWS_ADAPTER_BUFFER_RETRIES || size > WINDOWS_ADAPTER_BUFFER_MAX_BYTES
              Log.warn { "Windows adapter list exceeded the supported buffer size" }
              return addresses
            end
            buffer = Bytes.new(size.to_i)
          else
            Log.warn { "unable to enumerate Windows network adapters: error #{result}" }
            return addresses
          end
        end

        adapter_pointer = buffer.to_unsafe.as(LibWindowsAdapters::AdapterAddress*)
        until adapter_pointer.null?
          adapter = adapter_pointer.value
          if adapter.oper_status == WINDOWS_ADAPTER_OPER_STATUS_UP &&
             adapter.if_type != WINDOWS_ADAPTER_TYPE_LOOPBACK &&
             adapter.flags & WINDOWS_ADAPTER_NO_MULTICAST == 0
            unicast_pointer = adapter.first_unicast_address
            until unicast_pointer.null?
              unicast = unicast_pointer.value
              sockaddr = unicast.address.address
              unless sockaddr.null?
                family = sockaddr.value.sa_family
                if family == LibC::AF_INET || family == LibC::AF_INET6
                  index = family == LibC::AF_INET6 ? adapter.ipv6_if_index : adapter.if_index
                  if index > 0
                    address = Socket::IPAddress.from(sockaddr, unicast.address.length)
                    unless address.loopback? || address.unspecified?
                      normalized = Socket::IPAddress.new(address.address, UNSPECIFIED_PORT)
                      addresses[index] << normalized unless addresses[index].includes?(normalized)
                    end
                  end
                end
              end
              unicast_pointer = unicast.next_address
            end
          end
          adapter_pointer = adapter.next_adapter
        end
        addresses
      end
    {% else %}
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
