require "dns"

module Matter
  module MDNS
    # Helper for building DNS resource records for mDNS
    module RecordBuilder
      extend self

      # DNS record types
      TYPE_A    =  1_u16
      TYPE_PTR  = 12_u16
      TYPE_TXT  = 16_u16
      TYPE_AAAA = 28_u16
      TYPE_SRV  = 33_u16

      # DNS class codes
      CLASS_IN             = 0x0001_u16
      CLASS_IN_CACHE_FLUSH = 0x8001_u16 # IN class with cache-flush bit

      # Encode a domain name in DNS format
      # Returns bytes with length-prefixed labels
      private def encode_domain_name(name : String) : Bytes
        io = IO::Memory.new

        name.split('.').each do |label|
          next if label.empty?
          io.write_byte(label.size.to_u8)
          io.write(label.to_slice)
        end
        io.write_byte(0_u8) # Null terminator

        io.to_slice
      end

      # Build PTR record (for service enumeration)
      # Points service type to instance name
      def build_ptr(service : String, instance : String, ttl : Time::Span, cache_flush : Bool = false) : DNS::Packet::ResourceRecord
        resource_data = encode_domain_name(instance)

        DNS::Packet::ResourceRecord.new(
          name: service,
          type: TYPE_PTR,
          class_code: cache_flush ? CLASS_IN_CACHE_FLUSH : CLASS_IN,
          ttl: ttl,
          resource_data: resource_data
        )
      end

      # Build SRV record (service location: priority, weight, port, target)
      def build_srv(instance : String, port : Int32, target : String, ttl : Time::Span, priority : UInt16 = 0_u16, weight : UInt16 = 0_u16) : DNS::Packet::ResourceRecord
        io = IO::Memory.new
        io.write_bytes(priority, IO::ByteFormat::BigEndian)
        io.write_bytes(weight, IO::ByteFormat::BigEndian)
        io.write_bytes(port.to_u16, IO::ByteFormat::BigEndian)
        io.write(encode_domain_name(target))

        DNS::Packet::ResourceRecord.new(
          name: instance,
          type: TYPE_SRV,
          class_code: CLASS_IN_CACHE_FLUSH, # Always cache-flush for SRV
          ttl: ttl,
          resource_data: io.to_slice
        )
      end

      # Build TXT record (service metadata as key=value pairs)
      def build_txt(instance : String, txt_records : Hash(String, String), ttl : Time::Span) : DNS::Packet::ResourceRecord
        io = IO::Memory.new

        txt_records.each do |key, value|
          txt = "#{key}=#{value}"
          io.write_byte(txt.size.to_u8)
          io.write(txt.to_slice)
        end

        # Empty TXT record if no records provided
        if txt_records.empty?
          io.write_byte(0_u8)
        end

        DNS::Packet::ResourceRecord.new(
          name: instance,
          type: TYPE_TXT,
          class_code: CLASS_IN_CACHE_FLUSH, # Always cache-flush for TXT
          ttl: ttl,
          resource_data: io.to_slice
        )
      end

      # Build A record (IPv4 address)
      def build_a(hostname : String, ip : Socket::IPAddress, ttl : Time::Span) : DNS::Packet::ResourceRecord
        raise ArgumentError.new("IP address must be IPv4") unless ip.family.inet?

        # Parse IPv4 address string to 4 bytes
        parts = ip.address.split('.')
        resource_data = Bytes.new(4)
        parts.each_with_index do |part, i|
          resource_data[i] = part.to_u8
        end

        DNS::Packet::ResourceRecord.new(
          name: hostname,
          type: TYPE_A,
          class_code: CLASS_IN_CACHE_FLUSH, # Always cache-flush for A
          ttl: ttl,
          resource_data: resource_data
        )
      end

      # Build AAAA record (IPv6 address)
      def build_aaaa(hostname : String, ip : Socket::IPAddress, ttl : Time::Span) : DNS::Packet::ResourceRecord
        raise ArgumentError.new("IP address must be IPv6") unless ip.family.inet6?

        # Parse IPv6 address string to 16 bytes
        # Handle compressed IPv6 format (e.g., "fe80::1")
        addr = ip.address.split('%', 2)[0]

        # Expand :: notation
        if addr.includes?("::")
          parts = addr.split("::")
          left = parts[0].empty? ? [] of String : parts[0].split(':')
          right = parts[1].empty? ? [] of String : parts[1].split(':')

          # Calculate missing zero groups
          missing = 8 - left.size - right.size

          # Build full address
          full_parts = left + Array.new(missing, "0") + right
        else
          full_parts = addr.split(':')
        end

        # Convert hex strings to bytes
        resource_data = Bytes.new(16)
        full_parts.each_with_index do |part, i|
          value = part.to_u16(16)
          resource_data[i * 2] = (value >> 8).to_u8
          resource_data[i * 2 + 1] = (value & 0xFF).to_u8
        end

        DNS::Packet::ResourceRecord.new(
          name: hostname,
          type: TYPE_AAAA,
          class_code: CLASS_IN_CACHE_FLUSH, # Always cache-flush for AAAA
          ttl: ttl,
          resource_data: resource_data
        )
      end

      # Build NSEC record (for negative caching - optional but recommended)
      # Indicates which record types exist for a name
      def build_nsec(name : String, next_domain : String, types : Array(UInt16), ttl : Time::Span) : DNS::Packet::ResourceRecord
        io = IO::Memory.new

        # Next domain name
        io.write(encode_domain_name(next_domain))

        # Type bitmap (simplified - assumes types < 256)
        # Format: window_block(1) + bitmap_length(1) + bitmap(variable)
        window_block = 0_u8
        io.write_byte(window_block)

        # Calculate bitmap length (covers up to bit 255)
        max_type = types.max
        bitmap_bytes = ((max_type / 8) + 1).to_u8
        io.write_byte(bitmap_bytes)

        # Build bitmap
        bitmap = Bytes.new(bitmap_bytes.to_i32, 0_u8)
        types.each do |type|
          byte_index = (type / 8).to_i32
          bit_index = 7 - (type % 8)
          bitmap[byte_index] |= (1 << bit_index)
        end
        io.write(bitmap)

        DNS::Packet::ResourceRecord.new(
          name: name,
          type: 47_u16, # NSEC
          class_code: CLASS_IN_CACHE_FLUSH,
          ttl: ttl,
          resource_data: io.to_slice
        )
      end
    end
  end
end
