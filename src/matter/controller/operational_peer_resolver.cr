require "./scanner"
require "./state"

module Matter
  module Controller
    # Resolve an operational node by the identity that appears in DNS-SD.
    # Saved IP addresses are reachability hints: they can change when a node
    # moves networks, and CASE authenticates the selected fabric and Node ID.
    class OperationalPeerResolver
      POLL_INTERVAL = 100.milliseconds

      def resolve(state : State, fabric : FabricInfo, node_id : UInt64,
                  timeout : Time::Span = 10.seconds,
                  peer_hint : Socket::IPAddress? = nil) : Socket::IPAddress
        if peer = discover(fabric.compressed_fabric_id, node_id, timeout)
          return peer
        end
        if info = state.nodes_for(fabric.fabric_id, fabric.root_public_key,
             fabric.controller_node_id)[node_id]?
          if address = info.address
            return Socket::IPAddress.new(address, info.port)
          end
        end
        return peer_hint if peer_hint
        raise Matter::TransportError.new("Could not resolve operational node 0x#{node_id.to_s(16)} on fabric 0x#{fabric.fabric_id.to_s(16)}")
      end

      # An instance name contains the compressed fabric ID, not the raw fabric
      # ID. Matching both fields prevents same-Node-ID peers on other fabrics
      # from being selected before CASE can authenticate them.
      def self.select_peer(devices : Array(DiscoveredDevice), compressed_fabric_id : UInt64,
                           node_id : UInt64) : Socket::IPAddress?
        devices.each do |device|
          next unless device.fabric_id == compressed_fabric_id && device.node_id == node_id
          # Matter operational traffic uses IPv6. An IPv4 DNS-SD address may
          # coexist on a dual-stack interface, so select IPv6 when available.
          address = device.addresses.find(&.family.inet6?) || device.addresses.first?
          if address
            # Socket::IPAddress#address omits the scope identifier. Retain it
            # when changing the port of a link-local AAAA record so the CASE
            # datagram reaches the interface that supplied the mDNS answer.
            return Socket::IPAddress.new(address_hint(address), device.port)
          end
        end
        nil
      end

      # Persist the interface scope with link-local IPv6 hints. `#address`
      # returns only the numeric host and silently drops the scope.
      def self.address_hint(peer : Socket::IPAddress) : String
        peer.zone_id > 0 ? "#{peer.address}%#{peer.zone_id}" : peer.address
      end

      protected def discover(compressed_fabric_id : UInt64, node_id : UInt64,
                             timeout : Time::Span) : Socket::IPAddress?
        scanner = Scanner.new
        begin
          scanner.start
          scanner.query_operational
          deadline = Time.instant + timeout
          loop do
            if peer = self.class.select_peer(scanner.operational_devices, compressed_fabric_id, node_id)
              return peer
            end
            break if Time.instant >= deadline
            sleep POLL_INTERVAL
          end
          nil
        ensure
          scanner.close
        end
      end
    end
  end
end
