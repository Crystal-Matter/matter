require "../crypto/crypto"
require "../datatype/*"
require "../storage/record"
require "../transport/message_counter"

module Matter
  module Session
    # Session types in Matter protocol
    enum SessionType
      # Unsecured session (commissioning only)
      Unsecured
      # Unicast secure session (CASE or PASE)
      Unicast
      # Group secure session (multicast)
      Group
    end

    # Session parameters used during session establishment
    struct SessionParameters
      property session_id : UInt16
      property peer_session_id : UInt16
      property session_timestamp : Time
      property session_idle_interval : UInt32
      property session_active_interval : UInt32
      property session_active_threshold : UInt16

      def initialize(
        @session_id : UInt16,
        @peer_session_id : UInt16,
        @session_timestamp : Time = Time.utc,
        @session_idle_interval : UInt32 = 4000_u32,    # 4 seconds
        @session_active_interval : UInt32 = 500_u32,   # 500ms
        @session_active_threshold : UInt16 = 4000_u16, # 4000 messages
      )
      end
    end

    # Secure session context holding encryption keys and state
    class SecureContext
      property session_id : UInt16
      property peer_session_id : UInt16
      property session_type : SessionType
      property peer_node_id : DataType::NodeId?
      property local_node_id : DataType::NodeId?
      # All authenticated Subject IDs for the peer (NodeId + any CATs).
      # Used for AccessControl evaluation (ACL subjects can be Node IDs or CATs).
      property peer_subject_ids : Array(UInt64) = [] of UInt64
      # The validated CASE peer intermediate certificate, when presented.
      property peer_icac : Bytes? = nil

      # Encryption keys
      property encryption_key : Bytes # i2r (initiator to responder) or encryption key
      property decryption_key : Bytes # r2i (responder to initiator) or decryption key
      property attestation_challenge : Bytes?

      # Message counters for replay protection
      @local_counter : Transport::MessageCounter
      @peer_counter : Transport::MessageCounter

      # Session metadata
      property creation_time : Time
      property last_activity_time : Time
      property? initiator : Bool

      # Session type and fabric association
      # case_session: true for CASE sessions, false for PASE sessions
      # fabric_index: the fabric index for CASE sessions (nil for PASE)
      property? case_session : Bool
      property fabric_index : UInt8?

      def initialize(
        @session_id : UInt16,
        @peer_session_id : UInt16,
        @session_type : SessionType,
        @encryption_key : Bytes,
        @decryption_key : Bytes,
        @initiator : Bool = true,
        @peer_node_id : DataType::NodeId? = nil,
        @local_node_id : DataType::NodeId? = nil,
        @attestation_challenge : Bytes? = nil,
        @case_session : Bool = false,
        @fabric_index : UInt8? = nil,
      )
        # Matter spec requires message counter to start at a random value
        # to prevent replay attacks across session resumptions
        @local_counter = Transport::MessageCounter.new(Random::Secure.rand(UInt32), rollover: false)
        @peer_counter = Transport::MessageCounter.new
        @creation_time = Time.utc
        @last_activity_time = Time.utc
      end

      def local_message_counter : UInt32
        @local_counter.counter
      end

      def local_message_counter=(value : UInt32)
        @local_counter.reset(value)
      end

      def peer_message_counter : UInt32?
        @peer_counter.max_received
      end

      def peer_message_counter=(value : UInt32?)
        @peer_counter.restore_received(value)
      end

      def next_message_counter : UInt32
        @local_counter.next
      end

      def check_peer_message_counter(received_counter : UInt32) : Transport::MessageCounter::CheckResult
        @peer_counter.peek(received_counter)
      end

      def accept_peer_message_counter(received_counter : UInt32) : Nil
        @peer_counter.mark_received(received_counter)
        update_activity
      end

      # Update activity timestamp
      def update_activity
        @last_activity_time = Time.utc
      end

      # Set activity time (for testing)
      def last_activity_time=(time : Time)
        @last_activity_time = time
      end

      # Check if session is expired based on idle time
      def expired?(idle_timeout : Time::Span = 5.minutes) : Bool
        Time.utc - @last_activity_time > idle_timeout
      end

      # The persisted form of a CASE session (`sessions/<session_id>`).
      struct SessionRecord
        include Storage::Record

        getter session_id : UInt16
        getter peer_session_id : UInt16
        getter session_type : SessionType
        getter encryption_key : Bytes
        getter decryption_key : Bytes
        getter attestation_challenge : Bytes?
        getter? initiator : Bool
        getter? case_session : Bool
        getter local_message_counter : UInt32
        getter peer_message_counter : UInt32?
        getter peer_node_id : UInt64?
        getter local_node_id : UInt64?
        getter fabric_index : UInt8?
        getter peer_subject_ids : Array(UInt64) = [] of UInt64
        getter peer_icac : Bytes? = nil
        getter created_at : Time
        getter last_activity_at : Time

        def initialize(
          @session_id : UInt16,
          @peer_session_id : UInt16,
          @session_type : SessionType,
          @encryption_key : Bytes,
          @decryption_key : Bytes,
          @attestation_challenge : Bytes?,
          @initiator : Bool,
          @case_session : Bool,
          @local_message_counter : UInt32,
          @peer_message_counter : UInt32?,
          @peer_node_id : UInt64?,
          @local_node_id : UInt64?,
          @fabric_index : UInt8?,
          @created_at : Time,
          @last_activity_at : Time,
          @peer_subject_ids : Array(UInt64) = [] of UInt64,
          @peer_icac : Bytes? = nil,
        )
        end
      end

      def to_record : SessionRecord
        SessionRecord.new(
          session_id: @session_id,
          peer_session_id: @peer_session_id,
          session_type: @session_type,
          encryption_key: @encryption_key,
          decryption_key: @decryption_key,
          attestation_challenge: @attestation_challenge,
          initiator: @initiator,
          case_session: @case_session,
          local_message_counter: local_message_counter,
          peer_message_counter: peer_message_counter,
          peer_node_id: @peer_node_id.try(&.id),
          local_node_id: @local_node_id.try(&.id),
          fabric_index: @fabric_index,
          created_at: @creation_time,
          last_activity_at: @last_activity_time,
          peer_subject_ids: @peer_subject_ids,
          peer_icac: @peer_icac
        )
      end

      def self.from_record(record : SessionRecord) : SecureContext
        context = new(
          session_id: record.session_id,
          peer_session_id: record.peer_session_id,
          session_type: record.session_type,
          encryption_key: record.encryption_key,
          decryption_key: record.decryption_key,
          initiator: record.initiator?,
          peer_node_id: record.peer_node_id.try { |id| DataType::NodeId.new(id) },
          local_node_id: record.local_node_id.try { |id| DataType::NodeId.new(id) },
          attestation_challenge: record.attestation_challenge,
          case_session: record.case_session?,
          fabric_index: record.fabric_index
        )
        context.local_message_counter = record.local_message_counter
        context.peer_message_counter = record.peer_message_counter
        context.creation_time = record.created_at
        context.last_activity_time = record.last_activity_at
        context.peer_subject_ids = record.peer_subject_ids.dup
        context.peer_icac = record.peer_icac.try(&.dup)
        context
      end
    end

    # Unsecured session context (used during commissioning)
    class UnsecuredContext
      property session_id : UInt16
      property session_type : SessionType
      property initiator_session_id : UInt16
      property creation_time : Time

      def initialize(@session_id : UInt16, @initiator_session_id : UInt16 = 0_u16)
        @session_type = SessionType::Unsecured
        @creation_time = Time.utc
      end
    end
  end
end
