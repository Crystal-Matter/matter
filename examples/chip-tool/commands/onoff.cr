require "../registry"

module ChipTool
  module Commands
    module OnOff
      extend self

      def register : Nil
        Registry.register("onoff", "read", "Read OnOff cluster attributes") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          attribute = args.shift?
          node_id_str = args.shift?
          endpoint_str = args.shift?

          unless attribute && node_id_str && endpoint_str
            STDERR.puts "Usage: onoff read on-off <node-id> <endpoint-id>"
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

            case attribute
            when "on-off"
              report = im.read_attribute(
                session: session,
                peer: peer,
                endpoint_id: endpoint_id,
                cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
                attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF
              )

              value = extract_report_bool(report)
              raise Matter::ProtocolError.new("ReportData missing OnOff value") if value.nil?
              puts "OnOff: #{value ? "TRUE" : "FALSE"}"
              0
            when "attribute-list"
              report = im.read_attribute(
                session: session,
                peer: peer,
                endpoint_id: endpoint_id,
                cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
                attribute_id: Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST
              )

              list = extract_report_u32_list(report, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST) || raise Matter::ProtocolError.new("ReportData missing AttributeList")
              puts "AttributeList: #{list.size} entries"
              list.each_with_index do |id, idx|
                puts "  [#{idx}]: #{id}"
              end
              0
            else
              STDERR.puts "Unsupported attribute: #{attribute} (supported: on-off, attribute-list)"
              2
            end
          ensure
            controller.close
          end
        end

        Registry.register("onoff", "on", "Send On command") do |_ctx, _args|
          run_command(_ctx, _args, Matter::Cluster::OnOff::CMD_ON, "On")
        end

        Registry.register("onoff", "off", "Send Off command") do |_ctx, _args|
          run_command(_ctx, _args, Matter::Cluster::OnOff::CMD_OFF, "Off")
        end

        Registry.register("onoff", "toggle", "Send Toggle command") do |_ctx, _args|
          run_command(_ctx, _args, Matter::Cluster::OnOff::CMD_TOGGLE, "Toggle")
        end
      end

      private def run_command(ctx : Context, argv : Array(String), command_id : UInt32, name : String) : Int32
        args = argv.dup
        node_id_str = args.shift?
        endpoint_str = args.shift?

        unless node_id_str && endpoint_str
          STDERR.puts "Usage: onoff #{name.downcase} <node-id> <endpoint-id>"
          return 2
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
          resp = im.invoke(
            session: session,
            peer: peer,
            endpoint_id: endpoint_id,
            cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
            command_id: command_id,
            fields: Bytes.empty
          )
          assert_invoke_ok!(resp, name)
          puts "#{name}: OK"
          0
        ensure
          controller.close
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

      private def extract_report_bool(report : Matter::InteractionModel::ReportDataMessage) : Bool?
        reports = report.attribute_reports
        return unless reports

        reports.each do |attr_report|
          data = attr_report.attribute_data
          next unless data
          path = data.path
          next unless path.cluster == Matter::Cluster::OnOff::CLUSTER_ID
          next unless path.attribute == Matter::Cluster::OnOff::ATTR_ON_OFF
          case value = data.data.value
          when Bool
            return value
          when Int
            return value != 0
          else
            return
          end
        end

        nil
      end

      private def extract_report_u32_list(report : Matter::InteractionModel::ReportDataMessage, cluster_id : UInt32, attribute_id : UInt32) : Array(UInt32)?
        reports = report.attribute_reports
        return unless reports

        reports.each do |attr_report|
          data = attr_report.attribute_data
          next unless data
          path = data.path
          next unless path.cluster == cluster_id
          next unless path.attribute == attribute_id

          list = data.data.value.as?(Array(TLV::Any)) || return

          values = [] of UInt32
          list.each_with_index do |elem, idx|
            break if idx >= 8192
            v = elem.value
            next unless v.is_a?(Int)
            next if v < 0
            u64 = v.to_u64
            next if u64 > UInt32::MAX
            values << u64.to_u32
          end

          return values
        end

        nil
      end

      private def assert_invoke_ok!(response : Matter::InteractionModel::InvokeResponseMessage, name : String) : Nil
        saw_any = false

        response.invoke_responses.each do |resp|
          if resp.command_data
            saw_any = true
            next
          end

          if status_ib = resp.command_status
            saw_any = true
            return if status_ib.status.status == Matter::InteractionModel::StatusCode::Success.value
            raise Matter::ClusterError.from_wire("#{name} failed (status=#{status_ib.status.status})", status_ib.status.status, status_ib.status.cluster_status)
          end
        end

        raise Matter::ProtocolError.new("#{name} failed (empty InvokeResponse)") unless saw_any
      end
    end
  end
end
