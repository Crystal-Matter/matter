require "log"
require "../../session/context"
require "./transfer"

module Matter
  module Protocol
    module Bdx
      # Application-owned stream dispatcher for inbound BDX exchanges. The
      # callbacks are the authorization boundary: an unregistered designator
      # cannot create a transfer, and both receive the authenticated CASE peer.
      # MessageHandler serializes calls to this responder separately from its
      # session registry. Application callbacks and stream IO may block.
      class Responder
        Log                        = ::Log.for("matter.protocol.bdx.responder")
        MAX_ACTIVE_TRANSFERS       =        4
        MAX_BLOCK_SIZE             = 1024_u16
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

          def initialize(@session : Session::SecureContext, @transfer : Transfer,
                         @stream : IO, @max_bytes : UInt64)
            @touched_at = Time.instant
          end
        end

        @active = {} of Key => Active

        def active_count : Int32
          @active.size
        end

        def active_for_session?(session : Session::SecureContext) : Bool
          @active.values.any?(&.session.same?(session))
        end

        # Process one BDX message and return its protocol response. The caller
        # sends a BDX StatusReport for status, or a standalone ACK for an empty
        # step. Only authenticated CASE sessions may reach this method.
        def receive(session : Session::SecureContext, exchange_id : UInt16,
                    opcode : Wire::Opcode, payload : Bytes) : Step
          key = Key.new(session.session_id, exchange_id)
          sweep
          return Step.new(status: Transfer::StatusCode::UnexpectedMessage) unless session.case_session? && session.fabric_index && session.peer_node_id

          if opcode.send_init? || opcode.receive_init?
            return Step.new(status: Transfer::StatusCode::UnexpectedMessage) if @active.has_key?(key)
            return Step.new(status: Transfer::StatusCode::ResponderBusy) if @active.size >= MAX_ACTIVE_TRANSFERS
            init = Wire::Init.decode(opcode, payload)
            accept(session, key, init)
          else
            active = @active[key]?
            return Step.new(status: Transfer::StatusCode::UnexpectedMessage) unless active && active.session.same?(session)
            active.touched_at = Time.instant
            message = decode_transfer(opcode, payload, active.transfer.block_size)
            result = active.transfer.receive(message)
            if active.transfer.bytes_transferred > active.max_bytes
              raise Transfer::Error.new(Transfer::StatusCode::LengthTooLarge,
                "BDX transfer exceeds configured maximum")
            end
            finish(key) if active.transfer.complete?
            Step.new(message: result)
          end
        rescue ex : Transfer::Error
          finish(Key.new(session.session_id, exchange_id))
          Step.new(status: ex.status)
        rescue ex : Matter::CodecError
          finish(Key.new(session.session_id, exchange_id))
          Log.debug(exception: ex) { "Malformed BDX message (exchange=#{exchange_id})" }
          Step.new(status: Transfer::StatusCode::BadMessageContents)
        rescue ex
          finish(Key.new(session.session_id, exchange_id))
          Log.warn(exception: ex) { "BDX transfer failed (exchange=#{exchange_id})" }
          Step.new(status: Transfer::StatusCode::TransferFailed)
        end

        # A BDX StatusReport from the initiator ends the exchange immediately.
        def abort(session_id : UInt16, exchange_id : UInt16) : Nil
          finish(Key.new(session_id, exchange_id))
        end

        def abort(session : Session::SecureContext, exchange_id : UInt16) : Nil
          key = Key.new(session.session_id, exchange_id)
          finish(key) if @active[key]?.try(&.session.same?(session))
        end

        def forget_session(session_id : UInt16) : Nil
          @active.keys.select { |key| key.session_id == session_id }.each { |key| finish(key) }
        end

        # Identity-aware cleanup cannot affect a newly established CASE
        # session that happens to reuse the retired session's numeric ID.
        def forget_session(session : Session::SecureContext) : Nil
          @active.select { |_key, active| active.session.same?(session) }
            .each_key { |key| finish(key) }
        end

        def sweep(now : Time::Instant = Time.instant) : Nil
          @active.keys.select { |key| now - @active[key].touched_at >= IDLE_TIMEOUT }
            .each { |key| finish(key) }
        end

        def close : Nil
          @active.keys.each { |key| finish(key) }
        end

        private def accept(session : Session::SecureContext, key : Key, init : Wire::Init) : Step
          if offset = init.start_offset
            return Step.new(status: Transfer::StatusCode::StartOffsetNotSupported) unless offset == 0
          end
          size = {init.max_block_size, MAX_BLOCK_SIZE}.min
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
            @active[key] = Active.new(session, transfer, source.io,
              requested_max || @max_transfer_bytes)
            first = transfer.start
            Step.new(message: Wire::Accept.new(Wire::Opcode::ReceiveAccept,
              selected, size, length: length), follow_up: first)
          else
            sink = @on_upload.try(&.call(session, init))
            return Step.new(status: Transfer::StatusCode::FileDesignatorUnknown) unless sink
            length = init.length
            length = nil if length == 0
            transfer = Transfer.receiver(sink, size, drive, length)
            @active[key] = Active.new(session, transfer, sink, @max_transfer_bytes)
            first = transfer.start
            Step.new(message: Wire::Accept.new(Wire::Opcode::SendAccept,
              selected, size), follow_up: first)
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

        private def finish(key : Key) : Nil
          if active = @active.delete(key)
            active.stream.close
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
