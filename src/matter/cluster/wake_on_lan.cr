require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Wake On LAN server (0x0503). The host must provide addresses
    # for a network interface that can actually receive wake packets while the
    # rest of the device is asleep. Each address is optional on the wire.
    class WakeOnLan < Base
      cluster 0x0503, revision: 1

      MAC_ADDRESS_FORMAT            = /\A[0-9A-F]{12}\z/
      IPV6_ADDRESS_LENGTH           =      16
      LINK_LOCAL_FIRST_BYTE         = 0xfe_u8
      LINK_LOCAL_SECOND_BYTE_MASK   = 0xc0_u8
      LINK_LOCAL_SECOND_BYTE_PREFIX = 0x80_u8

      attribute 0x0000, :mac_address, String, optional: true,
        fixed: true, max_length: 12, computed: true, present_if: :mac_address_present?
      attribute 0x0001, :link_local_address, Bytes, optional: true,
        fixed: true, computed: true, present_if: :link_local_address_present?

      @mac_address : String?
      @link_local_address : Bytes?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @mac_address : String? = nil,
                     link_local_address : Bytes? = nil)
        if mac_address = @mac_address
          raise ArgumentError.new("mac_address must contain 12 upper-case hex digits") unless MAC_ADDRESS_FORMAT.matches?(mac_address)
        end

        if address = link_local_address
          unless address.size == IPV6_ADDRESS_LENGTH &&
                 address[0] == LINK_LOCAL_FIRST_BYTE &&
                 (address[1] & LINK_LOCAL_SECOND_BYTE_MASK) == LINK_LOCAL_SECOND_BYTE_PREFIX
            raise ArgumentError.new("link_local_address must be a 16-byte IPv6 link-local address")
          end
        end

        @link_local_address = link_local_address.try(&.dup)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def mac_address : String
        @mac_address || raise ArgumentError.new("mac_address is not configured")
      end

      def link_local_address : Bytes
        address = @link_local_address || raise ArgumentError.new("link_local_address is not configured")
        address.dup
      end

      def mac_address=(_value : String) : Nil
        raise ArgumentError.new("fixed Wake On LAN addresses cannot change after construction")
      end

      private def mac_address_present? : Bool
        !@mac_address.nil?
      end

      private def link_local_address_present? : Bool
        !@link_local_address.nil?
      end
    end
  end
end
