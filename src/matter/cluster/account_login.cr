require "digest/sha256"
require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Account Login (0x050E), revision 2. Account matching and
    # credential validation belong to the application host.
    class AccountLogin < Base
      cluster 0x050E, revision: 2, persist_state: false

      MAX_TEMP_IDENTIFIER_LENGTH = 100
      MIN_TEMP_IDENTIFIER_LENGTH =  16
      MIN_SETUP_PIN_LENGTH       =   8
      MAX_UNIQUE_REQUESTS        =  10
      REQUEST_WINDOW             = 10.minutes

      abstract class Host
        # Return nil when the temporary identifier does not match the current
        # account. The host expires identifiers within ten minutes and owns
        # PIN secrecy.
        abstract def setup_pin(identifier : String, fabric_index : UInt8) : String?

        abstract def login(identifier : String, pin : String, node : UInt64?, fabric_index : UInt8) : Bool

        abstract def logout(node : UInt64?, fabric_index : UInt8) : Bool
      end

      struct GetSetupPinRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter temp_account_identifier : String

        def initialize(@temp_account_identifier : String)
        end
      end

      struct GetSetupPinResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter setup_pin : String

        def initialize(@setup_pin : String)
        end
      end

      struct LoginRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter temp_account_identifier : String

        @[TLV::Field(tag: 1)]
        getter setup_pin : String

        @[TLV::Field(tag: 2, optional: true)]
        getter node : UInt64?

        def initialize(@temp_account_identifier : String, @setup_pin : String, @node : UInt64? = nil)
        end
      end

      struct LogoutRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter node : UInt64?

        def initialize(@node : UInt64? = nil)
        end
      end

      struct LoggedOutEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter node : UInt64?

        def initialize(@node : UInt64? = nil)
        end
      end

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter attempts : Hash(String, Time)

        def initialize(@data_version : UInt32, @attempts : Hash(String, Time))
        end
      end

      command 0x00, :get_setup_pin, request: GetSetupPinRequest,
        response: GetSetupPinResponse, response_id: 0x01, access: :administer, timed: true
      command 0x02, :login, request: LoginRequest, access: :administer, timed: true
      command 0x03, :logout, request: LogoutRequest, access: :operate, timed: true

      event 0x00, :logged_out, priority: :critical, access: :administer, payload: LoggedOutEvent

      @attempts = {} of String => Time
      @rate_mutex = Mutex.new

      def initialize(endpoint_id : DataType::EndpointNumber, @host : Host,
                     @clock : Proc(Time) = -> { Time.utc })
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def get_setup_pin(request : GetSetupPinRequest) : GetSetupPinResponse | InteractionModel::Status
        fabric_index = command_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric_index
        validate_identifier!(request.temp_account_identifier)
        return InteractionModel::Status.failure unless allow_request?(CMD_GET_SETUP_PIN, fabric_index, request.temp_account_identifier)
        pin = @host.setup_pin(request.temp_account_identifier, fabric_index) || ""
        return InteractionModel::Status.failure unless pin.empty? || pin.size >= MIN_SETUP_PIN_LENGTH
        GetSetupPinResponse.new(pin)
      end

      def login(request : LoginRequest) : InteractionModel::Status
        fabric_index = command_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric_index
        validate_identifier!(request.temp_account_identifier)
        raise ArgumentError.new("SetupPIN must have at least 8 characters") if request.setup_pin.size < MIN_SETUP_PIN_LENGTH
        return InteractionModel::Status.failure unless allow_request?(CMD_LOGIN, fabric_index,
                                                         request.temp_account_identifier, request.setup_pin)
        return InteractionModel::Status.failure unless @host.login(request.temp_account_identifier,
                                                         request.setup_pin, request.node, fabric_index)
        InteractionModel::Status.success
      end

      def logout(request : LogoutRequest) : InteractionModel::Status
        fabric_index = command_fabric_index
        return InteractionModel::Status.unsupported_access unless fabric_index
        return InteractionModel::Status.failure unless @host.logout(request.node, fabric_index)
        notify_logged_out(request.node, fabric_index)
        InteractionModel::Status.success
      end

      # Hosts call this when a user logs out locally. The event is visible only
      # to administrators on the affected fabric.
      def notify_logged_out(node : UInt64?, fabric_index : UInt8) : Nil
        raise ArgumentError.new("fabric index must be nonzero") if fabric_index == DataType::NO_FABRIC
        emit_logged_out(LoggedOutEvent.new(node), fabric_index)
      end

      def save_state : Storage::Document?
        attempts = @rate_mutex.synchronize { @attempts.dup }
        PersistedState.new(@data_version, attempts).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        raise ArgumentError.new("too many Account Login attempts") if state.attempts.size > MAX_UNIQUE_REQUESTS
        now = @clock.call
        @rate_mutex.synchronize do
          @attempts = state.attempts.reject { |_key, timestamp| now - timestamp >= REQUEST_WINDOW }
        end
        @data_version = state.data_version
      end

      private def command_fabric_index : UInt8?
        return unless request_is_case_session?
        request_fabric_index
      end

      private def validate_identifier!(identifier : String) : Nil
        unless (MIN_TEMP_IDENTIFIER_LENGTH..MAX_TEMP_IDENTIFIER_LENGTH).includes?(identifier.size)
          raise ArgumentError.new("TempAccountIdentifier must be 16 to 100 characters")
        end
      end

      private def allow_request?(command_id : UInt32, fabric_index : UInt8,
                                 identifier : String, pin : String? = nil) : Bool
        material = "#{command_id}:#{fabric_index}:#{identifier.bytesize}:#{identifier}:#{pin}"
        key = Digest::SHA256.hexdigest(material)
        now = @clock.call
        added = false
        allowed = @rate_mutex.synchronize do
          @attempts.reject! { |_digest, timestamp| now - timestamp >= REQUEST_WINDOW }
          if @attempts.has_key?(key)
            true
          elsif @attempts.size < MAX_UNIQUE_REQUESTS
            @attempts[key] = now
            added = true
            true
          else
            false
          end
        end
        increment_version if added
        allowed
      end
    end
  end
end
