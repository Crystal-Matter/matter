require "../protocol/bdx/transfer"
require "../protocol/message_type"
require "../session/pase/definitions"
require "./client"

module Matter
  module Controller
    # Stream a named BDX file over one authenticated CASE exchange. Callers own
    # their IO objects; the client never buffers the complete file in memory.
    class BdxClient(T)
      DEFAULT_BLOCK_SIZE = 1024_u16
      # A peer may pace synchronous blocks for up to its five-minute idle
      # window; allow that interval for each response, including negotiation.
      DEFAULT_TIMEOUT    = 5.minutes
      MAX_DOWNLOAD_BYTES = 64_u64 * 1024 * 1024

      class RemoteError < Protocol::Bdx::Transfer::Error
      end

      def initialize(@client : T, @timeout : Time::Span = DEFAULT_TIMEOUT)
      end

      def download(session : Session::SecureContext, peer : Socket::IPAddress,
                   file_designator : Bytes, sink : IO,
                   max_bytes : UInt64 = MAX_DOWNLOAD_BYTES,
                   block_size : UInt16 = DEFAULT_BLOCK_SIZE) : UInt64
        validate_case!(session)
        validate_block_size!(block_size, session, peer)
        exchange = @client.next_exchange_id
        init = Protocol::Bdx::Wire::Init.new(Protocol::Bdx::Wire::Opcode::ReceiveInit,
          supported_drives,
          block_size, file_designator, length: max_bytes)
        send_bdx(session, peer, exchange, init.opcode, init.to_slice)
        reply = wait_reply(session, peer, exchange)
        accept = decode_accept(reply, Protocol::Bdx::Wire::Opcode::ReceiveAccept)
        unless synchronous_drive?(accept.transfer_control) &&
               accept.max_block_size <= block_size && accept.max_block_size > 0
          abort_transfer(Protocol::Bdx::Transfer::StatusCode::TransferMethodNotSupported)
        end
        if announced = accept.length
          abort_transfer(Protocol::Bdx::Transfer::StatusCode::LengthTooLarge) if announced > max_bytes
        end
        length = accept.length
        length = nil if length == 0
        transfer = Protocol::Bdx::Transfer.receiver(sink, accept.max_block_size,
          drive_for(accept.transfer_control), length)
        request = transfer.start
        loop do
          if request
            send_bdx(session, peer, exchange, request.opcode, request.to_slice)
          end
          reply = wait_reply(session, peer, exchange)
          block = decode_block(reply, accept.max_block_size)
          if transfer.bytes_transferred + block.data.size.to_u64 > max_bytes
            abort_transfer(Protocol::Bdx::Transfer::StatusCode::LengthTooLarge)
          end
          request = transfer.receive(block)
          if transfer.complete?
            final = request.as(Protocol::Bdx::Wire::BlockCounterMessage)
            send_bdx(session, peer, exchange, final.opcode, final.to_slice)
            return transfer.bytes_transferred
          end
        end
      rescue ex : RemoteError
        raise ex
      rescue ex : Protocol::Bdx::Transfer::Error
        send_status(session, peer, exchange, ex.status) if exchange
        raise ex
      rescue ex : Matter::CodecError
        send_status(session, peer, exchange, Protocol::Bdx::Transfer::StatusCode::BadMessageContents) if exchange
        raise ex
      end

      def upload(session : Session::SecureContext, peer : Socket::IPAddress,
                 file_designator : Bytes, source : IO, length : UInt64,
                 block_size : UInt16 = DEFAULT_BLOCK_SIZE) : UInt64
        validate_case!(session)
        validate_block_size!(block_size, session, peer)
        exchange = @client.next_exchange_id
        init = Protocol::Bdx::Wire::Init.new(Protocol::Bdx::Wire::Opcode::SendInit,
          supported_drives,
          block_size, file_designator, length: length)
        send_bdx(session, peer, exchange, init.opcode, init.to_slice)
        reply = wait_reply(session, peer, exchange)
        accept = decode_accept(reply, Protocol::Bdx::Wire::Opcode::SendAccept)
        unless synchronous_drive?(accept.transfer_control) &&
               accept.max_block_size <= block_size && accept.max_block_size > 0
          abort_transfer(Protocol::Bdx::Transfer::StatusCode::TransferMethodNotSupported)
        end
        transfer = Protocol::Bdx::Transfer.sender(source, accept.max_block_size,
          drive_for(accept.transfer_control), length)
        block = transfer.start
        loop do
          if outgoing = block
            send_bdx(session, peer, exchange, outgoing.opcode, outgoing.to_slice)
          end
          reply = wait_reply(session, peer, exchange)
          counter = decode_counter(reply)
          block = transfer.receive(counter)
          return transfer.bytes_transferred if transfer.complete?
        end
      rescue ex : RemoteError
        raise ex
      rescue ex : Protocol::Bdx::Transfer::Error
        send_status(session, peer, exchange, ex.status) if exchange
        raise ex
      rescue ex : Matter::CodecError
        send_status(session, peer, exchange, Protocol::Bdx::Transfer::StatusCode::BadMessageContents) if exchange
        raise ex
      end

      private def validate_case!(session : Session::SecureContext) : Nil
        unless session.case_session? && session.fabric_index && session.peer_node_id
          raise Matter::ProtocolError.new("BDX requires an authenticated CASE session")
        end
      end

      private def validate_block_size!(size : UInt16, session : Session::SecureContext,
                                       peer : Socket::IPAddress) : Nil
        raise Matter::ConfigurationError.new("BDX block size must be positive") if size == 0
        limit = if session.tcp_session? && session.accepts_peer?(peer)
                  Protocol::Bdx::Transfer::MAX_TCP_BLOCK_SIZE
                else
                  DEFAULT_BLOCK_SIZE
                end
        if size > limit
          raise Matter::ConfigurationError.new("BDX block size exceeds transport payload limit")
        end
      end

      private def supported_drives : Protocol::Bdx::Wire::TransferControl
        Protocol::Bdx::Wire::TransferControl::SenderDrive |
          Protocol::Bdx::Wire::TransferControl::ReceiverDrive
      end

      private def synchronous_drive?(control : Protocol::Bdx::Wire::TransferControl) : Bool
        !control.async? && (control.sender_drive? || control.receiver_drive?)
      end

      private def drive_for(control : Protocol::Bdx::Wire::TransferControl) : Protocol::Bdx::Transfer::Drive
        control.sender_drive? ? Protocol::Bdx::Transfer::Drive::Sender : Protocol::Bdx::Transfer::Drive::Receiver
      end

      private def send_bdx(session : Session::SecureContext, peer : Socket::IPAddress,
                           exchange : UInt16, opcode : Protocol::Bdx::Wire::Opcode,
                           payload : Bytes) : Nil
        @client.send_encrypted_request(session, peer, Protocol::ProtocolId::Bdx.value,
          opcode.value, payload, exchange_id: exchange)
      end

      private def wait_reply(session : Session::SecureContext, peer : Socket::IPAddress,
                             exchange : UInt16) : Client::ReceivedMessage
        types = Protocol::Bdx::Wire::Opcode.values.map { |type| {Protocol::ProtocolId::Bdx.value, type.value} }
        types << {Protocol::ProtocolId::SecureChannel.value,
                  Protocol::SecureChannelMessageType::StatusReport.value}
        rec = @client.wait_for_exchange_message(exchange, types, @timeout) ||
              raise Matter::TimeoutError.new("BDX exchange #{exchange} timed out")
        # The Client already authenticated this packet with the registered
        # secure session. A dual-stack UDP socket may spell the same peer as
        # IPv4 or IPv4-mapped IPv6, so the address is not an identity check.
        if rec.message.packet_header.session_id != session.session_id ||
           rec.message.payload_header.initiator_message?
          raise Matter::ProtocolError.new("BDX reply belongs to another peer or secure session")
        end
        header = rec.message.payload_header
        if header.protocol_id == Protocol::ProtocolId::SecureChannel.value
          report = Session::Pase::Definitions::StatusReport.from_bytes(rec.message.payload)
          unless report.protocol_id == Protocol::ProtocolId::Bdx.value && report.vendor_id == 0
            raise Matter::ProtocolError.new("Unexpected status report during BDX transfer")
          end
          code = Protocol::Bdx::Transfer::StatusCode.from_value?(report.protocol_status) ||
                 Protocol::Bdx::Transfer::StatusCode::Unknown
          raise RemoteError.new(code, "BDX peer rejected transfer")
        end
        rec
      end

      private def decode_accept(rec : Client::ReceivedMessage,
                                expected : Protocol::Bdx::Wire::Opcode) : Protocol::Bdx::Wire::Accept
        opcode = Protocol::Bdx::Wire::Opcode.from_value?(rec.message.payload_header.message_type)
        unless opcode == expected
          raise Matter::ProtocolError.new("Expected BDX #{expected}, got #{opcode}")
        end
        Protocol::Bdx::Wire::Accept.decode(expected, rec.message.payload)
      end

      private def decode_block(rec : Client::ReceivedMessage,
                               max_block_size : UInt16) : Protocol::Bdx::Wire::BlockData
        opcode = Protocol::Bdx::Wire::Opcode.from_value?(rec.message.payload_header.message_type)
        unless opcode && (opcode.block? || opcode.block_eof?)
          raise Matter::ProtocolError.new("Expected BDX Block or BlockEOF")
        end
        Protocol::Bdx::Wire::BlockData.decode(opcode, rec.message.payload, max_block_size)
      end

      private def decode_counter(rec : Client::ReceivedMessage) : Protocol::Bdx::Wire::BlockCounterMessage
        opcode = Protocol::Bdx::Wire::Opcode.from_value?(rec.message.payload_header.message_type)
        unless opcode && (opcode.block_ack? || opcode.block_ack_eof? ||
               opcode.block_query? || opcode.block_query_with_skip?)
          raise Matter::ProtocolError.new("Expected BDX BlockAck, BlockAckEOF, or BlockQuery")
        end
        Protocol::Bdx::Wire::BlockCounterMessage.decode(opcode, rec.message.payload)
      end

      private def abort_transfer(status : Protocol::Bdx::Transfer::StatusCode) : NoReturn
        raise Protocol::Bdx::Transfer::Error.new(status, "BDX transfer aborted")
      end

      private def send_status(session : Session::SecureContext, peer : Socket::IPAddress,
                              exchange : UInt16, status : Protocol::Bdx::Transfer::StatusCode) : Nil
        report = Session::Pase::Definitions::StatusReport.new(
          general_status: 1_u16, protocol_id: Protocol::ProtocolId::Bdx.value,
          protocol_status: status.value)
        @client.send_encrypted_request(session, peer, Protocol::ProtocolId::SecureChannel.value,
          Protocol::SecureChannelMessageType::StatusReport.value, report.to_bytes,
          exchange_id: exchange)
      end
    end
  end
end
