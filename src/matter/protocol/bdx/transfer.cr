require "./wire"

module Matter
  module Protocol
    module Bdx
      # One synchronous BDX v0 stream after Init/Accept negotiation. A caller
      # transports each returned message on the same encrypted exchange.
      class Transfer
        enum Drive
          Sender
          Receiver
        end

        enum StatusCode : UInt16
          LengthMismatch     = 0x0014
          BadMessageContents = 0x0016
          BadBlockCounter    = 0x0017
          UnexpectedMessage  = 0x0018
        end

        class Error < Matter::Error
          getter status : StatusCode

          def initialize(@status : StatusCode, message : String)
            super(message)
          end
        end

        alias Message = Wire::BlockCounterMessage | Wire::BlockData

        getter drive : Drive
        getter block_size : UInt16
        getter length : UInt64?
        getter bytes_transferred : UInt64

        @source : IO?
        @sink : IO?
        @sender : Bool
        @counter : UInt32
        @last_sent : UInt32?
        @sent_eof : Bool
        @started : Bool
        @complete : Bool

        private def initialize(@sender : Bool, @drive : Drive, @block_size : UInt16,
                               @length : UInt64?, @source : IO?, @sink : IO?)
          raise Error.new(StatusCode::BadMessageContents, "BDX block size must be positive") if @block_size == 0
          @counter = 0_u32
          @last_sent = nil
          @sent_eof = false
          @started = false
          @complete = false
          @bytes_transferred = 0_u64
        end

        def self.sender(source : IO, block_size : UInt16, drive : Drive, length : UInt64? = nil) : self
          new(true, drive, block_size, length, source, nil)
        end

        def self.receiver(sink : IO, block_size : UInt16, drive : Drive, length : UInt64? = nil) : self
          new(false, drive, block_size, length, nil, sink)
        end

        def complete? : Bool
          @complete
        end

        def start : Message?
          raise Error.new(StatusCode::UnexpectedMessage, "BDX transfer already started") if @started
          @started = true
          if @sender
            return next_block if @drive.sender?
          elsif @drive.receiver?
            return Wire::BlockCounterMessage.new(Wire::Opcode::BlockQuery, @counter)
          end
          nil
        end

        def receive(message : Message) : Message?
          raise Error.new(StatusCode::UnexpectedMessage, "BDX transfer was not started") unless @started
          raise Error.new(StatusCode::UnexpectedMessage, "BDX transfer has ended") if @complete
          if @sender
            receive_as_sender(message)
          else
            receive_as_receiver(message)
          end
        end

        private def receive_as_sender(message : Message) : Message?
          raise Error.new(StatusCode::UnexpectedMessage, "Sender received a data block") if message.is_a?(Wire::BlockData)
          if @sent_eof
            expect_counter!(message.counter, @last_sent)
            require_opcode!(message.opcode, Wire::Opcode::BlockAckEOF)
            @complete = true
            return
          end

          if @drive.sender?
            require_opcode!(message.opcode, Wire::Opcode::BlockAck)
            expect_counter!(message.counter, @last_sent)
            @counter = @counter &+ 1_u32
            next_block
          else
            if message.opcode.block_ack?
              expect_counter!(message.counter, @last_sent)
              return
            end
            require_opcode!(message.opcode, Wire::Opcode::BlockQuery)
            expect_counter!(message.counter, @counter)
            result = next_block
            @counter = @counter &+ 1_u32
            result
          end
        end

        private def receive_as_receiver(message : Message) : Message?
          raise Error.new(StatusCode::UnexpectedMessage, "Receiver expected a data block") unless message.is_a?(Wire::BlockData)
          expect_counter!(message.counter, @counter)
          raise Error.new(StatusCode::BadMessageContents, "BDX block exceeds negotiated size") if message.data.size > @block_size
          new_total = @bytes_transferred + message.data.size.to_u64
          if limit = @length
            raise Error.new(StatusCode::LengthMismatch, "BDX transfer exceeds negotiated length") if new_total > limit
            if message.opcode.block_eof? && new_total != limit
              raise Error.new(StatusCode::LengthMismatch, "BDX transfer ended before negotiated length")
            end
          end
          sink = @sink || raise Error.new(StatusCode::UnexpectedMessage, "Receiver sink is missing")
          sink.write(message.data)
          @bytes_transferred = new_total
          if message.opcode.block_eof?
            @complete = true
            return Wire::BlockCounterMessage.new(Wire::Opcode::BlockAckEOF, @counter)
          end
          @counter = @counter &+ 1_u32
          opcode = @drive.sender? ? Wire::Opcode::BlockAck : Wire::Opcode::BlockQuery
          counter = @drive.sender? ? message.counter : @counter
          Wire::BlockCounterMessage.new(opcode, counter)
        end

        private def next_block : Wire::BlockData
          source = @source || raise Error.new(StatusCode::UnexpectedMessage, "Sender source is missing")
          buffer = Bytes.new(@block_size)
          count = source.read(buffer)
          data = buffer[0, count]
          new_total = @bytes_transferred + count.to_u64
          if limit = @length
            raise Error.new(StatusCode::LengthMismatch, "Source exceeds negotiated BDX length") if new_total > limit
            if count == 0 && new_total != limit
              raise Error.new(StatusCode::LengthMismatch, "Source ended before negotiated BDX length")
            end
          end
          @bytes_transferred = new_total
          eof = count == 0 || (@length == new_total && count < @block_size)
          @sent_eof = eof
          @last_sent = @counter
          Wire::BlockData.new(eof ? Wire::Opcode::BlockEOF : Wire::Opcode::Block, @counter, data)
        end

        private def expect_counter!(actual : UInt32, expected : UInt32?) : Nil
          raise Error.new(StatusCode::BadBlockCounter, "Unexpected BDX block counter") unless expected == actual
        end

        private def require_opcode!(actual : Wire::Opcode, expected : Wire::Opcode) : Nil
          raise Error.new(StatusCode::UnexpectedMessage, "Unexpected BDX message") unless actual == expected
        end
      end
    end
  end
end
