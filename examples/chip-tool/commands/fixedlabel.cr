require "../registry"

module ChipTool
  module Commands
    module FixedLabel
      extend self

      def register : Nil
        Registry.register("fixedlabel", "read", "Read FixedLabel cluster attributes") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          attribute = args.shift?
          node_id_str = args.shift?
          endpoint_str = args.shift?

          unless attribute && node_id_str && endpoint_str
            STDERR.puts "Usage: fixedlabel read label-list <node-id> <endpoint-id>"
            next 2
          end

          cluster_id = Matter::Cluster::FixedLabel::CLUSTER_ID
          attribute_id = case attribute
                         when "label-list" then Matter::Cluster::FixedLabel::ATTR_LABEL_LIST
                         else
                           STDERR.puts "Unsupported attribute: #{attribute} (supported: label-list)"
                           next 2
                         end

          node_id = parse_u64(node_id_str) || raise ArgumentError.new("invalid node-id: #{node_id_str}")
          endpoint_id = endpoint_str.to_u16

          labels = read_label_list(ctx, node_id, endpoint_id, cluster_id, attribute_id)
          puts "LabelList: #{labels.size} entries"
          labels.each_with_index do |label, idx|
            puts "  [#{idx}] label=#{label.label.inspect} value=#{label.value.inspect}"
          end
          0
        end

        Registry.register("fixedlabel", "check-example", "Assert FixedLabel LabelList values start with \"Example\"") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          node_id_str = args.shift?
          endpoint_str = args.shift?

          unless node_id_str && endpoint_str
            STDERR.puts "Usage: fixedlabel check-example <node-id> <endpoint-id>"
            next 2
          end

          node_id = parse_u64(node_id_str) || raise ArgumentError.new("invalid node-id: #{node_id_str}")
          endpoint_id = endpoint_str.to_u16

          cluster_id = Matter::Cluster::FixedLabel::CLUSTER_ID
          attribute_id = Matter::Cluster::FixedLabel::ATTR_LABEL_LIST

          labels = read_label_list(ctx, node_id, endpoint_id, cluster_id, attribute_id)
          if labels.empty?
            STDERR.puts "FixedLabel LabelList is empty"
            next 1
          end

          bad_label = false
          labels.each do |label|
            next if label.value.starts_with?("Example")
            STDERR.puts "FixedLabel value does not start with \"Example\": #{label.value.inspect}"
            bad_label = true
            break
          end

          next 1 if bad_label

          puts "OK"
          0
        end
      end

      private def read_label_list(
        ctx : Context,
        node_id : UInt64,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        attribute_id : UInt32,
      ) : Array(Matter::Cluster::LabelStruct)
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

          extract_report_label_list(report, cluster_id, attribute_id) || raise Matter::ProtocolError.new("ReportData missing LabelList")
        ensure
          controller.close
        end
      end

      private def extract_report_label_list(report : Matter::InteractionModel::ReportDataMessage, cluster_id : UInt32, attribute_id : UInt32) : Array(Matter::Cluster::LabelStruct)?
        reports = report.attribute_reports
        return unless reports

        reports.each do |attr_report|
          data = attr_report.attribute_data
          next unless data
          path = data.path
          next unless path.cluster == cluster_id
          next unless path.attribute == attribute_id

          list = data.data.value.as?(Array(TLV::Any)) || return
          return list.map { |entry| Matter::Cluster::LabelStruct.from_tlv(entry) }
        end

        nil
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
    end
  end
end
