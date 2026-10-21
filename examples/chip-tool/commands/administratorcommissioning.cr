require "../registry"

module ChipTool
  module Commands
    module AdministratorCommissioning
      extend self

      def register : Nil
        Registry.register("administratorcommissioning", "revoke-commissioning", "Revoke a commissioning window") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          node_id_str = args.shift?
          endpoint_str = args.shift?

          unless node_id_str && endpoint_str
            STDERR.puts "Usage: administratorcommissioning revoke-commissioning <node-id> <endpoint-id>"
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
            resp = im.invoke(
              session: session,
              peer: peer,
              endpoint_id: endpoint_id,
              cluster_id: Matter::Cluster::AdministratorCommissioning::CLUSTER_ID,
              command_id: Matter::Cluster::AdministratorCommissioning::CMD_REVOKE_COMMISSIONING,
              fields: Bytes.empty
            )

            if status = resp.invoke_responses.first?.try(&.command_status).try(&.status)
              unless status.status == Matter::InteractionModel::StatusCode::Success.value
                STDERR.puts "RevokeCommissioning failed (status=#{status.status})"
                next 1
              end
            end

            puts "RevokeCommissioning: OK"
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
    end
  end
end
