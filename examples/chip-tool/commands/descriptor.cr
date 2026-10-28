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

          peer = Matter::Controller::OperationalPeerResolver.new.resolve(state, fabric, node_id, ctx.timeout)

          controller = Matter::Controller::Client.new(
            counter_lease: store.counter_lease(state.commissioner_node_id)
          )
          begin
            session = ctx.case_pairing.pair(controller, peer, fabric, peer_node_id: node_id, timeout: ctx.timeout)
            store.update do |current|
              current.record_node(fabric.fabric_id, Matter::Controller::NodeInfo.new(node_id, Matter::Controller::OperationalPeerResolver.address_hint(peer), peer.port),
                fabric.root_public_key, fabric.controller_node_id)
            end
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
