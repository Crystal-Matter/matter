require "log"
require "../../session/context"
require "./transfer"

module Matter
  module Protocol
    module Bdx
      # Application-owned stream dispatcher for inbound BDX exchanges. The
      # callbacks are the authorization boundary: an unregistered designator
      # cannot create a transfer, and both receive the authenticated CASE peer.
      # Shared transfer metadata is synchronized briefly. Each transfer owns
      # its stream lock, so different CASE sessions can perform application IO
      # independently without holding the session registry lock.
      class Responder
        Log                        = ::Log.for("matter.protocol.bdx.responder")
        MAX_ACTIVE_TRANSFERS       =        4
        MAX_BLOCK_SIZE             = 1024_u16
        MAX_TCP_BLOCK_SIZE         = Transfer::MAX_TCP_BLOCK_SIZE
        DEFAULT_MAX_TRANSFER_BYTES = 64_u64 * 1024 * 1024
        IDLE_TIMEOUT               = 5.minutes

        record Source, io : IO, length : UInt64?
        alias ResponseMessage = Wire::Accept | Transfer::Message

        struct Step
          getter message : ResponseMessage?
          getter follow_up : Transfer::Message?
          getter status : Transfer::StatusCode?

          def initialize(@message : ResponseMessage? = nil,
                         @status : Transfer::StatusCode? = nil,
                         @follow_up : Transfer::Message? = nil)
          end

          def ack_only? : Bool
            @message.nil? && @status.nil?
          end
        end

        # Return nil to reject an unknown or unauthorized designator. The
        # returned IO belongs to this transfer and is closed on completion.
        property on_download : Proc(Session::SecureContext, Wire::Init, Source?)?
        property on_upload : Proc(Session::SecureContext, Wire::Init, IO?)?
        property max_transfer_bytes : UInt64 = DEFAULT_MAX_TRANSFER_BYTES

        private record Key, session_id : UInt16, exchange_id : UInt16

        private class Active
          getter session : Session::SecureContext
          getter transfer : Transfer
          getter stream : IO
          getter max_bytes : UInt64
          property touched_at : Time::Instant
          getter io_lock : Mutex

          def initialize(@session : Session::SecureContext, @transfer : Transfer,
                         @stream : IO, @max_bytes : UInt64)
            @touched_at = Time.instant
            @io_lock = Mutex.new(:reentrant)
          end
        end

        private record Pending, session : Session::SecureContext, touched_at : Time::Instant

        @active = {} of Key => Active
        @pending = {} of Key => Pending
        @state_lock = Mutex.new

        def active_count : Int32
          @state_lock.synchronize { @active.size + @pending.size }
        end

        def active_for_session?(session : Session::SecureContext) : Bool
          @state_lock.synchronize do
            @active.values.any?(&.session.same?(session)) ||
              @pending.values.any?(&.session.same?(session))
          end
        end

        # Process one BDX message and return its protocol response. The caller
        # sends a BDX StatusReport for status, or a standalone ACK for an empty
        # step. Only authenticated CASE sessions may reach this method.
        def receive(session : Session::SecureContext, exchange_id : UInt16,
                    opcode : Wire::Opcode, payload : Bytes) : Step
          key = Key.new(session.session_id, exchange_id)
          return Step.new(status: Transfer::StatusCode::UnexpectedMessage) unless session.case_session? && session.fabric_index && session.peer_node_id

          if opcode.send_init? || opcode.receive_init?
            if rejection = reserve(key, session)
              return Step.new(status: rejection)
            end
            init = Wire::Init.decode(opcode, payload)
            step = accept(session, key, init)
            finish(key, session) if step.status
            step
          else
            active = @state_lock.synchronize { @active[key]? }
            return Step.new(status: Transfer::StatusCode::UnexpectedMessage) unless active && active.session.same?(session)
            active.io_lock.synchronize do
              return Step.new(status: Transfer::StatusCode::UnexpectedMessage) unless current_active?(key, active)
              @state_lock.synchronize { active.touched_at = Time.instant }
              message = decode_transfer(opcode, payload, active.transfer.block_size)
              result = active.transfer.receive(message)
              if active.transfer.bytes_transferred > active.max_bytes
                raise Transfer::Error.new(Transfer::StatusCode::LengthTooLarge,
                  "BDX transfer exceeds configured maximum")
              end
              finish(key, session) if active.transfer.complete?
              Step.new(message: result)
            end
          end
        rescue ex : Transfer::Error
          finish(Key.new(session.session_id, exchange_id), session)
          Step.new(status: ex.status)
        rescue ex : Matter::CodecError
          finish(Key.new(session.session_id, exchange_id), session)
          Log.debug(exception: ex) { "Malformed BDX message (exchange=#{exchange_id})" }
          Step.new(status: Transfer::StatusCode::BadMessageContents)
        rescue ex
          finish(Key.new(session.session_id, exchange_id), session)
          Log.warn(exception: ex) { "BDX transfer failed (exchange=#{exchange_id})" }
          Step.new(status: Transfer::StatusCode::TransferFailed)
        end

        # A BDX StatusReport from the initiator ends the exchange immediately.
        def abort(session_id : UInt16, exchange_id : UInt16) : Nil
          finish(Key.new(session_id, exchange_id))
        end

        def abort(session : Session::SecureContext, exchange_id : UInt16) : Nil
          finish(Key.new(session.session_id, exchange_id), session)
        end

        def forget_session(session_id : UInt16) : Nil
          keys = @state_lock.synchronize do
            (@active.keys + @pending.keys).select { |key| key.session_id == session_id }
          end
          keys.each { |key| finish(key) }
        end

        # Identity-aware cleanup cannot affect a newly established CASE
        # session that happens to reuse the retired session's numeric ID.
        def forget_session(session : Session::SecureContext) : Nil
          keys = @state_lock.synchronize do
            @active.select { |_key, active| active.session.same?(session) }.keys +
              @pending.select { |_key, pending| pending.session.same?(session) }.keys
          end
          keys.each { |key| finish(key, session) }
        end

        def sweep(now : Time::Instant = Time.instant) : Nil
          expired = @state_lock.synchronize do
            active_keys = @active.select { |_key, active| now - active.touched_at >= IDLE_TIMEOUT }.keys
            pending_keys = @pending.select { |_key, pending| now - pending.touched_at >= IDLE_TIMEOUT }.keys
            active_keys + pending_keys
          end
          expired.each { |key| finish_if_expired(key, now) }
        end

        def close : Nil
          keys = @state_lock.synchronize { @active.keys + @pending.keys }
          keys.each { |key| finish(key) }
        end

        private def reserve(key : Key, session : Session::SecureContext) : Transfer::StatusCode?
          @state_lock.synchronize do
            return Transfer::StatusCode::UnexpectedMessage if @active.has_key?(key) || @pending.has_key?(key)
            return Transfer::StatusCode::ResponderBusy if @active.size + @pending.size >= MAX_ACTIVE_TRANSFERS
            @pending[key] = Pending.new(session, Time.instant)
            nil
          end
        end

        private def activate(key : Key, session : Session::SecureContext, active : Active) : Bool
          @state_lock.synchronize do
            return false unless @pending[key]?.try(&.session.same?(session))
            @pending.delete(key)
            @active[key] = active
            true
          end
        end

        private def current_active?(key : Key, active : Active) : Bool
          @state_lock.synchronize { @active[key]?.same?(active) || false }
        end

        private def accept(session : Session::SecureContext, key : Key, init : Wire::Init) : Step
          if offset = init.start_offset
            return Step.new(status: Transfer::StatusCode::StartOffsetNotSupported) unless offset == 0
          end
          transport_limit = session.tcp_session? ? MAX_TCP_BLOCK_SIZE : MAX_BLOCK_SIZE
          size = {init.max_block_size, transport_limit}.min
          if requested = init.length
            return Step.new(status: Transfer::StatusCode::LengthTooLarge) if requested > @max_transfer_bytes
          end
          proposed = init.transfer_control
          drive = if proposed.sender_drive?
                    Transfer::Drive::Sender
                  elsif proposed.receiver_drive?
                    Transfer::Drive::Receiver
                  else
                    return Step.new(status: Transfer::StatusCode::TransferMethodNotSupported)
                  end
          selected = drive.sender? ? Wire::TransferControl::SenderDrive : Wire::TransferControl::ReceiverDrive
          if init.opcode.receive_init?
            requested_max = init.length
            requested_max = nil if requested_max == 0
            source = @on_download.try(&.call(session, init))
            return Step.new(status: Transfer::StatusCode::FileDesignatorUnknown) unless source
            if known = source.length
              exceeds_request = requested_max.try { |maximum| known > maximum } || false
              if known > @max_transfer_bytes || exceeds_request
                source.io.close
                return Step.new(status: Transfer::StatusCode::LengthTooLarge)
              end
            end
            length = source.length
            transfer = Transfer.sender(source.io, size, drive, length)
            active = Active.new(session, transfer, source.io, requested_max || @max_transfer_bytes)
            active.io_lock.synchronize do
              unless activate(key, session, active)
                source.io.close
                return Step.new(status: Transfer::StatusCode::UnexpectedMessage)
              end
              first = transfer.start
              Step.new(message: Wire::Accept.new(Wire::Opcode::ReceiveAccept,
                selected, size, length: length), follow_up: first)
            end
          else
            sink = @on_upload.try(&.call(session, init))
            return Step.new(status: Transfer::StatusCode::FileDesignatorUnknown) unless sink
            length = init.length
            length = nil if length == 0
            transfer = Transfer.receiver(sink, size, drive, length)
            active = Active.new(session, transfer, sink, @max_transfer_bytes)
            active.io_lock.synchronize do
              unless activate(key, session, active)
                sink.close
                return Step.new(status: Transfer::StatusCode::UnexpectedMessage)
              end
              first = transfer.start
              Step.new(message: Wire::Accept.new(Wire::Opcode::SendAccept,
                selected, size), follow_up: first)
            end
          end
        end

        private def decode_transfer(opcode : Wire::Opcode, payload : Bytes,
                                    block_size : UInt16) : Transfer::Message
          case opcode
          when .block?, .block_eof?
            Wire::BlockData.decode(opcode, payload, block_size)
          when .block_query?, .block_query_with_skip?, .block_ack?, .block_ack_eof?
            Wire::BlockCounterMessage.decode(opcode, payload)
          else
            raise Matter::CodecError.new("Unsupported BDX transfer opcode")
          end
        end

        private def finish(key : Key, session : Session::SecureContext? = nil) : Nil
          active = @state_lock.synchronize do
            if pending = @pending[key]?
              @pending.delete(key) if session.nil? || pending.session.same?(session)
            end
            current = @active[key]?
            if current && (session.nil? || current.session.same?(session))
              @active.delete(key)
            end
          end
          close_active(active)
        end

        private def finish_if_expired(key : Key, now : Time::Instant) : Nil
          active = @state_lock.synchronize do
            if pending = @pending[key]?
              @pending.delete(key) if now - pending.touched_at >= IDLE_TIMEOUT
            end
            current = @active[key]?
            if current && now - current.touched_at >= IDLE_TIMEOUT
              @active.delete(key)
            end
          end
          close_active(active)
        end

        private def close_active(active : Active?) : Nil
          active.try do |transfer|
            transfer.io_lock.synchronize { transfer.stream.close }
          end
        rescue ex
          # Closing a finished application stream must not replace the actual
          # transfer result or keep an exchange resident.
          Log.warn(exception: ex) { "Failed closing BDX transfer stream" }
        end
      end
    end
  end
end
