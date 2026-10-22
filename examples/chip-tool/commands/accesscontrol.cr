require "../registry"

module ChipTool
  module Commands
    module AccessControl
      extend self

      alias Entry = Matter::Cluster::AccessControl::AccessControlEntry
      alias Target = Matter::Cluster::AccessControl::Target

      def register : Nil
        Registry.register("accesscontrol", "read", "Read AccessControl cluster attributes") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          attribute = args.shift?
          node_id_str = args.shift?
          endpoint_str = args.shift?

          unless attribute && node_id_str && endpoint_str
            STDERR.puts "Usage: accesscontrol read acl <node-id> <endpoint-id>"
            next 2
          end

          cluster_id = Matter::Cluster::AccessControl::CLUSTER_ID
          attribute_id = case attribute
                         when "acl" then Matter::Cluster::AccessControl::ATTR_ACL
                         else
                           STDERR.puts "Unsupported attribute: #{attribute} (supported: acl)"
                           next 2
                         end

          node_id = parse_u64(node_id_str) || raise ArgumentError.new("invalid node-id: #{node_id_str}")
          endpoint_id = endpoint_str.to_u16

          store = ctx.state_store
          state = store.load
          fabric = state.fabric || raise Matter::CommissioningError.new("No controller fabric found; run `pairing code ...` first")

          peer = Matter::Controller::OperationalPeerResolver.new.resolve(state, fabric, node_id, ctx.timeout)

          controller = Matter::Controller::Client.new(
            unsecured_source_node_id: state.commissioner_node_id,
            initial_unsecured_message_counter: state.unsecured_message_counter
          )
          begin
            session = ctx.case_pairing.pair(controller, peer, fabric, peer_node_id: node_id, timeout: ctx.timeout)
            state.record_node(fabric.fabric_id, Matter::Controller::NodeInfo.new(node_id, Matter::Controller::OperationalPeerResolver.address_hint(peer), peer.port),
              fabric.root_public_key, fabric.controller_node_id)
            im = Matter::Controller::ImClient.new(controller, ctx.timeout)
            report = im.read_attribute(
              session: session,
              peer: peer,
              endpoint_id: endpoint_id,
              cluster_id: cluster_id,
              attribute_id: attribute_id
            )

            entries = extract_entries(report, cluster_id, attribute_id) || raise Matter::ProtocolError.new("ReportData missing ACL")
            puts "ACL: #{entries.size} entries"
            entries.each_with_index do |e, idx|
              puts "  [#{idx}]:"
              puts "    FabricIndex: #{e.fabric_index || 0}"
              puts "    Privilege: #{e.privilege.value}"
              puts "    AuthMode: #{e.auth_mode.value}"
              puts "    Subjects"
              if subjects = e.subjects
                subjects.each_with_index do |subj, i|
                  puts "      [#{i}]: 0x#{subj.to_s(16)}"
                end
              else
                puts "      null"
              end
              if targets = e.targets
                puts "    Targets"
                targets.each_with_index do |tgt, tgt_idx|
                  puts "      [#{tgt_idx}]: endpoint=#{tgt.endpoint || "null"} cluster=#{tgt.cluster || "null"} deviceType=#{tgt.device_type || "null"}"
                end
              end
            end
            0
          ensure
            state.unsecured_message_counter = controller.transport.message_counter.counter
            store.save(state)
            controller.close
          end
        end

        Registry.register("accesscontrol", "write", "Write AccessControl cluster attributes") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          attribute = args.shift?
          json = args.shift?
          node_id_str = args.shift?
          endpoint_str = args.shift?

          unless attribute && json && node_id_str && endpoint_str
            STDERR.puts "Usage: accesscontrol write acl '<json>' <node-id> <endpoint-id>"
            next 2
          end

          cluster_id = Matter::Cluster::AccessControl::CLUSTER_ID
          attribute_id = case attribute
                         when "acl" then Matter::Cluster::AccessControl::ATTR_ACL
                         else
                           STDERR.puts "Unsupported attribute: #{attribute} (supported: acl)"
                           next 2
                         end

          node_id = parse_u64(node_id_str) || raise ArgumentError.new("invalid node-id: #{node_id_str}")
          endpoint_id = endpoint_str.to_u16

          entries = Matter::Controller::Clusters::AccessControl.parse_acl_json(json)
          tlv = Matter::Controller::Clusters::AccessControl.encode_acl_tlv(entries)

          store = ctx.state_store
          state = store.load
          fabric = state.fabric || raise Matter::CommissioningError.new("No controller fabric found; run `pairing code ...` first")

          peer = Matter::Controller::OperationalPeerResolver.new.resolve(state, fabric, node_id, ctx.timeout)

          controller = Matter::Controller::Client.new(
            unsecured_source_node_id: state.commissioner_node_id,
            initial_unsecured_message_counter: state.unsecured_message_counter
          )
          begin
            session = ctx.case_pairing.pair(controller, peer, fabric, peer_node_id: node_id, timeout: ctx.timeout)
            state.record_node(fabric.fabric_id, Matter::Controller::NodeInfo.new(node_id, Matter::Controller::OperationalPeerResolver.address_hint(peer), peer.port),
              fabric.root_public_key, fabric.controller_node_id)
            im = Matter::Controller::ImClient.new(controller, ctx.timeout)
            resp = im.write_attribute(
              session: session,
              peer: peer,
              endpoint_id: endpoint_id,
              cluster_id: cluster_id,
              attribute_id: attribute_id,
              value: tlv,
              timed_request: false,
              suppress_response: false
            )

            status = resp.write_responses.first?.try(&.status)
            if status && status.status != Matter::InteractionModel::StatusCode::Success.value
              # Print in a way device_validation can treat as "denied" if needed.
              STDERR.puts "IM Error: status=#{status.status} cluster_status=#{status.cluster_status}"
              next 1
            end

            puts "ACL: OK"
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

      private def extract_entries(report : Matter::InteractionModel::ReportDataMessage, cluster_id : UInt32, attribute_id : UInt32) : Array(Entry)?
        reports = report.attribute_reports
        return unless reports

        reports.each do |attr_report|
          data = attr_report.attribute_data
          next unless data
          path = data.path
          next unless path.cluster == cluster_id
          next unless path.attribute == attribute_id

          any = data.data
          case v = any.value
          when Array(TLV::Any)
            entries = [] of Entry
            v.each do |elem|
              entries << Entry.from_slice(elem.to_slice)
            end
            return entries
          else
            return
          end
        end

        nil
      end
    end
  end
end
