require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Matter 1.6 WebRTC Transport Requestor (0x0554). A host media engine
    # owns each session and handles signaling; this server validates and
    # dispatches Matter messages without inventing SDP or media streams.
    class WebrtcTransportRequestor < Base
      cluster 0x0554, revision: 2, persist_state: false

      MAX_SESSIONS         =         32
      MAX_ICE_SERVERS      =         10
      MAX_SERVER_URLS      =         10
      MAX_URL_BYTES        =       2000
      MAX_POLICY_BYTES     =         16
      MAX_USERNAME_BYTES   =        508
      MAX_CREDENTIAL_BYTES =        512
      MAX_STREAM_IDS       =         16
      MAX_STREAM_ID        = 65_534_u16
      MIN_FABRIC_INDEX     =       1_u8
      MAX_FABRIC_INDEX     =     254_u8

      enum StreamUsage : UInt8
        Internal  = 0
        Recording = 1
        Analysis  = 2
        LiveView  = 3
      end

      enum EndReason : UInt8
        IceFailed         =  0
        IceTimeout        =  1
        UserHangup        =  2
        UserBusy          =  3
        Replaced          =  4
        NoUserMedia       =  5
        InviteTimeout     =  6
        AnsweredElsewhere =  7
        OutOfResources    =  8
        MediaTimeout      =  9
        LowPower          = 10
        PrivacyMode       = 11
        UnknownReason     = 12
      end

      struct Session
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter id : UInt16
        @[TLV::Field(tag: 1)]
        getter peer_node_id : UInt64
        @[TLV::Field(tag: 2)]
        getter peer_endpoint_id : UInt16
        @[TLV::Field(tag: 3)]
        getter stream_usage : StreamUsage
        @[TLV::Field(tag: 4, optional: true)]
        getter video_stream_id : UInt16?
        @[TLV::Field(tag: 5, optional: true)]
        getter audio_stream_id : UInt16?
        @[TLV::Field(tag: 6)]
        getter? metadata_enabled : Bool
        @[TLV::Field(tag: 7, optional: true)]
        getter video_streams : Array(UInt16)?
        @[TLV::Field(tag: 8, optional: true)]
        getter audio_streams : Array(UInt16)?
        @[TLV::Field(tag: 254)]
        getter fabric_index : UInt8

        def initialize(*, @id : UInt16, @peer_node_id : UInt64,
                       @peer_endpoint_id : UInt16, @stream_usage : StreamUsage,
                       @metadata_enabled : Bool, @fabric_index : UInt8,
                       @video_stream_id : UInt16? = nil, @audio_stream_id : UInt16? = nil,
                       @video_streams : Array(UInt16)? = nil,
                       @audio_streams : Array(UInt16)? = nil)
        end
      end

      struct IceServer
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter urls : Array(String)
        @[TLV::Field(tag: 1, optional: true)]
        getter username : String?
        @[TLV::Field(tag: 2, optional: true)]
        getter credential : String?
        @[TLV::Field(tag: 3, optional: true)]
        getter ca_id : UInt16?

        def initialize(@urls : Array(String), @username : String? = nil,
                       @credential : String? = nil, @ca_id : UInt16? = nil)
        end
      end

      struct IceCandidate
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter candidate : String
        @[TLV::Field(tag: 1, optional: false)]
        getter sdp_mid : String?
        @[TLV::Field(tag: 2, optional: false)]
        getter sdp_m_line_index : UInt16?

        def initialize(@candidate : String, @sdp_mid : String?,
                       @sdp_m_line_index : UInt16?)
        end
      end

      struct OfferRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter sdp : String
        @[TLV::Field(tag: 2, optional: true)]
        getter ice_servers : Array(IceServer)?
        @[TLV::Field(tag: 3, optional: true)]
        getter ice_transport_policy : String?

        def initialize(@session_id : UInt16, @sdp : String,
                       @ice_servers : Array(IceServer)? = nil,
                       @ice_transport_policy : String? = nil)
        end
      end

      struct AnswerRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter sdp : String

        def initialize(@session_id : UInt16, @sdp : String)
        end
      end

      struct IceCandidatesRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter ice_candidates : Array(IceCandidate)

        def initialize(@session_id : UInt16, @ice_candidates : Array(IceCandidate))
        end
      end

      struct EndRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter reason : UInt8

        def initialize(@session_id : UInt16, @reason : UInt8)
        end

        def initialize(session_id : UInt16, reason : EndReason)
          @session_id = session_id
          @reason = reason.value
        end
      end

      abstract class Peer
        abstract def offer(session : Session, request : OfferRequest) : InteractionModel::Status
        abstract def answer(session : Session, request : AnswerRequest) : InteractionModel::Status
        abstract def ice_candidates(session : Session, request : IceCandidatesRequest) : InteractionModel::Status
        abstract def end_session(session : Session, request : EndRequest) : InteractionModel::Status
      end

      attribute 0x0000, :current_sessions, Array(Session), computed: true,
        read_access: :administer, fabric_scoped: true

      command 0x0000, :offer, request: OfferRequest, access: :operate
      command 0x0001, :answer, request: AnswerRequest, access: :operate
      command 0x0002, :ice_candidates, request: IceCandidatesRequest, access: :operate
      command 0x0003, :end, request: EndRequest, access: :operate, handler: :end_session

      @sessions = [] of Session

      def initialize(endpoint_id : DataType::EndpointNumber, @peer : Peer)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def current_sessions(fabric_index : UInt8?) : Array(Session) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        entries = request_fabric_filtered? ? @sessions.select(&.fabric_index.==(fabric_index)) : @sessions
        entries.map { |session| Session.from_slice(session.to_slice) }
      end

      # Called by the media host when it creates or updates a session after
      # Provider solicitation. The tuple (fabric, peer Node ID, session ID)
      # is the identity used by every incoming signaling command.
      def upsert_session(session : Session) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_session?(session)
        index = @sessions.index do |entry|
          entry.fabric_index == session.fabric_index &&
            entry.peer_node_id == session.peer_node_id && entry.id == session.id
        end
        return InteractionModel::Status.resource_exhausted if index.nil? && @sessions.size >= MAX_SESSIONS
        copy = Session.from_slice(session.to_slice)
        if index
          @sessions[index] = copy
        else
          @sessions << copy
        end
        increment_version_and_notify(ATTR_CURRENT_SESSIONS)
        InteractionModel::Status.success
      end

      def remove_session(fabric_index : UInt8, peer_node_id : UInt64, id : UInt16) : Bool
        old_size = @sessions.size
        @sessions.reject! do |session|
          session.fabric_index == fabric_index && session.peer_node_id == peer_node_id && session.id == id
        end
        return false if @sessions.size == old_size
        increment_version_and_notify(ATTR_CURRENT_SESSIONS)
        true
      end

      def remove_fabric(fabric_index : UInt8) : Nil
        affected = @sessions.select(&.fabric_index.==(fabric_index))
        return if affected.empty?
        @sessions.reject!(&.fabric_index.==(fabric_index))
        increment_version_and_notify(ATTR_CURRENT_SESSIONS)
        affected.each do |session|
          @peer.end_session(session, EndRequest.new(session.id, EndReason::UnknownReason))
        end
      end

      def offer(request : OfferRequest) : InteractionModel::Status
        session = authenticated_session(request.session_id)
        return session if session.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error unless valid_sdp?(request.sdp) && valid_offer_options?(request)
        @peer.offer(session, request)
      end

      def answer(request : AnswerRequest) : InteractionModel::Status
        session = authenticated_session(request.session_id)
        return session if session.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error unless valid_sdp?(request.sdp)
        @peer.answer(session, request)
      end

      def ice_candidates(request : IceCandidatesRequest) : InteractionModel::Status
        session = authenticated_session(request.session_id)
        return session if session.is_a?(InteractionModel::Status)
        candidates = request.ice_candidates
        return InteractionModel::Status.constraint_error if candidates.empty? ||
                                                            candidates.any? { |candidate| candidate.sdp_mid.try(&.empty?) }
        @peer.ice_candidates(session, request)
      end

      def end_session(request : EndRequest) : InteractionModel::Status
        session = authenticated_session(request.session_id)
        return session if session.is_a?(InteractionModel::Status)
        return InteractionModel::Status.constraint_error unless EndReason.from_value?(request.reason)
        status = @peer.end_session(session, request)
        remove_session(session.fabric_index, session.peer_node_id, session.id)
        status
      end

      private def authenticated_session(id : UInt16) : Session | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        fabric = request_fabric_index
        node = request_peer_node_id
        return InteractionModel::Status.unsupported_access unless fabric && node
        @sessions.find do |session|
          session.id == id && session.fabric_index == fabric && session.peer_node_id == node
        end || InteractionModel::Status.not_found
      end

      private def valid_sdp?(sdp : String) : Bool
        !sdp.empty? && sdp.valid_encoding?
      end

      private def valid_offer_options?(request : OfferRequest) : Bool
        if servers = request.ice_servers
          return false if servers.size > MAX_ICE_SERVERS
          return false if servers.any? do |server|
                            server.urls.size > MAX_SERVER_URLS ||
                            server.urls.any? { |url| url.bytesize > MAX_URL_BYTES || !url.valid_encoding? } ||
                            server.username.try { |value| value.bytesize > MAX_USERNAME_BYTES || !value.valid_encoding? } ||
                            server.credential.try { |value| value.bytesize > MAX_CREDENTIAL_BYTES || !value.valid_encoding? } ||
                            server.ca_id == UInt16::MAX
                          end
        end
        policy = request.ice_transport_policy
        !policy || (policy.bytesize <= MAX_POLICY_BYTES && policy.valid_encoding?)
      end

      private def valid_session?(session : Session) : Bool
        return false unless (MIN_FABRIC_INDEX..MAX_FABRIC_INDEX).includes?(session.fabric_index)
        return false unless (DataType::NodeId::OPERATIONAL_MINIMUM..DataType::NodeId::OPERATIONAL_MAXIMUM).includes?(session.peer_node_id)
        return false unless session.video_streams || session.audio_streams
        return false if session.video_stream_id.try { |id| id > MAX_STREAM_ID }
        return false if session.audio_stream_id.try { |id| id > MAX_STREAM_ID }
        return false unless valid_stream_ids?(session.video_streams) && valid_stream_ids?(session.audio_streams)
        true
      end

      private def valid_stream_ids?(ids : Array(UInt16)?) : Bool
        return true unless ids
        !ids.empty? && ids.size <= MAX_STREAM_IDS && ids.all? { |id| id <= MAX_STREAM_ID } && ids.uniq.size == ids.size
      end
    end
  end
end
