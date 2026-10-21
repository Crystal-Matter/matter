require "../registry"

module ChipTool
  module Commands
    module Descriptor
      extend self

      def register : Nil
        Registry.register("descriptor", "read", "Read Descriptor cluster attributes") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          attribute = args.shift?
          node_id_str = args.shift?
          endpoint_str = args.shift?

          unless attribute && node_id_str && endpoint_str
            STDERR.puts "Usage: descriptor read parts-list <node-id> <endpoint-id>"
            next 2
          end

          cluster_id = Matter::Cluster::Descriptor::CLUSTER_ID
          attribute_id = case attribute
                         when "parts-list" then Matter::Cluster::Descriptor::ATTR_PARTS_LIST
                         else
                           STDERR.puts "Unsupported attribute: #{attribute} (supported: parts-list)"
                           next 2
                         end

          node_id = parse_u64(node_id_str) || raise ArgumentError.new("invalid node-id: #{node_id_str}")
          endpoint_id = endpoint_str.to_u16

          store = ctx.state_store
          state = store.load
          fabric = state.fabric || raise Matter::CommissioningError.new("No controller fabric found; run `pairing code ...` first")

          peer = resolve_peer(state, fabric, node_id, ctx.timeout)
          state.nodes[node_id] = Matter::Controller::NodeInfo.new(node_id, peer.address, peer.port)
          store.save(state)

          controller = Matter::Controller::Client.new(
            unsecured_source_node_id: state.commissioner_node_id,
            initial_unsecured_message_counter: state.unsecured_message_counter
          )
          begin
            session = Matter::Controller::Pairing::CasePairing.new.pair(controller, peer, fabric, peer_node_id: node_id, timeout: ctx.timeout)
            im = Matter::Controller::ImClient.new(controller, ctx.timeout)
            report = im.read_attribute(
              session: session,
              peer: peer,
              endpoint_id: endpoint_id,
              cluster_id: cluster_id,
              attribute_id: attribute_id
            )

            endpoints = extract_report_u16_list(report, cluster_id, attribute_id) || raise Matter::ProtocolError.new("ReportData missing #{attribute} list")
            puts "PartsList: #{endpoints.size} entries"
            endpoints.each_with_index do |endpoint, idx|
              puts "  [#{idx}]: #{endpoint}"
            end
            0
          ensure
            state.unsecured_message_counter = controller.transport.message_counter.counter
            store.save(state)
            controller.close
          end
        end
      end

      private def parse_u64(s : String) : UInt64?
        v = s.strip
        return if v.empty?
        if v.starts_with?("0x") || v.starts_with?("0X")
          v[2..].to_u64?(16)
        else
          v.to_u64?
        end
      end

      private def resolve_peer(state : Matter::Controller::State, fabric : Matter::Controller::FabricInfo, node_id : UInt64, timeout : Time::Span) : Socket::IPAddress
        if info = state.nodes[node_id]?
          if addr = info.address
            return Socket::IPAddress.new(addr, info.port)
          end
        end

        scanner = nil.as(Matter::Controller::Scanner?)
        scanner = Matter::Controller::Scanner.new
        scanner.start
        scanner.query_operational

        deadline = Time.instant + timeout
        loop do
          if dev = scanner.operational_devices.find { |device| device.fabric_id == fabric.compressed_fabric_id && device.node_id == node_id }
            address = dev.addresses.find(&.family.inet?) || dev.addresses.first?
            if addr = address
              return Socket::IPAddress.new(addr.address, dev.port)
            end
          end
          break if Time.instant >= deadline
          sleep 100.milliseconds
        end

        raise Matter::TransportError.new("Failed to resolve operational address via mDNS (fabric_id=0x#{fabric.fabric_id.to_s(16)} node_id=0x#{node_id.to_s(16)})")
      ensure
        scanner.try(&.close)
      end

      private def extract_report_u16_list(report : Matter::InteractionModel::ReportDataMessage, cluster_id : UInt32, attribute_id : UInt32) : Array(UInt16)?
        reports = report.attribute_reports
        return unless reports

        reports.each do |attr_report|
          data = attr_report.attribute_data
          next unless data
          path = data.path
          next unless path.cluster == cluster_id
          next unless path.attribute == attribute_id

          any = data.data
          list = any.value.as?(Array(TLV::Any)) || return

          values = [] of UInt16
          list.each_with_index do |elem, idx|
            break if idx >= 4096
            v = elem.value
            next unless v.is_a?(Int)
            next if v < 0
            value_u64 = v.to_u64

            next if value_u64 > UInt16::MAX
            values << value_u64.to_u16
          end

          return values
        end

        nil
      end
    end
  end
end
