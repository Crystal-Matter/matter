require "./cluster"
require "./camera_av_stream_management"

module Matter
  module Cluster
    # Matter 1.6 WebRTC Transport Provider signaling. A host Peer implements
    # RFC 9429 negotiation and media transport; this cluster never fabricates
    # SDP or ICE candidates.
    class WebRtcTransportProvider < Base
      cluster 0x0553, revision: 2

      MAX_SESSION_ID            = 65_534_u16
      MAX_STREAMS               =         16
      MAX_ICE_SERVERS           =         10
      MAX_ICE_URL_LENGTH        =       2000
      MAX_ICE_USERNAME_LENGTH   =        508
      MAX_ICE_CREDENTIAL_LENGTH =        512
      MAX_ACTIVE_SESSIONS       =         32
      MAX_PENDING_SIGNALING     =        128
      OFFER_TIMEOUT             = 30.seconds

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

      alias StreamUsage = CameraAvStreamManagement::StreamUsage

      struct IceServer
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter urls : Array(String)
        @[TLV::Field(tag: 1, optional: true)]
        getter username : String?
        @[TLV::Field(tag: 2, optional: true)]
        getter credential : String?
        @[TLV::Field(tag: 3, optional: true)]
        getter caid : UInt16?

        def initialize(@urls : Array(String), @username : String? = nil,
                       @credential : String? = nil, @caid : UInt16? = nil)
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

        def initialize(@candidate : String, @sdp_mid : String? = nil,
                       @sdp_m_line_index : UInt16? = nil)
        end
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
        @audio_streams : Array(UInt16)?
        @[TLV::Field(tag: 254)]
        getter fabric_index : UInt8

        def initialize(@id : UInt16, @peer_node_id : UInt64, @peer_endpoint_id : UInt16,
                       @stream_usage : StreamUsage, audio_streams : Array(UInt16)?,
                       video_streams : Array(UInt16)?, @fabric_index : UInt8)
          @video_stream_id = video_streams.try(&.first?)
          @audio_stream_id = audio_streams.try(&.first?)
          @metadata_enabled = false
          @video_streams = video_streams.try(&.dup)
          @audio_streams = audio_streams.try(&.dup)
        end

        def audio_streams : Array(UInt16)?
          @audio_streams.try(&.dup)
        end
      end

      struct SolicitOfferRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        getter stream_usage : StreamUsage
        @[TLV::Field(tag: 1)]
        getter originating_endpoint_id : UInt16
        @[TLV::Field(tag: 2, optional: true)]
        getter video_stream_id_state : TLV::FieldState(UInt16)
        @[TLV::Field(tag: 3, optional: true)]
        getter audio_stream_id_state : TLV::FieldState(UInt16)
        @[TLV::Field(tag: 4, optional: true)]
        getter ice_servers : Array(IceServer)?
        @[TLV::Field(tag: 5, optional: true)]
        getter ice_transport_policy : String?
        @[TLV::Field(tag: 8, optional: true)]
        getter video_streams : Array(UInt16)?
        @[TLV::Field(tag: 9, optional: true)]
        getter audio_streams : Array(UInt16)?

        def initialize(@stream_usage : StreamUsage, @originating_endpoint_id : UInt16,
                       @audio_streams : Array(UInt16)? = nil,
                       audio_stream_id : UInt16? | TLV::FieldState(UInt16) = nil,
                       video_stream_id : UInt16? | TLV::FieldState(UInt16) = nil,
                       @video_streams : Array(UInt16)? = nil,
                       @ice_servers : Array(IceServer)? = nil,
                       @ice_transport_policy : String? = nil)
          @audio_stream_id_state = WebRtcTransportProvider.stream_id_field(audio_stream_id)
          @video_stream_id_state = WebRtcTransportProvider.stream_id_field(video_stream_id)
        end

        def video_stream_id : UInt16?
          @video_stream_id_state.value! if @video_stream_id_state.value?
        end

        def audio_stream_id : UInt16?
          @audio_stream_id_state.value! if @audio_stream_id_state.value?
        end
      end

      struct SolicitOfferResponse
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        getter web_rtc_session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter? deferred_offer : Bool

        @[TLV::Field(tag: 2, optional: true)]
        getter video_stream_id_state : TLV::FieldState(UInt16)
        @[TLV::Field(tag: 3, optional: true)]
        getter audio_stream_id_state : TLV::FieldState(UInt16)

        def initialize(@web_rtc_session_id : UInt16, @deferred_offer : Bool,
                       audio_stream_id : UInt16? | TLV::FieldState(UInt16) = nil,
                       video_stream_id : UInt16? | TLV::FieldState(UInt16) = nil)
          @audio_stream_id_state = WebRtcTransportProvider.stream_id_field(audio_stream_id)
          @video_stream_id_state = WebRtcTransportProvider.stream_id_field(video_stream_id)
        end

        def video_stream_id : UInt16?
          @video_stream_id_state.value! if @video_stream_id_state.value?
        end

        def audio_stream_id : UInt16?
          @audio_stream_id_state.value! if @audio_stream_id_state.value?
        end
      end

      struct ProvideOfferRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0, optional: false)]
        getter web_rtc_session_id : UInt16?
        @[TLV::Field(tag: 1)]
        getter sdp : String
        @[TLV::Field(tag: 2, optional: true)]
        getter stream_usage : StreamUsage?
        @[TLV::Field(tag: 3, optional: true)]
        getter originating_endpoint_id : UInt16?
        @[TLV::Field(tag: 4, optional: true)]
        getter video_stream_id_state : TLV::FieldState(UInt16)
        @[TLV::Field(tag: 5, optional: true)]
        getter audio_stream_id_state : TLV::FieldState(UInt16)
        @[TLV::Field(tag: 6, optional: true)]
        getter ice_servers : Array(IceServer)?
        @[TLV::Field(tag: 7, optional: true)]
        getter ice_transport_policy : String?
        @[TLV::Field(tag: 10, optional: true)]
        getter video_streams : Array(UInt16)?
        @[TLV::Field(tag: 11, optional: true)]
        getter audio_streams : Array(UInt16)?

        def initialize(@web_rtc_session_id : UInt16?, @sdp : String,
                       @stream_usage : StreamUsage? = nil,
                       @originating_endpoint_id : UInt16? = nil,
                       @audio_streams : Array(UInt16)? = nil,
                       audio_stream_id : UInt16? | TLV::FieldState(UInt16) = nil,
                       video_stream_id : UInt16? | TLV::FieldState(UInt16) = nil,
                       @video_streams : Array(UInt16)? = nil,
                       @ice_servers : Array(IceServer)? = nil,
                       @ice_transport_policy : String? = nil)
          @audio_stream_id_state = WebRtcTransportProvider.stream_id_field(audio_stream_id)
          @video_stream_id_state = WebRtcTransportProvider.stream_id_field(video_stream_id)
        end

        def video_stream_id : UInt16?
          @video_stream_id_state.value! if @video_stream_id_state.value?
        end

        def audio_stream_id : UInt16?
          @audio_stream_id_state.value! if @audio_stream_id_state.value?
        end
      end

      struct ProvideOfferResponse
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        getter web_rtc_session_id : UInt16

        @[TLV::Field(tag: 1, optional: true)]
        getter video_stream_id_state : TLV::FieldState(UInt16)
        @[TLV::Field(tag: 2, optional: true)]
        getter audio_stream_id_state : TLV::FieldState(UInt16)

        def initialize(@web_rtc_session_id : UInt16,
                       audio_stream_id : UInt16? | TLV::FieldState(UInt16) = nil,
                       video_stream_id : UInt16? | TLV::FieldState(UInt16) = nil)
          @audio_stream_id_state = WebRtcTransportProvider.stream_id_field(audio_stream_id)
          @video_stream_id_state = WebRtcTransportProvider.stream_id_field(video_stream_id)
        end

        def video_stream_id : UInt16?
          @video_stream_id_state.value! if @video_stream_id_state.value?
        end

        def audio_stream_id : UInt16?
          @audio_stream_id_state.value! if @audio_stream_id_state.value?
        end
      end

      def self.stream_id_field(value : UInt16? | TLV::FieldState(UInt16)) : TLV::FieldState(UInt16)
        case value
        in TLV::FieldState(UInt16)
          value
        in UInt16
          TLV::FieldState(UInt16).value(value)
        in Nil
          TLV::FieldState(UInt16).absent
        end
      end

      struct ProvideAnswerRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        getter web_rtc_session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter sdp : String

        def initialize(@web_rtc_session_id : UInt16, @sdp : String)
        end
      end

      struct ProvideIceCandidatesRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        getter web_rtc_session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter ice_candidates : Array(IceCandidate)

        def initialize(@web_rtc_session_id : UInt16, @ice_candidates : Array(IceCandidate))
        end
      end

      struct EndSessionRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        getter web_rtc_session_id : UInt16
        @[TLV::Field(tag: 1)]
        getter reason : EndReason

        def initialize(@web_rtc_session_id : UInt16, @reason : EndReason)
        end
      end

      abstract class Peer
        abstract def solicit_offer(session : Session, request : SolicitOfferRequest) : InteractionModel::Status
        abstract def accept_offer(session : Session, request : ProvideOfferRequest) : InteractionModel::Status
        abstract def accept_answer(session : Session, sdp : String) : InteractionModel::Status
        abstract def add_ice_candidates(session : Session, candidates : Array(IceCandidate)) : InteractionModel::Status
        abstract def end_session(session : Session, reason : EndReason) : Nil
      end

      attribute 0x0000, :current_sessions, Array(Session), computed: true,
        read_access: :manage, fabric_scoped: true

      command 0x00, :solicit_offer, request: SolicitOfferRequest,
        response: SolicitOfferResponse, response_id: 0x01, access: :operate
      command 0x02, :provide_offer, request: ProvideOfferRequest,
        response: ProvideOfferResponse, response_id: 0x03, access: :operate
      command 0x04, :provide_answer, request: ProvideAnswerRequest, access: :operate
      command 0x05, :provide_ice_candidates, request: ProvideIceCandidatesRequest, access: :operate
      command 0x06, :end_session, request: EndSessionRequest, access: :operate

      @sessions = [] of Session
      @offer_deadlines = {} of UInt16 => Time::Instant
      @next_session_id = 0_u16
      private record PendingSignaling, session_identity : UInt64, exchange_id : UInt16,
        fabric_index : UInt8, peer_node_id : UInt64, session_id : UInt16,
        sequence : UInt64, task : Proc(Nil)
      @pending_signaling = [] of PendingSignaling
      @pending_signaling_sequence = 0_u64

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @streams : CameraAvStreamManagement, @peer : Peer)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("WebRTC Provider and Camera AV streams must share an endpoint") unless @streams.endpoint_id == endpoint_id
        @streams.on_delivery_changed { end_private_sessions }
        @streams.on_audio_released do |id|
          @sessions.select { |session| session.audio_streams.try(&.includes?(id)) }.each do |session|
            remove_session(session, EndReason::OutOfResources)
          end
        end
        @streams.on_video_released do |id|
          @sessions.select { |session| session.video_streams.try(&.includes?(id)) }.each do |session|
            remove_session(session, EndReason::OutOfResources)
          end
        end
      end

      def current_sessions(fabric_index : UInt8?) : Array(Session) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        expire_offers
        @sessions.select { |session| session.fabric_index == fabric_index }
      end

      def solicit_offer(request : SolicitOfferRequest) : InteractionModel::Status | SolicitOfferResponse
        fabric, node = authenticated_peer || return InteractionModel::Status.unsupported_access
        audio_id = selected_audio_id(request.audio_stream_id_state, request.stream_usage)
        video_id = selected_video_id(request.video_stream_id_state, request.stream_usage)
        return InteractionModel::Status.resource_exhausted if request.audio_stream_id_state.null? && !audio_id
        return InteractionModel::Status.resource_exhausted if request.video_stream_id_state.null? && !video_id
        return InteractionModel::Status.constraint_error unless valid_streams?(request.audio_streams, audio_id, request.video_streams, video_id, request.stream_usage)
        return InteractionModel::Status.constraint_error unless valid_ice?(request.ice_servers, request.ice_transport_policy)
        audio = selected_audio(request.audio_streams, audio_id)
        video = selected_video(request.video_streams, video_id)
        return InteractionModel::Status.invalid_in_state unless delivery_allowed?(audio, video, request.stream_usage)
        id = allocate_id || return InteractionModel::Status.resource_exhausted
        session = Session.new(id, node, request.originating_endpoint_id, request.stream_usage,
          audio, video, fabric)
        @sessions << session
        @offer_deadlines[id] = Time.instant + OFFER_TIMEOUT
        schedule_offer_timeout
        changed
        begin
          status = peer_status { @peer.solicit_offer(session, request) }
        rescue ex
          remove_session(session, EndReason::UnknownReason)
          raise ex
        end
        unless status.success?
          remove_session(session, EndReason::UnknownReason)
          return status
        end
        SolicitOfferResponse.new(id, true,
          response_stream_id(request.audio_stream_id_state, audio_id),
          response_stream_id(request.video_stream_id_state, video_id))
      end

      def provide_offer(request : ProvideOfferRequest) : InteractionModel::Status | ProvideOfferResponse
        fabric, node = authenticated_peer || return InteractionModel::Status.unsupported_access
        return InteractionModel::Status.constraint_error if request.sdp.empty?
        return InteractionModel::Status.constraint_error unless valid_ice?(request.ice_servers, request.ice_transport_policy)
        if id = request.web_rtc_session_id
          session = owned_session(id, fabric, node) || return InteractionModel::Status.not_found
          return InteractionModel::Status.invalid_in_state unless delivery_allowed?(session)
          return InteractionModel::Status.constraint_error if (usage = request.stream_usage) && usage != session.stream_usage
          return InteractionModel::Status.constraint_error if (endpoint = request.originating_endpoint_id) && endpoint != session.peer_endpoint_id
          return InteractionModel::Status.constraint_error if request.audio_streams || !request.audio_stream_id_state.absent? ||
                                                              request.video_streams || !request.video_stream_id_state.absent?
          status = peer_status { @peer.accept_offer(session, request) }
          return status unless status.success?
          @offer_deadlines[id] = Time.instant + OFFER_TIMEOUT
          schedule_offer_timeout
          return ProvideOfferResponse.new(id, request.audio_stream_id_state, request.video_stream_id_state)
        end
        usage = request.stream_usage || return InteractionModel::Status.invalid_command
        endpoint = request.originating_endpoint_id || return InteractionModel::Status.invalid_command
        audio_id = selected_audio_id(request.audio_stream_id_state, usage)
        video_id = selected_video_id(request.video_stream_id_state, usage)
        return InteractionModel::Status.resource_exhausted if request.audio_stream_id_state.null? && !audio_id
        return InteractionModel::Status.resource_exhausted if request.video_stream_id_state.null? && !video_id
        return InteractionModel::Status.constraint_error unless valid_streams?(request.audio_streams, audio_id, request.video_streams, video_id, usage)
        audio = selected_audio(request.audio_streams, audio_id)
        video = selected_video(request.video_streams, video_id)
        return InteractionModel::Status.invalid_in_state unless delivery_allowed?(audio, video, usage)
        id = allocate_id || return InteractionModel::Status.resource_exhausted
        session = Session.new(id, node, endpoint, usage,
          audio, video, fabric)
        @sessions << session
        @offer_deadlines[id] = Time.instant + OFFER_TIMEOUT
        schedule_offer_timeout
        changed
        begin
          status = peer_status { @peer.accept_offer(session, request) }
        rescue ex
          remove_session(session, EndReason::UnknownReason)
          raise ex
        end
        unless status.success?
          remove_session(session, EndReason::UnknownReason)
          return status
        end
        ProvideOfferResponse.new(id,
          response_stream_id(request.audio_stream_id_state, audio_id),
          response_stream_id(request.video_stream_id_state, video_id))
      end

      def provide_answer(request : ProvideAnswerRequest) : InteractionModel::Status
        fabric, node = authenticated_peer || return InteractionModel::Status.unsupported_access
        session = owned_session(request.web_rtc_session_id, fabric, node) || return InteractionModel::Status.not_found
        return InteractionModel::Status.constraint_error if request.sdp.empty?
        return InteractionModel::Status.invalid_in_state unless delivery_allowed?(session)
        status = peer_status { @peer.accept_answer(session, request.sdp) }
        @offer_deadlines.delete(session.id) if status.success?
        status
      end

      def provide_ice_candidates(request : ProvideIceCandidatesRequest) : InteractionModel::Status
        fabric, node = authenticated_peer || return InteractionModel::Status.unsupported_access
        session = owned_session(request.web_rtc_session_id, fabric, node) || return InteractionModel::Status.not_found
        return InteractionModel::Status.constraint_error if request.ice_candidates.empty?
        return InteractionModel::Status.constraint_error if request.ice_candidates.any? { |candidate| candidate.sdp_mid == "" }
        return InteractionModel::Status.invalid_in_state unless delivery_allowed?(session)
        peer_status { @peer.add_ice_candidates(session, request.ice_candidates) }
      end

      def end_session(request : EndSessionRequest) : InteractionModel::Status
        fabric, node = authenticated_peer || return InteractionModel::Status.unsupported_access
        session = owned_session(request.web_rtc_session_id, fabric, node) || return InteractionModel::Status.not_found
        remove_session(session, request.reason)
        InteractionModel::Status.success
      end

      def remove_fabric(fabric_index : UInt8) : Nil
        @sessions.select { |session| session.fabric_index == fabric_index }.each do |session|
          remove_session(session, EndReason::UnknownReason)
        end
      end

      # A host media engine may fail after the command handler has returned.
      # Scope cleanup to the authenticated session owner so a delayed callback
      # cannot tear down another fabric's or peer's connection.
      def end_host_session(fabric_index : UInt8, peer_node_id : UInt64,
                           session_id : UInt16, reason : EndReason = EndReason::UnknownReason) : Bool
        with_request_context do
          session = @sessions.find do |entry|
            entry.fabric_index == fabric_index && entry.peer_node_id == peer_node_id && entry.id == session_id
          end
          return false unless session
          remove_session(session, reason)
          true
        end
      end

      # A media Peer can prepare an outbound Requestor command while handling
      # the Provider command, but must wait until its final InvokeResponse has
      # been transmitted. The protocol layer drains this queue at that point.
      def defer_signaling(session : Session, &task : -> Nil) : Bool
        with_request_context do
          identity = request_session_identity
          exchange = request_exchange_id
          return false unless request_command_active? && request_is_case_session? &&
                              identity && exchange &&
                              request_fabric_index == session.fabric_index &&
                              request_peer_node_id == session.peer_node_id &&
                              session_active?(session) &&
                              @pending_signaling.size < MAX_PENDING_SIGNALING
          @pending_signaling_sequence += 1_u64
          @pending_signaling << PendingSignaling.new(identity, exchange,
            session.fabric_index, session.peer_node_id, session.id,
            @pending_signaling_sequence, task)
          true
        end
      end

      def take_pending_signaling(session_identity : UInt64, exchange_id : UInt16) : Array(Proc(Nil))
        with_request_context do
          selected = @pending_signaling.select do |entry|
            entry.session_identity == session_identity && entry.exchange_id == exchange_id
          end
          @pending_signaling.reject! do |entry|
            entry.session_identity == session_identity && entry.exchange_id == exchange_id
          end
          selected.select { |entry| session_active?(entry.fabric_index, entry.peer_node_id, entry.session_id) }
            .map do |entry|
              -> : Nil do
                active = with_request_context do
                  session_active?(entry.fabric_index, entry.peer_node_id, entry.session_id)
                end
                entry.task.call if active
              end
            end
        end
      end

      def discard_pending_signaling(session_identity : UInt64, exchange_id : UInt16) : Nil
        with_request_context do
          @pending_signaling.reject! do |entry|
            entry.session_identity == session_identity && entry.exchange_id == exchange_id
          end
        end
      end

      def end_private_sessions : Nil
        @sessions.reject { |session| delivery_allowed?(session) }.each do |session|
          remove_session(session, EndReason::PrivacyMode)
        end
      end

      private def authenticated_peer : Tuple(UInt8, UInt64)?
        return unless request_command_active? && request_is_case_session?
        fabric = request_fabric_index
        node = request_peer_node_id
        {fabric, node} if fabric && node
      end

      # A Peer may enqueue outbound signaling before discovering it cannot
      # accept the command. Keep tasks from earlier successful commands on the
      # same InvokeRequest while dropping only this callback's additions.
      private def peer_status(& : -> InteractionModel::Status) : InteractionModel::Status
        before = @pending_signaling_sequence
        begin
          status = yield
        rescue ex
          discard_pending_after(before)
          raise ex
        end
        discard_pending_after(before) unless status.success?
        status
      end

      private def discard_pending_after(sequence : UInt64) : Nil
        @pending_signaling.reject! { |entry| entry.sequence > sequence }
      end

      private def selected_audio_id(field : TLV::FieldState(UInt16), usage : StreamUsage) : UInt16?
        return field.value! if field.value?
        return unless field.null?
        @streams.allocated_audio_streams.find { |stream| stream.stream_usage == usage }.try(&.audio_stream_id)
      end

      private def selected_video_id(field : TLV::FieldState(UInt16), usage : StreamUsage) : UInt16?
        return field.value! if field.value?
        return unless field.null?
        @streams.allocated_video_streams.find { |stream| stream.stream_usage == usage }.try(&.video_stream_id)
      end

      private def response_stream_id(field : TLV::FieldState(UInt16), selected : UInt16?) : TLV::FieldState(UInt16)
        return field unless field.null? && selected
        TLV::FieldState(UInt16).value(selected)
      end

      private def selected_audio(streams : Array(UInt16)?, legacy : UInt16?) : Array(UInt16)?
        return unless streams || legacy
        ids = streams ? streams.dup : [] of UInt16
        ids << legacy if legacy && !ids.includes?(legacy)
        ids
      end

      private def selected_video(streams : Array(UInt16)?, legacy : UInt16?) : Array(UInt16)?
        return unless streams || legacy
        ids = streams ? streams.dup : [] of UInt16
        ids << legacy if legacy && !ids.includes?(legacy)
        ids
      end

      private def delivery_allowed?(session : Session) : Bool
        delivery_allowed?(session.audio_streams, session.video_streams, session.stream_usage)
      end

      private def delivery_allowed?(audio : Array(UInt16)?, video : Array(UInt16)?, usage : StreamUsage) : Bool
        (!audio || @streams.stream_delivery_allowed?(usage)) &&
          (!video || @streams.video_delivery_allowed?(usage))
      end

      private def valid_streams?(audio : Array(UInt16)?, legacy_audio : UInt16?,
                                 video : Array(UInt16)?, legacy_video : UInt16?, usage : StreamUsage) : Bool
        return false if audio && (audio.empty? || audio.size > MAX_STREAMS || audio.uniq.size != audio.size)
        return false if video && (video.empty? || video.size > MAX_STREAMS || video.uniq.size != video.size)
        audio_ids = selected_audio(audio, legacy_audio)
        video_ids = selected_video(video, legacy_video)
        return false unless audio_ids || video_ids
        return false if audio_ids && audio_ids.size > MAX_STREAMS
        return false if video_ids && video_ids.size > MAX_STREAMS
        return false unless @streams.supported_stream_usages.includes?(usage)
        if audio_ids
          return false unless @streams.feature_map.audio?
          available = @streams.allocated_audio_streams
          return false unless audio_ids.all? { |id| available.any? { |stream| stream.audio_stream_id == id && stream.stream_usage == usage } }
        end
        if video_ids
          return false unless @streams.feature_map.video?
          available = @streams.allocated_video_streams
          return false unless video_ids.all? { |id| available.any? { |stream| stream.video_stream_id == id && stream.stream_usage == usage } }
        end
        true
      end

      private def valid_ice?(servers : Array(IceServer)?, policy : String?) : Bool
        return false if servers && servers.size > MAX_ICE_SERVERS
        return false if policy && !policy.in?("all", "relay")
        return false if servers && !servers.all? { |server| valid_ice_server?(server) }
        true
      end

      private def valid_ice_server?(server : IceServer) : Bool
        return false if server.urls.empty? || server.urls.size > MAX_ICE_SERVERS
        return false unless server.urls.all? do |url|
                              url.bytesize <= MAX_ICE_URL_LENGTH &&
                              ["stun:", "stuns:", "turn:", "turns:"].any? { |scheme| url.starts_with?(scheme) }
                            end
        # TLS ICE servers require a fabric-scoped TLSCAID lookup before a host
        # may trust the remote certificate. This bounded adapter has no CA map.
        return false if server.urls.any? { |url| url.starts_with?("stuns:") || url.starts_with?("turns:") }
        return false if (username = server.username) && username.bytesize > MAX_ICE_USERNAME_LENGTH
        return false if (credential = server.credential) && credential.bytesize > MAX_ICE_CREDENTIAL_LENGTH
        return false if (caid = server.caid) && caid > MAX_SESSION_ID
        true
      end

      private def owned_session(id : UInt16, fabric : UInt8, node : UInt64) : Session?
        expire_offers
        @sessions.find { |session| session.id == id && session.fabric_index == fabric && session.peer_node_id == node }
      end

      private def allocate_id : UInt16?
        expire_offers
        return if @sessions.size >= MAX_ACTIVE_SESSIONS
        (MAX_SESSION_ID.to_i + 1).times do
          id = @next_session_id
          @next_session_id = id == MAX_SESSION_ID ? 0_u16 : id + 1_u16
          return id unless @sessions.any? { |session| session.id == id }
        end
        nil
      end

      protected def expire_offers(now : Time::Instant = Time.instant) : Nil
        @offer_deadlines.select { |_id, deadline| deadline <= now }.each_key do |id|
          if session = @sessions.find { |entry| entry.id == id }
            remove_session(session, EndReason::InviteTimeout)
          end
        end
      end

      private def schedule_offer_timeout : Nil
        spawn do
          sleep OFFER_TIMEOUT
          with_request_context { expire_offers }
        end
      end

      private def remove_session(session : Session, reason : EndReason) : Nil
        @sessions.delete(session)
        @pending_signaling.reject! do |entry|
          entry.fabric_index == session.fabric_index && entry.peer_node_id == session.peer_node_id &&
            entry.session_id == session.id
        end
        @offer_deadlines.delete(session.id)
        changed
        begin
          @peer.end_session(session, reason)
        rescue ex
          Log.error(exception: ex) { "WebRTC peer cleanup failed for session #{session.id}" }
        end
      end

      private def session_active?(session : Session) : Bool
        session_active?(session.fabric_index, session.peer_node_id, session.id)
      end

      private def session_active?(fabric_index : UInt8, peer_node_id : UInt64, id : UInt16) : Bool
        @sessions.any? do |session|
          session.fabric_index == fabric_index && session.peer_node_id == peer_node_id && session.id == id
        end
      end

      private def changed : Nil
        increment_version_and_notify(ATTR_CURRENT_SESSIONS)
      end
    end
  end
end
