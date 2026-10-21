require "../message_type"
require "../../error"

module Matter
  module Protocol
    module Bdx
      # Binary BDX v0 messages. The opcode lives in the Matter payload header;
      # these structures encode only the BDX message body.
      module Wire
        enum Opcode : UInt8
          SendInit           = 0x01
          SendAccept         = 0x02
          ReceiveInit        = 0x04
          ReceiveAccept      = 0x05
          BlockQuery         = 0x10
          Block              = 0x11
          BlockEOF           = 0x12
          BlockAck           = 0x13
          BlockAckEOF        = 0x14
          BlockQueryWithSkip = 0x15
        end

        @[Flags]
        enum TransferControl : UInt8
          SenderDrive   = 0x10
          ReceiverDrive = 0x20
          Async         = 0x40
        end

        private LENGTH_PRESENT = 0x01_u8
        private OFFSET_PRESENT = 0x02_u8
        private WIDE_RANGE     = 0x10_u8
        private RANGE_MASK     = LENGTH_PRESENT | OFFSET_PRESENT | WIDE_RANGE
        private CONTROL_MASK   = 0x70_u8
        private VERSION_MASK   = 0x0f_u8

        def self.read_u16(io : IO::Memory) : UInt16
          io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        end

        def self.read_u32(io : IO::Memory) : UInt32
          io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        end

        def self.read_u64(io : IO::Memory) : UInt64
          io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        end

        def self.read_bytes(io : IO::Memory, length : Int) : Bytes
          raise Matter::CodecError.new("BDX field exceeds payload") if length < 0 || length > io.size - io.pos
          Bytes.new(length).tap { |buffer| io.read_fully(buffer) }
        end

        def self.remainder(io : IO::Memory) : Bytes
          read_bytes(io, io.size - io.pos)
        end

        def self.finished!(io : IO::Memory) : Nil
          raise Matter::CodecError.new("Trailing BDX payload bytes") unless io.pos == io.size
        end

        def self.valid_control!(control : UInt8, proposal : Bool) : Nil
          raise Matter::CodecError.new("Unsupported BDX version or transfer bits") unless (control & VERSION_MASK) == 0 && (control & ~CONTROL_MASK) == 0
          modes = control & (TransferControl::SenderDrive.value | TransferControl::ReceiverDrive.value)
          raise Matter::CodecError.new("BDX needs a synchronous drive mode") if modes == 0
          if !proposal && (modes == (TransferControl::SenderDrive.value | TransferControl::ReceiverDrive.value) ||
             (control & TransferControl::Async.value) != 0)
            raise Matter::CodecError.new("BDX responder must select one synchronous mode")
          end
        end

        def self.range_control(offset : UInt64?, length : UInt64?) : UInt8
          flags = 0_u8
          flags |= OFFSET_PRESENT if offset
          flags |= LENGTH_PRESENT if length
          if (offset && offset > UInt32::MAX) || (length && length > UInt32::MAX)
            flags |= WIDE_RANGE
          end
          flags
        end

        def self.write_range(io : IO::Memory, value : UInt64, wide : Bool) : Nil
          if wide
            io.write_bytes(value, IO::ByteFormat::LittleEndian)
          else
            io.write_bytes(value.to_u32, IO::ByteFormat::LittleEndian)
          end
        end

        def self.read_range(io : IO::Memory, wide : Bool) : UInt64
          wide ? read_u64(io) : read_u32(io).to_u64
        end

        struct Init
          getter opcode : Opcode
          getter transfer_control : TransferControl
          getter max_block_size : UInt16
          getter file_designator : Bytes
          getter start_offset : UInt64?
          getter length : UInt64?
          getter metadata : Bytes

          def initialize(@opcode : Opcode, @transfer_control : TransferControl, @max_block_size : UInt16,
                         @file_designator : Bytes, @start_offset : UInt64? = nil, @length : UInt64? = nil,
                         @metadata : Bytes = Bytes.empty)
            raise Matter::CodecError.new("Expected BDX Init opcode") unless @opcode.send_init? || @opcode.receive_init?
            Wire.valid_control!(@transfer_control.value, proposal: true)
            raise Matter::CodecError.new("Invalid BDX block size or designator") if @max_block_size == 0 ||
                                                                                    @file_designator.empty? || @file_designator.size > UInt16::MAX
          end

          def to_slice : Bytes
            io = IO::Memory.new
            io.write_byte(@transfer_control.value)
            flags = Wire.range_control(@start_offset, @length)
            io.write_byte(flags)
            io.write_bytes(@max_block_size, IO::ByteFormat::LittleEndian)
            wide = (flags & WIDE_RANGE) != 0
            offset = @start_offset
            length = @length
            Wire.write_range(io, offset, wide) if offset
            Wire.write_range(io, length, wide) if length
            io.write_bytes(@file_designator.size.to_u16, IO::ByteFormat::LittleEndian)
            io.write(@file_designator)
            io.write(@metadata)
            io.to_slice
          end

          def self.decode(opcode : Opcode, payload : Bytes) : self
            io = IO::Memory.new(payload)
            control = io.read_byte || raise Matter::CodecError.new("Truncated BDX Init")
            range = io.read_byte || raise Matter::CodecError.new("Truncated BDX Init")
            raise Matter::CodecError.new("Reserved BDX range bits") unless (range & ~RANGE_MASK) == 0
            max_block_size = Wire.read_u16(io)
            wide = (range & WIDE_RANGE) != 0
            offset = Wire.read_range(io, wide) if (range & OFFSET_PRESENT) != 0
            length = Wire.read_range(io, wide) if (range & LENGTH_PRESENT) != 0
            designator = Wire.read_bytes(io, Wire.read_u16(io).to_i)
            new(opcode, TransferControl.from_value(control), max_block_size, designator,
              offset, length, Wire.remainder(io))
          rescue IO::EOFError | ArgumentError
            raise Matter::CodecError.new("Malformed BDX Init")
          end

          def ==(other : self) : Bool
            @opcode == other.opcode && @transfer_control == other.transfer_control &&
              @max_block_size == other.max_block_size && @file_designator == other.file_designator &&
              @start_offset == other.start_offset && @length == other.length && @metadata == other.metadata
          end
        end

        struct Accept
          getter opcode : Opcode
          getter transfer_control : TransferControl
          getter max_block_size : UInt16
          getter length : UInt64?
          getter metadata : Bytes

          def initialize(@opcode : Opcode, @transfer_control : TransferControl, @max_block_size : UInt16,
                         @length : UInt64? = nil, @metadata : Bytes = Bytes.empty)
            raise Matter::CodecError.new("Expected BDX Accept opcode") unless @opcode.send_accept? || @opcode.receive_accept?
            Wire.valid_control!(@transfer_control.value, proposal: false)
            raise Matter::CodecError.new("Invalid BDX block size") if @max_block_size == 0
            raise Matter::CodecError.new("SendAccept has no length") if @opcode.send_accept? && @length
          end

          def to_slice : Bytes
            io = IO::Memory.new
            io.write_byte(@transfer_control.value)
            flags = Wire.range_control(nil, @length)
            if @opcode.receive_accept?
              io.write_byte(flags)
            end
            io.write_bytes(@max_block_size, IO::ByteFormat::LittleEndian)
            length = @length
            Wire.write_range(io, length, (flags & WIDE_RANGE) != 0) if @opcode.receive_accept? && length
            io.write(@metadata)
            io.to_slice
          end

          def self.decode(opcode : Opcode, payload : Bytes) : self
            io = IO::Memory.new(payload)
            control = io.read_byte || raise Matter::CodecError.new("Truncated BDX Accept")
            range = opcode.receive_accept? ? (io.read_byte || raise Matter::CodecError.new("Truncated BDX Accept")) : 0_u8
            raise Matter::CodecError.new("Reserved BDX range bits") unless (range & ~(LENGTH_PRESENT | WIDE_RANGE)) == 0
            block_size = Wire.read_u16(io)
            length = Wire.read_range(io, (range & WIDE_RANGE) != 0) if (range & LENGTH_PRESENT) != 0
            new(opcode, TransferControl.from_value(control), block_size, length, Wire.remainder(io))
          rescue IO::EOFError | ArgumentError
            raise Matter::CodecError.new("Malformed BDX Accept")
          end

          def ==(other : self) : Bool
            @opcode == other.opcode && @transfer_control == other.transfer_control &&
              @max_block_size == other.max_block_size && @length == other.length && @metadata == other.metadata
          end
        end

        struct BlockCounterMessage
          getter opcode : Opcode
          getter counter : UInt32
          getter bytes_to_skip : UInt64?

          def initialize(@opcode : Opcode, @counter : UInt32, @bytes_to_skip : UInt64? = nil)
            valid = @opcode.block_query? || @opcode.block_ack? || @opcode.block_ack_eof? || @opcode.block_query_with_skip?
            raise Matter::CodecError.new("Expected BDX counter opcode") unless valid
            raise Matter::CodecError.new("Invalid BDX skip field") unless @opcode.block_query_with_skip? == !@bytes_to_skip.nil?
          end

          def to_slice : Bytes
            io = IO::Memory.new
            io.write_bytes(@counter, IO::ByteFormat::LittleEndian)
            skip = @bytes_to_skip
            io.write_bytes(skip, IO::ByteFormat::LittleEndian) if skip
            io.to_slice
          end

          def self.decode(opcode : Opcode, payload : Bytes) : self
            io = IO::Memory.new(payload)
            counter = Wire.read_u32(io)
            skip = Wire.read_u64(io) if opcode.block_query_with_skip?
            Wire.finished!(io)
            new(opcode, counter, skip)
          rescue IO::EOFError
            raise Matter::CodecError.new("Malformed BDX counter")
          end

          def ==(other : self) : Bool
            @opcode == other.opcode && @counter == other.counter && @bytes_to_skip == other.bytes_to_skip
          end
        end

        struct BlockData
          getter opcode : Opcode
          getter counter : UInt32
          getter data : Bytes

          def initialize(@opcode : Opcode, @counter : UInt32, @data : Bytes)
            raise Matter::CodecError.new("Expected BDX Block opcode") unless @opcode.block? || @opcode.block_eof?
            raise Matter::CodecError.new("Non-final BDX block must contain data") if @opcode.block? && @data.empty?
          end

          def to_slice : Bytes
            io = IO::Memory.new
            io.write_bytes(@counter, IO::ByteFormat::LittleEndian)
            io.write(@data)
            io.to_slice
          end

          def self.decode(opcode : Opcode, payload : Bytes, max_block_size : Int) : self
            io = IO::Memory.new(payload)
            counter = Wire.read_u32(io)
            data = Wire.remainder(io)
            raise Matter::CodecError.new("BDX block exceeds negotiated size") if data.size > max_block_size
            new(opcode, counter, data)
          rescue IO::EOFError
            raise Matter::CodecError.new("Malformed BDX block")
          end

          def ==(other : self) : Bool
            @opcode == other.opcode && @counter == other.counter && @data == other.data
          end
        end
      end
    end
  end
end
