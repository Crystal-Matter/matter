module Matter
  module Network
    # WiFi Security Types
    enum WiFiSecurityType
      Open
      WEP
      WPA_Personal
      WPA2_Personal
      WPA3_Personal
    end

    # WiFi Credentials
    #
    # Represents parsed WiFi credentials in a structured format.
    # The backend can use this information to configure the network interface
    # without needing to parse raw bytes.
    class WiFiCredentials
      # The credential data (passphrase or PSK)
      getter credentials : Bytes

      # Inferred security type based on credential length and format
      getter security_type : WiFiSecurityType

      # Whether this is a raw PSK (true) or passphrase (false)
      getter? is_psk : Bool

      def initialize(@credentials : Bytes)
        @security_type, @is_psk = infer_security_type(@credentials)
      end

      # Infer security type from credential length and format
      private def infer_security_type(creds : Bytes) : {WiFiSecurityType, Bool}
        case creds.size
        when 0
          # Open network
          {WiFiSecurityType::Open, false}
        when 5
          # WEP-64 passphrase
          {WiFiSecurityType::WEP, false}
        when 10
          # WEP-64 hex PSK (10 hex chars = 40 bits)
          if hex_string?(creds)
            {WiFiSecurityType::WEP, true}
          else
            # Treat as passphrase if not valid hex
            {WiFiSecurityType::WPA_Personal, false}
          end
        when 13
          # WEP-128 passphrase
          {WiFiSecurityType::WEP, false}
        when 26
          # WEP-128 hex PSK (26 hex chars = 104 bits)
          if hex_string?(creds)
            {WiFiSecurityType::WEP, true}
          else
            # Treat as passphrase if not valid hex
            {WiFiSecurityType::WPA_Personal, false}
          end
        when 8..63
          # WPA/WPA2/WPA3 passphrase
          {WiFiSecurityType::WPA2_Personal, false}
        when 64
          # WPA/WPA2/WPA3 hex PSK (64 hex chars = 256 bits)
          if hex_string?(creds)
            {WiFiSecurityType::WPA2_Personal, true}
          else
            # Invalid - too long for passphrase
            {WiFiSecurityType::WPA2_Personal, false}
          end
        else
          # Default to WPA2 passphrase for other lengths
          {WiFiSecurityType::WPA2_Personal, false}
        end
      end

      # Check if bytes represent a valid hex string (all chars 0-9, A-F, a-f)
      private def hex_string?(bytes : Bytes) : Bool
        bytes.all? do |byte|
          (byte >= 0x30 && byte <= 0x39) ||   # 0-9
            (byte >= 0x41 && byte <= 0x46) || # A-F
            (byte >= 0x61 && byte <= 0x66)    # a-f
        end
      end

      # Get credentials as a string (for passphrases)
      def passphrase : String
        String.new(@credentials)
      end

      # Get credentials as hex string (for PSKs)
      def psk_hex : String
        @credentials.hexstring
      end

      # Get raw credential bytes
      def raw : Bytes
        @credentials
      end

      def to_s(io : IO)
        io << "WiFiCredentials("
        io << "security=" << @security_type
        io << ", type=" << (@is_psk ? "PSK" : "passphrase")
        io << ", length=" << @credentials.size
        io << ")"
      end
    end

    # Thread Network Credentials
    #
    # Represents a Thread Operational Dataset with parsed fields.
    # The operational dataset contains all parameters needed to join a Thread network.
    class ThreadCredentials
      enum DatasetField : UInt8
        Channel       = 0x00
        PanId         = 0x01
        ExtendedPanId = 0x02
        NetworkName   = 0x03
        NetworkKey    = 0x05
      end

      # The complete operational dataset (TLV-encoded)
      getter operational_dataset : Bytes

      # Extended PAN ID (8 bytes) - uniquely identifies the Thread network
      getter extended_pan_id : Bytes

      # Network name (optional, human-readable)
      property network_name : String?

      # PAN ID (2 bytes, optional)
      property pan_id : UInt16?

      # Channel (optional)
      property channel : UInt8?

      # Network master key (16 bytes, optional)
      property network_key : Bytes?

      def initialize(@operational_dataset : Bytes)
        # Parse the operational dataset to extract key fields
        @extended_pan_id = extract_extended_pan_id(@operational_dataset)
        @network_name = extract_network_name(@operational_dataset)
        @pan_id = extract_pan_id(@operational_dataset)
        @channel = extract_channel(@operational_dataset)
        @network_key = extract_network_key(@operational_dataset)
      end

      # Parse TLV-encoded operational dataset and build a hash of fields
      private def parse_tlv(dataset : Bytes) : Hash(UInt8, Bytes)
        fields = {} of UInt8 => Bytes
        offset = 0

        while offset < dataset.size
          # Need at least 2 bytes for type and length
          break if offset + 2 > dataset.size

          type = dataset[offset]
          length = dataset[offset + 1]
          offset += 2

          # Check if we have enough bytes for the value
          break if offset + length > dataset.size

          # Extract value
          value = dataset[offset, length]
          fields[type] = value
          offset += length
        end

        fields
      end

      # Extract Extended PAN ID from operational dataset
      # TLV Type: 0x02, Length: 8 bytes
      private def extract_extended_pan_id(dataset : Bytes) : Bytes
        fields = parse_tlv(dataset)

        # Look for Extended PAN ID (Type 0x02)
        if xpan = fields[DatasetField::ExtendedPanId.value]?
          return xpan if xpan.size == 8
        end

        # Fallback: use first 8 bytes or entire dataset
        if dataset.size >= 8
          dataset[0, 8]
        else
          dataset
        end
      end

      # Extract network name from operational dataset
      # TLV Type: 0x03, Length: 1-16 bytes
      private def extract_network_name(dataset : Bytes) : String?
        fields = parse_tlv(dataset)

        # Look for Network Name (Type 0x03)
        if name_bytes = fields[DatasetField::NetworkName.value]?
          return String.new(name_bytes) if name_bytes.size >= 1 && name_bytes.size <= 16
        end

        nil
      end

      # Extract PAN ID from operational dataset
      # TLV Type: 0x01, Length: 2 bytes
      private def extract_pan_id(dataset : Bytes) : UInt16?
        fields = parse_tlv(dataset)

        # Look for PAN ID (Type 0x01)
        if pan_bytes = fields[DatasetField::PanId.value]?
          if pan_bytes.size == 2
            # Convert 2 bytes to UInt16 (big-endian)
            return (pan_bytes[0].to_u16 << 8) | pan_bytes[1].to_u16
          end
        end

        nil
      end

      # Extract channel from operational dataset
      # TLV Type: 0x00, Length: 3 bytes (but only first byte is channel)
      private def extract_channel(dataset : Bytes) : UInt8?
        fields = parse_tlv(dataset)

        # Look for Channel (Type 0x00)
        if channel_bytes = fields[DatasetField::Channel.value]?
          if channel_bytes.size >= 1
            # First byte is the channel number
            return channel_bytes[0]
          end
        end

        nil
      end

      # Extract network master key from operational dataset
      # TLV Type: 0x05, Length: 16 bytes
      private def extract_network_key(dataset : Bytes) : Bytes?
        fields = parse_tlv(dataset)

        # Look for Network Key (Type 0x05)
        if key = fields[DatasetField::NetworkKey.value]?
          return key if key.size == 16
        end

        nil
      end

      # Get the network ID (Extended PAN ID)
      def network_id : Bytes
        @extended_pan_id
      end

      # Get raw operational dataset
      def raw : Bytes
        @operational_dataset
      end

      def to_s(io : IO)
        io << "ThreadCredentials("
        io << "xpan=" << @extended_pan_id.hexstring
        io << ", name=" << (@network_name || "unknown")
        io << ", dataset_size=" << @operational_dataset.size
        io << ")"
      end
    end
  end
end
