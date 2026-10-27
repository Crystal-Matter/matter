require "../error"
require "../cluster/web_rtc_transport_requestor"
require "../session"
require "../interaction_model/tlv_messages"
require "./im_client"

module Matter
  module Controller
    # Outbound Matter 1.6 WebRTC Transport Requestor signaling (cluster 0x0554).
    # The caller owns the WebRTC peer and media engine. A Binding ties every
    # command to the CASE fabric and peer that supplied the session ID.
    class WebrtcRequestorClient(I)
      CLUSTER_ID           = Cluster::WebRtcTransportRequestor::CLUSTER_ID
      CMD_OFFER            = Cluster::WebRtcTransportRequestor::CMD_OFFER
      CMD_ANSWER           = Cluster::WebRtcTransportRequestor::CMD_ANSWER
      CMD_ICE_CANDIDATES   = Cluster::WebRtcTransportRequestor::CMD_ICE_CANDIDATES
      CMD_END              = Cluster::WebRtcTransportRequestor::CMD_END
      MAX_ICE_SERVERS      =   10
      MAX_SERVER_URLS      =   10
      MAX_URL_BYTES        = 2000
      MAX_POLICY_BYTES     =   16
      MAX_USERNAME_BYTES   =  508
      MAX_CREDENTIAL_BYTES =  512

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

      record Binding, fabric_index : UInt8, peer_node_id : UInt64,
        endpoint : UInt16, session_id : UInt16

      struct IceServer
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property urls : Array(String)
        @[TLV::Field(tag: 1, optional: true)]
        property username : String?
        @[TLV::Field(tag: 2, optional: true)]
        property credential : String?
        @[TLV::Field(tag: 3, optional: true)]
        property ca_id : UInt16?

        def initialize(@urls : Array(String), @username : String? = nil,
                       @credential : String? = nil, @ca_id : UInt16? = nil)
        end
      end

      struct IceCandidate
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property candidate : String
        @[TLV::Field(tag: 1, optional: false)]
        property sdp_mid : String?
        @[TLV::Field(tag: 2, optional: false)]
        property sdp_m_line_index : UInt16?

        def initialize(@candidate : String, @sdp_mid : String? = nil,
                       @sdp_m_line_index : UInt16? = nil)
        end
      end

      struct OfferRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property session_id : UInt16
        @[TLV::Field(tag: 1)]
        property sdp : String
        @[TLV::Field(tag: 2, optional: true)]
        property ice_servers : Array(IceServer)?
        @[TLV::Field(tag: 3, optional: true)]
        property ice_transport_policy : String?

        def initialize(@session_id : UInt16, @sdp : String,
                       @ice_servers : Array(IceServer)? = nil,
                       @ice_transport_policy : String? = nil)
        end
      end

      struct AnswerRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property session_id : UInt16
        @[TLV::Field(tag: 1)]
        property sdp : String

        def initialize(@session_id : UInt16, @sdp : String)
        end
      end

      struct IceCandidatesRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property session_id : UInt16
        @[TLV::Field(tag: 1)]
        property ice_candidates : Array(IceCandidate)

        def initialize(@session_id : UInt16, @ice_candidates : Array(IceCandidate))
        end
      end

      struct EndRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property session_id : UInt16
        @[TLV::Field(tag: 1)]
        property reason : EndReason

        def initialize(@session_id : UInt16, @reason : EndReason)
        end
      end

      def initialize(@im : I)
      end

      def bind(session : Session::SecureContext, endpoint : UInt16,
               session_id : UInt16) : Binding
        fabric = session.fabric_index
        peer_node = session.peer_node_id.try(&.id)
        unless session.case_session? && fabric && peer_node
          raise Matter::SessionError.new("WebRTC Requestor signaling requires an authenticated CASE peer")
        end
        Binding.new(fabric, peer_node, endpoint, session_id)
      end

      def offer(binding : Binding, session : Session::SecureContext,
                peer : Socket::IPAddress, sdp : String,
                ice_servers : Array(IceServer)? = nil,
                ice_transport_policy : String? = nil) : Nil
        validate_sdp!(sdp)
        validate_ice_servers!(ice_servers)
        if policy = ice_transport_policy
          unless policy.bytesize <= MAX_POLICY_BYTES
            raise Matter::ConfigurationError.new("ICE transport policy exceeds 16 bytes")
          end
        end
        invoke!(binding, session, peer, CMD_OFFER,
          OfferRequest.new(binding.session_id, sdp, ice_servers, ice_transport_policy).to_slice)
      end

      def answer(binding : Binding, session : Session::SecureContext,
                 peer : Socket::IPAddress, sdp : String) : Nil
        validate_sdp!(sdp)
        invoke!(binding, session, peer, CMD_ANSWER,
          AnswerRequest.new(binding.session_id, sdp).to_slice)
      end

      def ice_candidates(binding : Binding, session : Session::SecureContext,
                         peer : Socket::IPAddress,
                         candidates : Array(IceCandidate)) : Nil
        if candidates.empty? || candidates.any? { |candidate| candidate.candidate.empty? || candidate.sdp_mid.try(&.empty?) }
          raise Matter::ConfigurationError.new("ICE candidates must be nonempty and valid")
        end
        invoke!(binding, session, peer, CMD_ICE_CANDIDATES,
          IceCandidatesRequest.new(binding.session_id, candidates).to_slice)
      end

      def end_session(binding : Binding, session : Session::SecureContext,
                      peer : Socket::IPAddress, reason : EndReason) : Nil
        invoke!(binding, session, peer, CMD_END,
          EndRequest.new(binding.session_id, reason).to_slice)
      end

      private def validate_sdp!(sdp : String) : Nil
        raise Matter::ConfigurationError.new("WebRTC SDP cannot be empty") if sdp.empty?
      end

      private def validate_ice_servers!(servers : Array(IceServer)?) : Nil
        return unless servers
        if servers.size > MAX_ICE_SERVERS || servers.any? do |server|
             server.urls.size > MAX_SERVER_URLS ||
             server.urls.any? { |url| url.bytesize > MAX_URL_BYTES } ||
             (username = server.username) && username.bytesize > MAX_USERNAME_BYTES ||
             (credential = server.credential) && credential.bytesize > MAX_CREDENTIAL_BYTES ||
             server.ca_id == UInt16::MAX
           end
          raise Matter::ConfigurationError.new("ICE server exceeds Matter 1.6 bounds")
        end
      end

      private def invoke!(binding : Binding, session : Session::SecureContext,
                          peer : Socket::IPAddress, command_id : UInt32,
                          payload : Bytes) : Nil
        unless session.case_session? && session.fabric_index == binding.fabric_index &&
               session.peer_node_id.try(&.id) == binding.peer_node_id &&
               session.accepts_peer?(peer)
          raise Matter::SessionError.new("WebRTC Requestor CASE peer or fabric differs from binding")
        end
        response = @im.invoke(session, peer, binding.endpoint, CLUSTER_ID, command_id, payload)
        unless response.invoke_responses.size == 1
          raise Matter::ProtocolError.new("WebRTC Requestor returned an ambiguous response")
        end
        item = response.invoke_responses.first
        status = item.command_status || raise Matter::ProtocolError.new("WebRTC Requestor omitted command status")
        path = status.command_path
        unless path.endpoint == binding.endpoint && path.cluster == CLUSTER_ID && path.command == command_id
          raise Matter::ProtocolError.new("WebRTC Requestor returned a mismatched command path")
        end
        unless status.status.status == InteractionModel::StatusCode::Success.value
          raise Matter::ClusterError.from_wire("WebRTC Requestor command failed",
            status.status.status, status.status.cluster_status)
        end
      end
    end
  end
end
