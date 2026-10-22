require "../fabric_table"
require "../fabric"
require "../mdns/responder"
require "../mdns/responder_interface"
require "../mdns/service_type"
require "../protocol/session_registry"
require "../cluster/operational_credentials"

module Matter
  abstract class Device
    # Wires fabric lifecycle events (commissioning/operational transitions) to:
    # - mDNS advertisements
    # - protocol session/subscription cleanup
    # - OperationalCredentials trusted root restoration
    #
    # The device/application can still hook into these events, but does not need
    # to manually persist sessions/subscriptions or manage advertisement state.
    class LifecycleManager
      Log = ::Log.for("matter.device.lifecycle_manager")

      enum Mode
        Commissioning
        Operational
      end

      getter mode : Mode

      # Called for every fabric added.
      property on_fabric_added : Proc(Fabric, Nil)?

      # Called for every fabric removed.
      property on_fabric_removed : Proc(UInt8, Nil)?

      # Called when transitioning from 0 -> 1 fabrics.
      property on_commissioned : Proc(Fabric, Nil)?

      # Called when transitioning from 1 -> 0 fabrics.
      property on_decommissioned : Proc(Nil)?

      def initialize(
        @fabric_table : FabricTable,
        @registry : Protocol::SessionRegistry,
        @operational_credentials : Cluster::OperationalCredentials,
        @responder : MDNS::ResponderInterface,
        @commissioning_info : Proc(MDNS::CommissioningInfo),
        @port : Int32 = 5540,
        @operational_info_factory : Proc(Fabric, MDNS::OperationalInfo)? = nil,
        @fabric_session_cleanup_delay : Time::Span = 1.second,
      )
        @mode = @fabric_table.empty? ? Mode::Commissioning : Mode::Operational
        restore_root_certs
        install!
      end

      def commissioned? : Bool
        !@fabric_table.empty?
      end

      # Ensures mDNS advertisements match current commissioned state.
      def sync_advertisements : Nil
        if @fabric_table.empty?
          switch_to_commissioning
        else
          switch_to_operational
        end
      end

      # Installs cluster callbacks. Safe to call multiple times.
      def install! : Nil
        @operational_credentials.on_fabric_added = ->(fabric : Fabric) { handle_fabric_added(fabric) }
        @operational_credentials.on_fabric_removed = ->(fabric_index : UInt8) { handle_fabric_removed(fabric_index) }
        @operational_credentials.on_fabric_updated = ->(fabric : Fabric) { handle_fabric_updated(fabric) }
      end

      private def handle_fabric_added(fabric : Fabric) : Nil
        # Ensure trusted roots include the RCAC from the new fabric (if present)
        if root_cert = fabric.root_cert
          @operational_credentials.restore_root_cert(root_cert)
        end

        first_fabric = @fabric_table.size == 1
        if first_fabric
          @responder.stop_commissioning
          @mode = Mode::Operational
        end

        @responder.advertise_operational(operational_info_for(fabric), port: @port)

        if callback = @on_fabric_added
          callback.call(fabric)
        end

        if first_fabric
          if callback = @on_commissioned
            callback.call(fabric)
          end
        end
      end

      private def handle_fabric_removed(fabric_index : UInt8) : Nil
        # When a fabric is removed, a final encrypted exchange (InvokeResponse/ACK)
        # may still be in-flight on the fabric's CASE session. Cleaning up the
        # session immediately can cause us to fail decryption and make some
        # commissioners (notably iOS) abort.
        #
        # To avoid this, defer session deletion by a short grace period.
        retire_fabric_sessions(fabric_index)

        # Re-advertise remaining operational services (or switch back to commissioning).
        @responder.stop_operational_advertisement

        if callback = @on_fabric_removed
          callback.call(fabric_index)
        end

        if @fabric_table.empty?
          switch_to_commissioning
          if callback = @on_decommissioned
            callback.call
          end
        else
          switch_to_operational
        end
      end

      private def handle_fabric_updated(fabric : Fabric) : Nil
        # The old CASE session can finish its UpdateNOC response before it is
        # retired. Newly established sessions use the replacement identity.
        retire_fabric_sessions(fabric.fabric_index)
        @responder.stop_operational_advertisement
        switch_to_operational
      end

      private def retire_fabric_sessions(fabric_index : UInt8) : Nil
        session_ids = @registry.sessions
          .select { |_, session| session.fabric_index == fabric_index }
          .keys
        return if session_ids.empty?

        delay = @fabric_session_cleanup_delay
        if delay <= Time::Span.zero
          session_ids.each { |session_id| @registry.delete_session(session_id) }
        else
          Log.debug { "Deferring cleanup of #{session_ids.size} session(s) for fabric #{fabric_index} by #{delay.total_milliseconds}ms" }
          spawn do
            sleep delay
            session_ids.each { |session_id| @registry.delete_session(session_id) }
          end
        end
      end

      private def switch_to_commissioning : Nil
        @mode = Mode::Commissioning
        @responder.stop_operational_advertisement
        @responder.advertise_commissioning(@commissioning_info.call, port: @port)
      end

      private def switch_to_operational : Nil
        @mode = Mode::Operational
        @responder.stop_commissioning
        @fabric_table.all_fabrics.each do |fabric|
          @responder.advertise_operational(operational_info_for(fabric), port: @port)
        end
      end

      private def operational_info_for(fabric : Fabric) : MDNS::OperationalInfo
        if factory = @operational_info_factory
          factory.call(fabric)
        else
          MDNS::OperationalInfo.new(
            compressed_fabric_id: fabric.compressed_fabric_id,
            node_id: fabric.node_id,
            tcp_supported: false
          )
        end
      end

      private def restore_root_certs : Nil
        @fabric_table.all_fabrics.each do |fabric|
          if root_cert = fabric.root_cert
            @operational_credentials.restore_root_cert(root_cert)
          end
        end
      end
    end
  end
end
