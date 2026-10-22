require "./cluster"
require "../commissioning/window_service"

module Matter
  module Cluster
    # Matter 1.6 Commissioner Control (0x0751). The host owns approval policy,
    # target-window creation and subsequent device attestation/commissioning.
    # No ordinary device includes this cluster by default.
    class CommissionerControl < Base
      cluster 0x0751, revision: 1

      FABRIC_SYNCHRONIZATION =   1_u32
      MAX_LABEL_BYTES        =      64
      MIN_RESPONSE_TIMEOUT   =  30_u16
      MAX_RESPONSE_TIMEOUT   = 120_u16
      MAX_TRACKED_APPROVALS  =      64

      record ApprovalRequest,
        fabric_index : UInt8,
        client_node_id : UInt64,
        request_id : UInt64,
        vendor_id : UInt16,
        product_id : UInt16,
        label : String?,
        generation : UInt64

      # Preparing the response must not wait for the target to enter its
      # commissioning window. The client opens that window only after it
      # receives the response; `commission` runs after the response is sent.
      record PreparedWindow,
        response : ReverseOpenCommissioningWindowResponse,
        commission : Proc(Nil)

      private record PendingCommission,
        approval : ApprovalRequest,
        session_identity : UInt64?,
        exchange_id : UInt16?,
        commission : Proc(Nil)

      struct RequestCommissioningApprovalRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property request_id : UInt64

        @[TLV::Field(tag: 1)]
        property vendor_id : UInt16

        @[TLV::Field(tag: 2)]
        property product_id : UInt16

        @[TLV::Field(tag: 3, optional: true)]
        property label : String?

        def initialize(@request_id : UInt64, @vendor_id : UInt16, @product_id : UInt16, @label : String? = nil)
        end
      end

      struct CommissionNodeRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property request_id : UInt64

        @[TLV::Field(tag: 1)]
        property response_timeout_seconds : UInt16

        def initialize(@request_id : UInt64, @response_timeout_seconds : UInt16 = MIN_RESPONSE_TIMEOUT)
        end
      end

      struct ReverseOpenCommissioningWindowResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property commissioning_timeout : UInt16

        @[TLV::Field(tag: 1)]
        property pake_passcode_verifier : Bytes

        @[TLV::Field(tag: 2)]
        property discriminator : UInt16

        @[TLV::Field(tag: 3)]
        property iterations : UInt32

        @[TLV::Field(tag: 4)]
        property salt : Bytes

        def initialize(@commissioning_timeout : UInt16, @pake_passcode_verifier : Bytes,
                       @discriminator : UInt16, @iterations : UInt32, @salt : Bytes)
        end
      end

      struct CommissioningRequestResultEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property request_id : UInt64

        @[TLV::Field(tag: 1)]
        property client_node_id : UInt64

        @[TLV::Field(tag: 2)]
        property status_code : InteractionModel::StatusCode

        @[TLV::Field(tag: 254)]
        property fabric_index : UInt8

        def initialize(@request_id : UInt64, @client_node_id : UInt64,
                       @status_code : InteractionModel::StatusCode, @fabric_index : UInt8)
        end
      end

      private class Approval
        getter request : ApprovalRequest
        property status : InteractionModel::StatusCode? = nil
        property? consumed : Bool = false
        property? preparing : Bool = false

        def initialize(@request : ApprovalRequest)
        end
      end

      attribute 0x0000, :supported_device_categories, UInt32, computed: true, read_access: :manage

      command 0x00, :request_commissioning_approval, request: RequestCommissioningApprovalRequest, access: :manage
      command 0x01, :commission_node, request: CommissionNodeRequest,
        response: ReverseOpenCommissioningWindowResponse, response_id: 0x02, access: :manage

      event 0x00, :commissioning_request_result, priority: :info, access: :manage,
        payload: CommissioningRequestResultEvent

      @approvals = {} of Tuple(UInt8, UInt64, UInt64) => Approval
      @approval_order = [] of Tuple(UInt8, UInt64, UInt64)
      @pending_commissions = [] of PendingCommission
      @next_approval_generation = 0_u64
      @approval_mutex = Mutex.new
      @on_approval_requested : Proc(ApprovalRequest, Nil)? = nil
      @on_prepare_window : Proc(ApprovalRequest, CommissionNodeRequest, PreparedWindow?)? = nil

      # Both callbacks must be supplied before FabricSynchronization is
      # advertised. The first promptly queues consent work and returns; the
      # host later calls resolve_approval asynchronously. The second
      # generates response parameters and a deferred commissioning task.
      # The task must commission only the approved VID/PID after attestation.
      def configure_host(
        approval_requested : Proc(ApprovalRequest, Nil),
        prepare_window : Proc(ApprovalRequest, CommissionNodeRequest, PreparedWindow?),
      ) : Nil
        @on_approval_requested = approval_requested
        @on_prepare_window = prepare_window
        increment_version_and_notify(ATTR_SUPPORTED_DEVICE_CATEGORIES)
      end

      def supported_device_categories : UInt32
        @on_approval_requested && @on_prepare_window ? FABRIC_SYNCHRONIZATION : 0_u32
      end

      def request_commissioning_approval(request : RequestCommissioningApprovalRequest) : InteractionModel::Status
        context = authenticated_context || return InteractionModel::Status.unsupported_access
        if (label = request.label) && label.bytesize > MAX_LABEL_BYTES
          return InteractionModel::Status.constraint_error
        end

        evicted = nil.as(Approval?)
        approval = @approval_mutex.synchronize do
          key = {context[0], context[1], request.request_id}
          if @approvals.has_key?(key)
            nil
          else
            if @approvals.size >= MAX_TRACKED_APPROVALS
              evicted = @approvals.delete(@approval_order.shift)
              if old = evicted
                @pending_commissions.reject! { |entry| entry.approval == old.request }
              end
            end
            @next_approval_generation += 1_u64
            current = ApprovalRequest.new(context[0], context[1], request.request_id,
              request.vendor_id, request.product_id, request.label, @next_approval_generation)
            @approvals[key] = Approval.new(current)
            @approval_order << key
            current
          end
        end
        return InteractionModel::Status.failure unless approval
        if old = evicted
          emit_result(old.request, InteractionModel::StatusCode::Failure) if old.status.nil?
        end

        if callback = @on_approval_requested
          begin
            callback.call(approval)
          rescue ex
            Log.error(exception: ex) { "Commissioner Control host approval callback failed" }
            resolve_approval(approval, InteractionModel::StatusCode::Failure)
          end
        else
          # A bare cluster accepts the well-formed request but never grants it.
          resolve_approval(approval, InteractionModel::StatusCode::Failure)
        end
        InteractionModel::Status.success
      end

      # The host's explicit decision produces the fabric-sensitive result
      # event. A repeated or unknown decision cannot silently alter approval.
      def resolve_approval(request : ApprovalRequest, status : InteractionModel::StatusCode) : Bool
        key = approval_key(request)
        resolved = @approval_mutex.synchronize do
          entry = @approvals[key]?
          if entry && entry.request == request && entry.status.nil? && !entry.consumed?
            entry.status = status
            true
          else
            false
          end
        end
        return false unless resolved

        emit_result(request, status)
        true
      end

      def commission_node(request : CommissionNodeRequest) : ReverseOpenCommissioningWindowResponse | InteractionModel::Status
        context = authenticated_context || return InteractionModel::Status.unsupported_access
        unless (MIN_RESPONSE_TIMEOUT..MAX_RESPONSE_TIMEOUT).includes?(request.response_timeout_seconds)
          return InteractionModel::Status.constraint_error
        end
        key = {context[0], context[1], request.request_id}
        approval = @approval_mutex.synchronize do
          entry = @approvals[key]?
          if entry && entry.status == InteractionModel::StatusCode::Success && !entry.consumed? && !entry.preparing?
            entry.preparing = true
            entry.request
          end
        end
        return InteractionModel::Status.failure unless approval
        begin
          callback = @on_prepare_window || return InteractionModel::Status.failure
          prepared = callback.call(approval, request) || return InteractionModel::Status.failure
          return InteractionModel::Status.constraint_error unless valid_window?(prepared.response)
          still_approved = @approval_mutex.synchronize do
            entry = @approvals[key]?
            if entry && entry.request == approval && entry.status == InteractionModel::StatusCode::Success && entry.preparing?
              entry.consumed = true
              @pending_commissions << PendingCommission.new(approval,
                request_session_identity, request_exchange_id, prepared.commission)
              true
            else
              false
            end
          end
          return InteractionModel::Status.failure unless still_approved
          prepared.response
        ensure
          @approval_mutex.synchronize do
            entry = @approvals[key]?
            entry.preparing = false if entry && entry.request == approval
          end
        end
      end

      # The protocol layer drains these only after handing InvokeResponse to
      # the transport. A failed send discards them, including their PIN-bearing
      # host closures, without starting commissioning.
      def take_pending_commissions(session_identity : UInt64? = nil, exchange_id : UInt16? = nil) : Array(Proc(Nil))
        @approval_mutex.synchronize do
          pending = @pending_commissions.select do |entry|
            entry.session_identity == session_identity && entry.exchange_id == exchange_id
          end
          @pending_commissions.reject! do |entry|
            entry.session_identity == session_identity && entry.exchange_id == exchange_id
          end
          pending.compact_map do |entry|
            approval = entry.approval
            current = @approvals[approval_key(approval)]?
            if current && current.request == approval
              # Fabric removal can race with a task already drained from the
              # queue but still waiting for the protocol lock to be released.
              -> do
                active = @approval_mutex.synchronize do
                  present = @approvals[approval_key(approval)]?
                  present && present.request == approval
                end
                entry.commission.call if active
                nil
              end
            end
          end
        end
      end

      def discard_pending_commissions(session_identity : UInt64? = nil, exchange_id : UInt16? = nil) : Nil
        @approval_mutex.synchronize do
          @pending_commissions.reject! do |entry|
            entry.session_identity == session_identity && entry.exchange_id == exchange_id
          end
        end
      end

      # The manufacturer decides how long an approval remains valid. Its host
      # may discard an approved or denied request when that interval elapses.
      def expire_approval(request : ApprovalRequest) : Bool
        @approval_mutex.synchronize do
          key = approval_key(request)
          entry = @approvals[key]?
          next false unless entry && entry.request == request
          @approvals.delete(key)
          @approval_order.delete(key)
          @pending_commissions.reject! { |pending| pending.approval == request }
          true
        end
      end

      # A removed fabric may never reuse old approval state.
      def remove_fabric(fabric_index : UInt8) : Nil
        @approval_mutex.synchronize do
          @approvals.reject! { |key, _| key[0] == fabric_index }
          @approval_order.reject! { |key| key[0] == fabric_index }
          @pending_commissions.reject! { |entry| entry.approval.fabric_index == fabric_index }
        end
      end

      private def emit_result(request : ApprovalRequest, status : InteractionModel::StatusCode) : Nil
        emit_event(EVENT_COMMISSIONING_REQUEST_RESULT,
          CommissioningRequestResultEvent.new(request.request_id, request.client_node_id,
            status, request.fabric_index), request.fabric_index)
      end

      private def authenticated_context : Tuple(UInt8, UInt64)?
        return unless request_is_case_session?
        fabric = request_fabric_index
        peer = request_peer_node_id
        {fabric, peer} if fabric && peer
      end

      private def approval_key(request : ApprovalRequest) : Tuple(UInt8, UInt64, UInt64)
        {request.fabric_index, request.client_node_id, request.request_id}
      end

      private def valid_window?(response : ReverseOpenCommissioningWindowResponse) : Bool
        response.commissioning_timeout >= Commissioning::WindowService::MINIMUM_COMMISSIONING_TIMEOUT &&
          response.pake_passcode_verifier.size == Commissioning::WindowService::PAKE_PASSCODE_VERIFIER_LENGTH &&
          response.discriminator <= 4095 &&
          (Commissioning::WindowService::PBKDF2_MIN_ITERATIONS..Commissioning::WindowService::PBKDF2_MAX_ITERATIONS).includes?(response.iterations) &&
          (Commissioning::WindowService::PAKE_SALT_MIN_LENGTH..Commissioning::WindowService::PAKE_SALT_MAX_LENGTH).includes?(response.salt.size)
      end
    end
  end
end
