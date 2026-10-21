require "log"

require "../interaction_model/paths"
require "../interaction_model/tlv_messages"
require "./client"

module Matter
  module Controller
    class ImClient
      Log = ::Log.for("matter.controller.im_client")

      MSG_STATUS_RESPONSE = 0x01_u8
      MSG_READ_REQUEST    = 0x02_u8
      MSG_REPORT_DATA     = 0x05_u8
      MSG_WRITE_REQUEST   = 0x06_u8
      MSG_WRITE_RESPONSE  = 0x07_u8
      MSG_INVOKE_REQUEST  = 0x08_u8
      MSG_INVOKE_RESPONSE = 0x09_u8
      MSG_TIMED_REQUEST   = 0x0A_u8

      DEFAULT_TIMED_REQUEST_TIMEOUT = 10.seconds
      MAX_TIMED_REQUEST_TIMEOUT_MS  = UInt16::MAX

      def initialize(@client : Client, @timeout : Time::Span = 10.seconds)
      end

      def read_attribute(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        attribute_id : UInt32,
        fabric_filtered : Bool = true,
      ) : InteractionModel::ReportDataMessage
        path = InteractionModel::AttributePath.new(
          endpoint: endpoint_id,
          cluster: cluster_id,
          attribute: attribute_id
        )

        request = InteractionModel::ReadRequestMessage.new(
          attribute_requests: [path],
          fabric_filtered: fabric_filtered,
          interaction_model_revision: 12_u8
        )

        payload = request.to_slice
        exchange_id = @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_READ_REQUEST,
          payload: payload,
          requires_ack: true
        )

        response = @client.wait_for(exchange_id, Client::PROTOCOL_INTERACTION_MODEL, MSG_REPORT_DATA, @timeout)
        raise Matter::TimeoutError.new("IM: timeout waiting for ReportData (exchange=#{exchange_id})") unless response

        InteractionModel::ReportDataMessage.from_slice(response.message.payload.to_slice)
      end

      def write_attribute(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        attribute_id : UInt32,
        value : Bytes,
        timed_request : Bool = false,
        suppress_response : Bool = false,
        timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
      ) : InteractionModel::WriteResponseMessage
        write_attributes(
          session: session,
          peer: peer,
          writes: [{endpoint_id, cluster_id, attribute_id, value}],
          timed_request: timed_request,
          suppress_response: suppress_response,
          timed_request_timeout: timed_request_timeout
        )
      end

      def write_attributes(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        writes : Array(Tuple(UInt16, UInt32, UInt32, Bytes)),
        timed_request : Bool = false,
        suppress_response : Bool = false,
        timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
      ) : InteractionModel::WriteResponseMessage
        write_ibs = writes.map do |endpoint_id, cluster_id, attribute_id, value|
          path = InteractionModel::AttributePath.new(
            endpoint: endpoint_id,
            cluster: cluster_id,
            attribute: attribute_id
          )

          InteractionModel::AttributeDataIB.new(
            path: path,
            data: TLV::Any.from_slice(value),
            data_version: nil
          )
        end

        request = InteractionModel::WriteRequestMessage.new(
          suppress_response: suppress_response,
          timed_request: timed_request,
          write_requests: write_ibs,
          more_chunked_messages: false,
          interaction_model_revision: 12_u8
        )

        exchange_id = begin_timed_request(session, peer, timed_request_timeout) if timed_request
        exchange_id = @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_WRITE_REQUEST,
          payload: request.to_slice,
          exchange_id: exchange_id || @client.next_exchange_id,
          requires_ack: true
        )

        response = if timed_request
                     @client.wait_for_any(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
                       [MSG_WRITE_RESPONSE, MSG_STATUS_RESPONSE], @timeout)
                   else
                     @client.wait_for(exchange_id, Client::PROTOCOL_INTERACTION_MODEL, MSG_WRITE_RESPONSE, @timeout)
                   end
        raise Matter::TimeoutError.new("IM: timeout waiting for WriteResponse (exchange=#{exchange_id})") unless response
        raise_follow_up_status!(response, "WriteRequest", exchange_id) if timed_request

        InteractionModel::WriteResponseMessage.from_slice(response.message.payload.to_slice)
      end

      def invoke(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        endpoint_id : UInt16,
        cluster_id : UInt32,
        command_id : UInt32,
        fields : Bytes = Bytes.empty,
        timed_request : Bool = false,
        timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
      ) : InteractionModel::InvokeResponseMessage
        path = InteractionModel::CommandPath.new(
          endpoint: endpoint_id,
          cluster: cluster_id,
          command: command_id
        )

        command_fields = fields.empty? ? nil : TLV::Any.from_slice(fields)
        command = InteractionModel::CommandDataIBTlv.new(command_path: path, command_fields: command_fields)

        request = InteractionModel::InvokeRequestMessage.new(
          invoke_requests: [command],
          suppress_response: false,
          timed_request: timed_request,
          interaction_model_revision: 12_u8
        )

        exchange_id = begin_timed_request(session, peer, timed_request_timeout) if timed_request
        exchange_id = @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_INVOKE_REQUEST,
          payload: request.to_slice,
          exchange_id: exchange_id || @client.next_exchange_id,
          requires_ack: true
        )

        response = if timed_request
                     @client.wait_for_any(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
                       [MSG_INVOKE_RESPONSE, MSG_STATUS_RESPONSE], @timeout)
                   else
                     @client.wait_for(exchange_id, Client::PROTOCOL_INTERACTION_MODEL, MSG_INVOKE_RESPONSE, @timeout)
                   end
        raise Matter::TimeoutError.new("IM: timeout waiting for InvokeResponse (exchange=#{exchange_id})") unless response
        raise_follow_up_status!(response, "InvokeRequest", exchange_id) if timed_request

        InteractionModel::InvokeResponseMessage.from_slice(response.message.payload.to_slice)
      end

      private def raise_follow_up_status!(response : Client::ReceivedMessage, operation : String,
                                          exchange_id : UInt16) : Nil
        return unless response.message.payload_header.message_type == MSG_STATUS_RESPONSE

        status = begin
          InteractionModel::StatusResponseMessage.from_slice(response.message.payload.to_slice).status
        rescue ex
          raise Matter::ProtocolError.new("IM: invalid #{operation} StatusResponse (exchange=#{exchange_id})", cause: ex)
        end
        code = InteractionModel::StatusCode.from_value?(status)
        if code == InteractionModel::StatusCode::Timeout
          raise Matter::TimeoutError.new("IM: timed #{operation} expired (exchange=#{exchange_id})")
        end
        raise Matter::ProtocolError.new("IM: timed #{operation} rejected with #{code || "0x#{status.to_s(16)}"} (exchange=#{exchange_id})")
      end

      private def begin_timed_request(session : Session::SecureContext, peer : Socket::IPAddress,
                                      window : Time::Span) : UInt16
        milliseconds = window.total_milliseconds.ceil.to_i64
        unless milliseconds.in?(1..MAX_TIMED_REQUEST_TIMEOUT_MS)
          raise Matter::ConfigurationError.new("TimedRequest window must be between 1 and #{MAX_TIMED_REQUEST_TIMEOUT_MS} milliseconds")
        end

        exchange_id = @client.next_exchange_id
        request = InteractionModel::TimedRequestMessage.new(milliseconds.to_u16)
        @client.send_encrypted_request(
          session: session,
          peer: peer,
          protocol_id: Client::PROTOCOL_INTERACTION_MODEL,
          message_type: MSG_TIMED_REQUEST,
          payload: request.to_slice,
          exchange_id: exchange_id,
          requires_ack: true
        )

        response = @client.wait_for(exchange_id, Client::PROTOCOL_INTERACTION_MODEL,
          MSG_STATUS_RESPONSE, {@timeout, window}.min)
        raise Matter::TimeoutError.new("IM: timeout waiting for TimedRequest StatusResponse (exchange=#{exchange_id})") unless response

        status = begin
          InteractionModel::StatusResponseMessage.from_slice(response.message.payload.to_slice).status
        rescue ex
          raise Matter::ProtocolError.new("IM: invalid TimedRequest StatusResponse (exchange=#{exchange_id})", cause: ex)
        end
        unless status == InteractionModel::StatusCode::Success.value
          label = InteractionModel::StatusCode.from_value?(status).try(&.to_s) || "0x#{status.to_s(16)}"
          raise Matter::ProtocolError.new("IM: TimedRequest rejected with #{label} (exchange=#{exchange_id})")
        end

        exchange_id
      end
    end
  end
end
