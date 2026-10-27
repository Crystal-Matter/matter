require "./cluster"

module Matter
  module Cluster
    # Diagnostic Logs Cluster (0x0032)
    #
    # Provides access to device logs for debugging and diagnostics.
    # Required by Apple Home for accessory compatibility.
    #
    # Matter Spec: Core 11.10
    class DiagnosticLogs < Base
      cluster 0x0032, revision: 1

      # Intent enum - type of log being requested
      enum Intent : UInt8
        EndUserSupport = 0 # Logs for end-user support
        NetworkDiag    = 1 # Network diagnostic logs
        CrashLogs      = 2 # Crash/fault logs
      end

      # Status enum - response status
      enum LogsStatus : UInt8
        Success   = 0 # Logs retrieved successfully
        Exhausted = 1 # No more logs available
        NoLogs    = 2 # No logs of requested type
        Busy      = 3 # Device is busy
        Denied    = 4 # Access denied
      end

      # Transfer Protocol enum
      enum TransferProtocol : UInt8
        ResponsePayload = 0 # Return logs in response
        BDX             = 1 # Use BDX protocol
      end

      # Request struct for RetrieveLogsRequest command
      struct RetrieveLogsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property intent : Intent

        @[TLV::Field(tag: 1)]
        property requested_protocol : TransferProtocol

        @[TLV::Field(tag: 2, optional: true)]
        property transfer_file_designator : String?

        def initialize(@intent : Intent, @requested_protocol : TransferProtocol = TransferProtocol::ResponsePayload, @transfer_file_designator : String? = nil)
        end
      end

      # Response struct for RetrieveLogsResponse
      struct RetrieveLogsResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property status : LogsStatus

        @[TLV::Field(tag: 1)]
        property log_content : Bytes

        def initialize(@status : LogsStatus, @log_content : Bytes)
        end
      end

      command 0x00, :retrieve_logs_request, request: RetrieveLogsRequest, response: RetrieveLogsResponse, response_id: 0x01

      # Number of recent entries returned for end-user support.
      END_USER_SUPPORT_ENTRIES = 20

      # Log buffer - stores recent log entries
      @log_buffer : Array(String)
      @max_log_entries : Int32

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @max_log_entries : Int32 = 100,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @log_buffer = [] of String
      end

      # Matter 1.6 caps LogContent at 1024 octets; the InvokeResponse envelope
      # remains below the Interaction Model's 1100-byte UDP payload budget.
      MAX_INLINE_LOG_BYTES      = 1024
      MAX_FILE_DESIGNATOR_BYTES =   32

      # Queues a sender-initiated BDX transfer after the InvokeResponse has
      # been emitted. The device runtime installs this callback.
      property on_bdx_transfer : Proc(UInt16, UInt8, UInt64, Socket::IPAddress, Bytes, Bytes, Bool)?

      def retrieve_logs_request(request : RetrieveLogsRequest) : RetrieveLogsResponse | InteractionModel::Status
        designator = request.transfer_file_designator
        if request.requested_protocol.bdx?
          return InteractionModel::Status.invalid_command unless designator
        end
        if designator && designator.bytesize > MAX_FILE_DESIGNATOR_BYTES
          return InteractionModel::Status.constraint_error
        end

        log_content = build_log_content(request.intent)
        return RetrieveLogsResponse.new(LogsStatus::NoLogs, Bytes.empty) if log_content.empty?

        content = log_content.to_slice
        if request.requested_protocol.bdx?
          bdx_designator = designator || return InteractionModel::Status.invalid_command
          if content.size > MAX_INLINE_LOG_BYTES
            callback = @on_bdx_transfer
            # A cluster used without a device BDX sender follows the
            # ResponsePayload behavior required by Core 11.11.5.1.2.
            return RetrieveLogsResponse.new(LogsStatus::Exhausted, inline_content(content)) unless callback
            session_id = request_session_id
            fabric_index = request_fabric_index
            peer_node_id = request_peer_node_id
            peer = request_peer_address
            if callback && request_is_case_session? && session_id && fabric_index && peer_node_id && peer &&
               callback.call(session_id.to_u16, fabric_index, peer_node_id, peer, bdx_designator.to_slice, content.dup)
              return RetrieveLogsResponse.new(LogsStatus::Success, Bytes.empty)
            end
            return RetrieveLogsResponse.new(LogsStatus::Exhausted, inline_content(content))
          end

          return RetrieveLogsResponse.new(LogsStatus::Exhausted, inline_content(content))
        end

        RetrieveLogsResponse.new(LogsStatus::Success, inline_content(content))
      end

      private def inline_content(content : Bytes) : Bytes
        content[0, Math.min(content.size, MAX_INLINE_LOG_BYTES)].dup
      end

      private def build_log_content(intent : Intent) : String
        case intent
        in Intent::EndUserSupport
          # Return recent log entries
          @log_buffer.last(END_USER_SUPPORT_ENTRIES).join("\n")
        in Intent::NetworkDiag
          # Return network-related info
          "Network diagnostics: Device operational"
        in Intent::CrashLogs
          # Return crash logs (none available)
          ""
        end
      end

      # Public API: Add a log entry
      def log(message : String)
        timestamp = Time.utc.to_s("%Y-%m-%d %H:%M:%S")
        @log_buffer << "[#{timestamp}] #{message}"

        # Trim buffer if too large
        if @log_buffer.size > @max_log_entries
          @log_buffer.shift(@log_buffer.size - @max_log_entries)
        end
      end

      # Public API: Clear logs
      def clear_logs
        @log_buffer.clear
      end
    end
  end
end
