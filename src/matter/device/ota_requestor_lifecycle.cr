require "../../matter"
require "../controller/ota_requestor_client"
require "../storage"
require "log"

module Matter
  abstract class Device
    # Opt-in host integration for the OTA Requestor cluster. The host owns CASE
    # resolution, image storage, consent, and the platform installer. Nothing
    # starts a firmware update until this service is explicitly attached.
    class OtaRequestorLifecycle(C)
      Log = ::Log.for("matter.device.ota_requestor_lifecycle")

      COLLECTION = Storage::Collections::APP
      PENDING_ID = "ota_requestor_pending"

      record Peer, session : Session::SecureContext, address : Socket::IPAddress

      enum Result
        NoUpdate
        Delayed
        Installed
      end

      struct PendingNotification
        include Storage::Record

        getter fabric_index : UInt8
        getter fabric_identity : String
        getter provider_node_id : UInt64
        getter provider_endpoint : UInt16
        getter update_token : Bytes
        getter software_version : UInt32
        getter product_id : UInt16
        getter? provider_notified : Bool = false
        getter? event_published : Bool = false

        def initialize(@fabric_index, @fabric_identity, @provider_node_id,
                       @provider_endpoint, @update_token, @software_version,
                       @product_id, @provider_notified = false,
                       @event_published = false)
        end
      end

      record DeferredApply,
        fabric_index : UInt8,
        provider_node_id : UInt64,
        endpoint : UInt16,
        staged : Controller::OtaRequestorClient::StagedUpdate,
        sink : IO,
        next_action_at : Time::Instant,
        await_next_action : Bool

      getter cluster : Cluster::OtaRequestor
      @deferred_apply : DeferredApply? = nil

      def fabric_table : FabricTable
        @fabrics
      end

      def initialize(@cluster : Cluster::OtaRequestor, @client : C,
                     @storage : Storage::Backend,
                     @fabrics : FabricTable,
                     @resolve_peer : Proc(UInt8, UInt64, Peer?),
                     @new_sink : Proc(IO),
                     @install : Proc(IO, Protocol::OtaImage::Header, Nil),
                     @vendor_id : UInt16, @product_id : UInt16,
                     @running_version : Proc(UInt32))
        @busy_lock = Mutex.new
        @busy = false
        @closed = false
        @storage.open unless @storage.open?
        @fabrics.register_removal_guard { |fabric| remove_fabric(fabric.fabric_index) }
      end

      # The command handler only schedules work: CASE command processing must
      # not wait on a network download or hold a cluster lock during it.
      def attach : Nil
        raise Matter::ProtocolError.new("OTA lifecycle is closed") if @closed
        @cluster.update_possible = true
        @cluster.on_announce_provider = ->(fabric : UInt8, _sender : UInt64, request : Cluster::OtaRequestor::AnnounceProviderRequest) do
          spawn do
            process_provider(fabric, request.provider_node_id, request.endpoint)
          rescue ex
            Log.error(exception: ex) { "OTA announcement failed (fabric=#{fabric} provider=#{request.provider_node_id})" }
          end
          nil
        end
      end

      def process_default(fabric_index : UInt8) : Result
        provider = @cluster.providers_for_fabric(fabric_index).first?
        return Result::NoUpdate unless provider
        process_provider(fabric_index, provider.provider_node_id, provider.endpoint)
      end

      def process_provider(fabric_index : UInt8, provider_node_id : UInt64,
                           endpoint : UInt16) : Result
        enter_work
        begin
          return Result::Delayed if pending_notification || @deferred_apply
          peer = resolve(fabric_index, provider_node_id)
          sink = @new_sink.call
          begin
            staged = @client.query_and_download(peer.session, peer.address, endpoint,
              @vendor_id, @product_id, @running_version.call, sink)
            unless staged
              return @cluster.update_state.in?(
                Cluster::OtaRequestor::UpdateState::DelayedOnQuery,
                Cluster::OtaRequestor::UpdateState::DelayedOnUserConsent) ? Result::Delayed : Result::NoUpdate
            end

            approval = @client.request_apply(peer.session, peer.address, endpoint, staged)
            if approval.action.await_next_action? ||
               (approval.action.proceed? && approval.delayed_action_time > 0)
              @deferred_apply = DeferredApply.new(fabric_index, provider_node_id,
                endpoint, staged, sink,
                Time.instant + approval.delayed_action_time.to_i64.seconds,
                approval.action.await_next_action?)
              return Result::Delayed
            end
            return Result::NoUpdate unless approval.action.proceed?

            persist_and_install(fabric_index, provider_node_id, endpoint, staged, sink)
          ensure
            sink.close unless @deferred_apply.try(&.sink) == sink
          end
        ensure
          leave_work
        end
      end

      # Resume a staged ApplyUpdate response after its delay. AwaitNextAction
      # asks the provider again; delayed Proceed installs the same staged image.
      # The host calls this after `next_apply_at`; the sink stays open meanwhile.
      def resume_delayed_apply : Result
        enter_work
        begin
          deferred = @deferred_apply || return Result::NoUpdate
          return Result::Delayed if Time.instant < deferred.next_action_at
          peer = resolve(deferred.fabric_index, deferred.provider_node_id)
          if deferred.await_next_action
            approval = @client.request_apply(peer.session, peer.address,
              deferred.endpoint, deferred.staged)
            if approval.action.await_next_action? ||
               (approval.action.proceed? && approval.delayed_action_time > 0)
              @deferred_apply = DeferredApply.new(deferred.fabric_index,
                deferred.provider_node_id, deferred.endpoint, deferred.staged,
                deferred.sink, Time.instant + approval.delayed_action_time.to_i64.seconds,
                approval.action.await_next_action?)
              return Result::Delayed
            end
            unless approval.action.proceed?
              @deferred_apply = nil
              deferred.sink.close
              return Result::NoUpdate
            end
          end
          @deferred_apply = nil
          begin
            persist_and_install(deferred.fabric_index, deferred.provider_node_id,
              deferred.endpoint, deferred.staged, deferred.sink)
          ensure
            deferred.sink.close
          end
        ensure
          leave_work
        end
      end

      def next_apply_at : Time::Instant?
        @deferred_apply.try(&.next_action_at)
      end

      # Call on every startup after Basic Information reflects the installed
      # version. A failed CASE exchange leaves the journal for another attempt.
      def notify_if_applied : Bool
        enter_work
        begin
          pending = pending_notification
          return false unless pending
          return false unless @running_version.call == pending.software_version

          unless pending.provider_notified?
            peer = resolve(pending.fabric_index, pending.provider_node_id)
            @client.notify_applied(peer.session, peer.address, pending.provider_endpoint,
              pending.update_token, pending.software_version, pending.product_id,
              publish_result: false)
            pending = PendingNotification.new(pending.fabric_index, pending.fabric_identity,
              pending.provider_node_id, pending.provider_endpoint, pending.update_token,
              pending.software_version, pending.product_id, provider_notified: true)
            @storage.write(COLLECTION, PENDING_ID, pending.to_document)
          end
          unless pending.event_published?
            published = PendingNotification.new(pending.fabric_index, pending.fabric_identity,
              pending.provider_node_id, pending.provider_endpoint, pending.update_token,
              pending.software_version, pending.product_id,
              provider_notified: true, event_published: true)
            # EventJournal advances live state while publishing. Keep the
            # marker until publication succeeds, then persist it before
            # deleting the token. A failed marker write can replay the event;
            # it cannot lose the event or repeat the provider notification.
            @cluster.emit_version_applied(pending.software_version, pending.product_id)
            @cluster.transition_to(Cluster::OtaRequestor::UpdateState::Idle,
              Cluster::OtaRequestor::ChangeReason::Success)
            @storage.write(COLLECTION, PENDING_ID, published.to_document)
          end
          @storage.delete(COLLECTION, PENDING_ID)
          true
        ensure
          leave_work
        end
      end

      # Release an in-memory staged image on graceful shutdown. Delayed Apply
      # must be re-queried after process restart because the host owns its file.
      def close : Nil
        return if @closed
        enter_work
        begin
          @closed = true
          @cluster.on_announce_provider = nil
          @cluster.update_possible = false
          if deferred = @deferred_apply
            @deferred_apply = nil
            deferred.sink.close
          end
        ensure
          leave_work
        end
      end

      def pending_notification : PendingNotification?
        document = @storage.read(COLLECTION, PENDING_ID)
        return unless document
        pending = PendingNotification.from_document(document)
        if @fabrics.get_fabric(pending.fabric_index).try(&.storage_identity) != pending.fabric_identity
          @storage.delete(COLLECTION, PENDING_ID)
          return
        end
        pending
      end

      # Close an in-memory staged image before the fabric is removed. The
      # durable token stays until deletion succeeds: FabricTable invokes guards
      # before its own durable delete, which may fail and leave the fabric live.
      # `pending_notification` discards the token after actual removal/reuse.
      def remove_fabric(fabric_index : UInt8) : Nil
        enter_work(allow_closed: true)
        begin
          if (deferred = @deferred_apply) && deferred.fabric_index == fabric_index
            @deferred_apply = nil
            deferred.sink.close
          end
        ensure
          leave_work
        end
      end

      private def persist_and_install(fabric_index : UInt8, provider_node_id : UInt64,
                                      endpoint : UInt16,
                                      staged : Controller::OtaRequestorClient::StagedUpdate,
                                      sink : IO) : Result
        # A synchronous backend write is the reboot boundary: the token must
        # be durable before the installer can replace the process.
        identity = current_fabric_identity(fabric_index)
        pending = PendingNotification.new(fabric_index, identity, provider_node_id,
          endpoint, staged.update_token.dup, staged.header.software_version, @product_id)
        @storage.write(COLLECTION, PENDING_ID, pending.to_document)
        sink.seek(0)
        begin
          @install.call(sink, staged.header)
        rescue ex
          @storage.delete(COLLECTION, PENDING_ID)
          @cluster.transition_to(Cluster::OtaRequestor::UpdateState::Idle,
            Cluster::OtaRequestor::ChangeReason::Failure)
          raise ex
        end
        Result::Installed
      end

      private def resolve(fabric_index : UInt8, node_id : UInt64) : Peer
        current_fabric_identity(fabric_index)
        peer = @resolve_peer.call(fabric_index, node_id) ||
               raise Matter::SessionError.new("OTA provider could not be resolved on its fabric")
        session = peer.session
        unless session.case_session? && session.fabric_index == fabric_index &&
               session.peer_node_id.try(&.id) == node_id
          raise Matter::SessionError.new("OTA provider CASE peer differs from the selected fabric or node")
        end
        peer
      end

      private def current_fabric_identity(fabric_index : UInt8) : String
        fabric = @fabrics.get_fabric(fabric_index) ||
                 raise Matter::SessionError.new("OTA fabric is absent or changed")
        fabric.storage_identity
      end

      private def enter_work(allow_closed : Bool = false) : Nil
        @busy_lock.synchronize do
          raise Matter::ProtocolError.new("OTA lifecycle is closed") if @closed && !allow_closed
          raise Matter::ProtocolError.new("OTA update already in progress") if @busy
          @busy = true
        end
      end

      private def leave_work : Nil
        @busy_lock.synchronize { @busy = false }
      end
    end
  end
end
