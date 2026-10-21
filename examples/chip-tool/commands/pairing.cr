require "../registry"

module ChipTool
  module Commands
    module Pairing
      extend self

      def register : Nil
        Registry.register("pairing", "fabrics", "List installed controller fabric identities") do |ctx, _args|
          state = ctx.state_store.load
          state.fabrics.each do |fabric|
            selected = state.fabric.try { |active| active.fabric_id == fabric.fabric_id && active.root_public_key == fabric.root_public_key && active.controller_node_id == fabric.controller_node_id } ? "*" : " "
            puts "#{selected} fabric=0x#{fabric.fabric_id.to_s(16)} controller=0x#{fabric.controller_node_id.to_s(16)} root=#{fabric.root_public_key.hexstring}"
          end
          0
        end

        Registry.register("pairing", "code", "Commission over IP using manual pairing code") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          node_id_str = args.shift?
          manual_code = args.shift?

          unless node_id_str && manual_code
            STDERR.puts "Usage: pairing code <node-id> <manual-code> [--address <ip[:port]>] [--new-fabric] [--allow-test-attestation]"
            next 2
          end

          new_fabric = !!args.delete("--new-fabric")
          allow_test_attestation = !!args.delete("--allow-test-attestation")
          peer = nil.as(Socket::IPAddress?)
          if idx = args.index("--address")
            addr = args[idx + 1]?
            raise ArgumentError.new("missing value for --address") unless addr
            args.delete_at(idx)
            args.delete_at(idx)

            host, port = addr.includes?(':') ? addr.split(':', 2) : {addr, "5540"}
            peer = Socket::IPAddress.new(host, port.to_i)
          end

          if peer.nil?
            if addr = ENV["MATTER_PEER_ADDRESS"]?
              host, port = addr.includes?(':') ? addr.split(':', 2) : {addr, "5540"}
              peer = Socket::IPAddress.new(host, port.to_i)
            end
          end

          node_id = parse_u64(node_id_str) || raise ArgumentError.new("invalid node-id: #{node_id_str}")

          store = ctx.state_store
          state = store.load
          controller = Matter::Controller::Client.new(
            unsecured_source_node_id: state.commissioner_node_id,
            initial_unsecured_message_counter: state.unsecured_message_counter
          )
          verifier = if allow_test_attestation
                       Matter::Controller::DeviceAttestationVerifier.new(
                         Matter::Controller::AttestationTrustStore.matter_test_fixture)
                     end
          commissioner = Matter::Controller::Commissioning::Commissioner.new(store, controller,
            timeout: ctx.timeout, attestation_verifier: verifier)
          begin
            commissioner.pairing_code(node_id, manual_code, peer: peer, new_fabric: new_fabric)
          ensure
            latest = store.load
            latest.unsecured_message_counter = controller.transport.message_counter.counter
            store.save(latest)
            commissioner.close
          end

          puts "Commissioned node 0x#{node_id.to_s(16)}"
          0
        end

        Registry.register("pairing", "open-commissioning-window", "Open an Enhanced or Basic commissioning window") do |_ctx, _args|
          ctx = _ctx
          args = _args.dup

          node_id_str = args.shift?
          option_str = args.shift?
          window_timeout_str = args.shift?
          iteration_str = args.shift?
          discriminator_str = args.shift?

          unless node_id_str && option_str && window_timeout_str && iteration_str && discriminator_str
            STDERR.puts "Usage: pairing open-commissioning-window <node-id> <option> <window-timeout> <iteration> <discriminator>"
            next 2
          end

          node_id = parse_u64(node_id_str) || raise ArgumentError.new("invalid node-id: #{node_id_str}")
          option = option_str.to_i
          window_timeout = window_timeout_str.to_u16
          iterations = iteration_str.to_u32
          discriminator = discriminator_str.to_u16

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

            case option
            when 0
              request = Matter::Cluster::AdministratorCommissioning::OpenBasicCommissioningWindowRequest.new(window_timeout)
              resp = im.invoke(
                session: session,
                peer: peer,
                endpoint_id: 0_u16,
                cluster_id: Matter::Cluster::AdministratorCommissioning::CLUSTER_ID,
                command_id: Matter::Cluster::AdministratorCommissioning::CMD_OPEN_BASIC_COMMISSIONING_WINDOW,
                fields: request.to_slice
              )
              if status = resp.invoke_responses.first?.try(&.command_status).try(&.status)
                unless status.status == Matter::InteractionModel::StatusCode::Success.value
                  raise Matter::ClusterError.from_wire("OpenBasicCommissioningWindow failed (status=#{status.status})", status.status, status.cluster_status)
                end
              end
              puts "OpenBasicCommissioningWindow: OK"
              0
            when 1
              opener = Matter::Controller::Commissioning::CommissioningWindowOpener.new
              window = opener.open_enhanced(
                im: im,
                session: session,
                peer: peer,
                timeout_seconds: window_timeout,
                iterations: iterations,
                discriminator: discriminator
              )
              puts "Manual pairing code: [#{window.manual_pairing_code}]"
              puts "Discriminator: #{window.discriminator}"
              0
            else
              STDERR.puts "Unsupported option: #{option} (supported: 0=basic, 1=enhanced)"
              2
            end
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
    end
  end
end
