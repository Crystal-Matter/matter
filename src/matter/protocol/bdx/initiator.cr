require "log"
require "../../session/context"
require "./transfer"
require "../response_sender"

module Matter
  module Protocol
    module Bdx
      # Starts sender-driven BDX uploads for device-initiated transfers such as
      # DiagnosticLogs. All methods run under the SessionRegistry lock.
      class Initiator
        Log = ::Log.for("matter.protocol.bdx.initiator")
        # The Diagnostic Logs server handles one log collection at a time.
        MAX_TRANSFERS = 1
        MAX_BYTES     = 64 * 1024 * 1024
        BLOCK_SIZE    = 1024_u16
        IDLE_TIMEOUT  = 5.minutes

        private record Key, session_id : UInt16, exchange_id : UInt16
        private record Pending, session : Session::SecureContext, peer : Socket::IPAddress,
          designator : Bytes, content : Bytes

        private class Active
          getter session : Session::SecureContext
          getter peer : Socket::IPAddress
          getter content : Bytes
          getter io : IO::Memory
          property transfer : Transfer?
          property touched_at : Time::Instant

          def initialize(@session : Session::SecureContext, @peer : Socket::IPAddress,
                         @content : Bytes)
            @io = IO::Memory.new(@content)
            @transfer = nil
            @touched_at = Time.instant
          end
        end

        @pending = [] of Pending
        @active = {} of Key => Active

        def initialize(@sender : ResponseSender)
        end

        def queue(session : Session::SecureContext, peer : Socket::IPAddress,
                  designator : Bytes, content : Bytes) : Bool
          return false unless session.case_session? && session.fabric_index && session.peer_node_id
          return false if designator.empty? || designator.size > UInt16::MAX ||
                          content.empty? || content.size > MAX_BYTES
          return false if busy?
          @pending << Pending.new(session, peer, designator.dup, content.dup)
          true
        end

        def busy? : Bool
          @pending.size + @active.size >= MAX_TRANSFERS
        end

        def pending_for?(session : Session::SecureContext) : Bool
          @pending.any?(&.session.same?(session))
        end

        # Starts the log collection tied to a deferred IM InvokeResponse.
        def start_pending_for(session : Session::SecureContext) : UInt16?
          index = @pending.index(&.session.same?(session))
          return unless index
          start_transfer(@pending.delete_at(index))
        end

        # Directly queued transfers have no InvokeResponse to defer.
        def start_pending : Nil
          while pending = @pending.shift?
            start_transfer(pending)
          end
        end

        def discard_pending : Nil
          @pending.clear
        end

        def handles?(session_id : UInt16, exchange_id : UInt16) : Bool
          @active.has_key?(Key.new(session_id, exchange_id))
        end

        def receive(session : Session::SecureContext, exchange_id : UInt16,
                    opcode : Wire::Opcode, payload : Bytes,
                    initiator_message : Bool) : Tuple(Transfer::StatusCode?, Transfer::Message?)
          key = Key.new(session.session_id, exchange_id)
          active = @active[key]? || return {nil, nil}
          if !active.session.same?(session) || initiator_message
            finish(key)
            return {Transfer::StatusCode::UnexpectedMessage, nil}
          end
          active.touched_at = Time.instant
          if transfer = active.transfer
            unless opcode.block_ack? || opcode.block_ack_eof? || opcode.block_query? || opcode.block_query_with_skip?
              raise Transfer::Error.new(Transfer::StatusCode::UnexpectedMessage, "Expected BDX counter")
            end
            counter = Wire::BlockCounterMessage.decode(opcode, payload)
            next_message = transfer.receive(counter)
            finish(key) if transfer.complete?
            {nil, next_message}
          else
            raise Transfer::Error.new(Transfer::StatusCode::UnexpectedMessage, "Expected SendAccept") unless opcode.send_accept?
            accepted = Wire::Accept.decode(opcode, payload)
            control = accepted.transfer_control
            if control.async? || !(control.sender_drive? || control.receiver_drive?) ||
               accepted.max_block_size == 0 || accepted.max_block_size > BLOCK_SIZE
              raise Transfer::Error.new(Transfer::StatusCode::TransferMethodNotSupported, "Unsupported BDX drive")
            end
            drive = control.sender_drive? ? Transfer::Drive::Sender : Transfer::Drive::Receiver
            transfer = Transfer.sender(active.io, accepted.max_block_size, drive,
              active.content.size.to_u64)
            active.transfer = transfer
            {nil, transfer.start}
          end
        rescue ex : Transfer::Error | Matter::CodecError
          Log.warn(exception: ex) { "Outbound BDX transfer failed" }
          finish(Key.new(session.session_id, exchange_id))
          status = ex.is_a?(Transfer::Error) ? ex.status : Transfer::StatusCode::BadMessageContents
          {status, nil}
        end

        def abort(session_id : UInt16, exchange_id : UInt16) : Nil
          finish(Key.new(session_id, exchange_id))
        end

        def forget_session(session_id : UInt16) : Nil
          @pending.reject! { |pending| pending.session.session_id == session_id }
          @active.keys.select { |key| key.session_id == session_id }.each { |key| finish(key) }
        end

        def sweep(now : Time::Instant = Time.instant) : Nil
          @active.keys.select { |key| now - @active[key].touched_at >= IDLE_TIMEOUT }
            .each { |key| finish(key) }
        end

        def close : Nil
          @pending.clear
          @active.keys.each { |key| finish(key) }
        end

        private def finish(key : Key) : Nil
          @active.delete(key).try(&.io.close)
        end

        private def start_transfer(pending : Pending) : UInt16
          exchange_id = allocate_exchange(pending.session.session_id)
          key = Key.new(pending.session.session_id, exchange_id)
          active = Active.new(pending.session, pending.peer, pending.content)
          @active[key] = active
          init = Wire::Init.new(Wire::Opcode::SendInit,
            Wire::TransferControl::SenderDrive | Wire::TransferControl::ReceiverDrive,
            BLOCK_SIZE, pending.designator, length: pending.content.size.to_u64)
          @sender.send_bdx_request(pending.session, pending.peer, exchange_id,
            init.opcode.value, init.to_slice)
          exchange_id
        rescue ex
          finish(key) if key
          raise ex
        end

        private def allocate_exchange(session_id : UInt16) : UInt16
          UInt16::MAX.times do
            exchange_id = @sender.next_exchange_id
            @sender.next_exchange_id = exchange_id &+ 1
            return exchange_id unless @active.has_key?(Key.new(session_id, exchange_id))
          end
          raise Matter::ProtocolError.new("No BDX exchange id available")
        end
      end
    end
  end
end
