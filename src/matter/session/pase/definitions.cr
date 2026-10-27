require "tlv"

module Matter
  module Session
    module Pase
      module Definitions
        VENDOR_PROTOCOL_ID_FIELD_MASK = 0xFFFF_u32
        PROTOCOL_ID_BITS              =         16

        # MRP (Message Reliability Protocol) parameters
        struct MrpParameters
          include TLV::Serializable

          # Idle retransmit timeout (optional, tag 1)
          @[TLV::Field(tag: 1, optional: true)]
          property idle_retransmit_timeout_ms : UInt32?

          # Active retransmit timeout (optional, tag 2)
          @[TLV::Field(tag: 2, optional: true)]
          property active_retransmit_timeout_ms : UInt32?

          def initialize(
            @idle_retransmit_timeout_ms = nil,
            @active_retransmit_timeout_ms = nil,
          )
          end
        end

        # PBKDF parameters nested structure (tag 4 in PbkdfParamResponse)
        struct PbkdfParametersTLV
          include TLV::Serializable

          # Iterations (tag 1)
          @[TLV::Field(tag: 1)]
          property iterations : UInt32

          # Salt (tag 2)
          @[TLV::Field(tag: 2)]
          property salt : Bytes

          def initialize(@iterations : UInt32, @salt : Bytes)
          end
        end

        # PBKDF Parameter Request message
        # Sent by commissioner to request PBKDF parameters from the device
        struct PbkdfParamRequest
          include TLV::Serializable

          INITIATOR_RANDOM_SIZE =    32
          DEFAULT_PASSCODE_ID   = 0_u16

          # Initiator random (mandatory on the wire, tag 1)
          @[TLV::Field(tag: 1, optional: true)]
          property initiator_random : Bytes?

          # Initiator session ID (mandatory on the wire, tag 2)
          @[TLV::Field(tag: 2, optional: true)]
          property initiator_session_id : UInt16?

          # Passcode ID (mandatory on the wire, tag 3)
          @[TLV::Field(tag: 3, optional: true)]
          property passcode_id : UInt16?

          # Has PBKDF parameters (mandatory on the wire, tag 4)
          @[TLV::Field(tag: 4, optional: true)]
          property has_pbkdf_parameters : Bool?

          # MRP parameters (optional, tag 5)
          @[TLV::Field(tag: 5, optional: true)]
          property mrp_parameters : MrpParameters?

          def initialize(
            @initiator_random = nil,
            @initiator_session_id = nil,
            @passcode_id = nil,
            @has_pbkdf_parameters = nil,
            @mrp_parameters = nil,
          )
          end

          def valid? : Bool
            random = @initiator_random
            !!random && random.size == INITIATOR_RANDOM_SIZE && !@initiator_session_id.nil? &&
              @passcode_id == DEFAULT_PASSCODE_ID && !@has_pbkdf_parameters.nil?
          end
        end

        # PBKDF Parameter Response message
        # Sent by device in response to PbkdfParamRequest
        struct PbkdfParamResponse
          include TLV::Serializable

          # Initiator random (echo from request, tag 1)
          @[TLV::Field(tag: 1)]
          property initiator_random : Bytes

          # Responder random (new 32-byte random, tag 2)
          @[TLV::Field(tag: 2)]
          property responder_random : Bytes

          # Responder session ID (tag 3)
          @[TLV::Field(tag: 3)]
          property responder_session_id : UInt16

          # PBKDF parameters (nested structure, optional, tag 4)
          @[TLV::Field(tag: 4, optional: true)]
          property pbkdf_parameters : PbkdfParametersTLV?

          # MRP parameters (optional, tag 5)
          @[TLV::Field(tag: 5, optional: true)]
          property mrp_parameters : MrpParameters?

          def initialize(
            @initiator_random : Bytes,
            @responder_random : Bytes,
            @responder_session_id : UInt16,
            @pbkdf_parameters : PbkdfParametersTLV? = nil,
            @mrp_parameters : MrpParameters? = nil,
          )
          end

          # Convenience constructor with iterations and salt directly
          def self.new(
            initiator_random : Bytes,
            responder_random : Bytes,
            responder_session_id : UInt16,
            iterations : UInt32,
            salt : Bytes,
          )
            new(
              initiator_random: initiator_random,
              responder_random: responder_random,
              responder_session_id: responder_session_id,
              pbkdf_parameters: PbkdfParametersTLV.new(iterations, salt),
            )
          end
        end

        # PASE Pake1 message
        # Sent by commissioner with their public key (pA)
        struct Pake1
          include TLV::Serializable

          # Commissioner's public key (X value, pA)
          @[TLV::Field(tag: 1)]
          property x : Bytes

          def initialize(@x : Bytes)
          end
        end

        # PASE Pake2 message
        # Sent by device with their public key (pB) and confirmation (cB)
        struct Pake2
          include TLV::Serializable

          # Device's public key (Y value, pB)
          @[TLV::Field(tag: 1)]
          property y : Bytes

          # Device's confirmation value (cB, h_bx)
          @[TLV::Field(tag: 2)]
          property verifier : Bytes

          def initialize(@y : Bytes, @verifier : Bytes)
          end
        end

        # PASE Pake3 message
        # Sent by commissioner with their confirmation (cA)
        struct Pake3
          include TLV::Serializable

          # Commissioner's confirmation value (cA, h_ay)
          @[TLV::Field(tag: 1)]
          property verifier : Bytes

          def initialize(@verifier : Bytes)
          end
        end

        # StatusReport message
        # Sent to indicate success or failure of a protocol operation
        # NOTE: StatusReport is NOT TLV encoded! It's raw binary format:
        #   2 bytes: generalStatus (UInt16)
        #   4 bytes: vendorProtocolId (UInt32) - lower 16 bits = protocol ID, upper 16 bits = vendor ID
        #   2 bytes: protocolStatus (UInt16)
        #   N bytes: protocolData (optional)
        struct StatusReport
          SECURE_CHANNEL_PROTOCOL_ID = 0_u16
          GENERAL_STATUS_SUCCESS     = 0_u16
          GENERAL_STATUS_FAILURE     = 1_u16
          PROTOCOL_STATUS_SUCCESS    = 0_u16
          CASE_NO_SHARED_ROOT        = 1_u16
          NO_VENDOR_ID               = 0_u16

          # General status code (SUCCESS = 0)
          property general_status : UInt16

          # Protocol ID (lower 16 bits of vendorProtocolId)
          property protocol_id : UInt16

          # Vendor ID (upper 16 bits of vendorProtocolId)
          property vendor_id : UInt16

          # Protocol-specific status code (SUCCESS = 0 for Secure Channel)
          property protocol_status : UInt16

          # Optional protocol-specific data
          property protocol_data : Bytes?

          def initialize(
            @general_status : UInt16 = GENERAL_STATUS_SUCCESS,
            @protocol_id : UInt16 = SECURE_CHANNEL_PROTOCOL_ID,
            @vendor_id : UInt16 = NO_VENDOR_ID,
            @protocol_status : UInt16 = PROTOCOL_STATUS_SUCCESS,
            @protocol_data : Bytes? = nil,
          )
          end

          # Decode from raw binary bytes (NOT TLV!)
          def self.from_bytes(data : Bytes) : StatusReport
            io = IO::Memory.new(data)

            # Read fields in little-endian format
            general_status = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)

            # Read vendorProtocolId (UInt32) and split into vendor_id and protocol_id
            vendor_protocol_id = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            protocol_id = (vendor_protocol_id & VENDOR_PROTOCOL_ID_FIELD_MASK).to_u16
            vendor_id = ((vendor_protocol_id >> PROTOCOL_ID_BITS) & VENDOR_PROTOCOL_ID_FIELD_MASK).to_u16

            protocol_status = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)

            # Read remaining bytes as optional protocol data
            protocol_data = if io.pos < data.size
                              remaining = data[io.pos..]
                              remaining.size > 0 ? remaining : nil
                            end

            StatusReport.new(
              general_status: general_status,
              protocol_id: protocol_id,
              vendor_id: vendor_id,
              protocol_status: protocol_status,
              protocol_data: protocol_data
            )
          end

          # Encode to raw binary bytes (NOT TLV!)
          def to_bytes : Bytes
            io = IO::Memory.new

            # Write fields in little-endian format
            io.write_bytes(@general_status, IO::ByteFormat::LittleEndian)

            # Combine vendor ID and protocol ID into vendorProtocolId (UInt32)
            vendor_protocol_id = (@vendor_id.to_u32 << 16) | @protocol_id.to_u32
            io.write_bytes(vendor_protocol_id, IO::ByteFormat::LittleEndian)

            io.write_bytes(@protocol_status, IO::ByteFormat::LittleEndian)

            # Write optional protocol data
            if data = @protocol_data
              io.write(data)
            end

            bytes = io.to_slice
            Log.trace { "StatusReport raw bytes: #{bytes.hexstring}" }
            bytes
          end
        end
      end
    end
  end
end
