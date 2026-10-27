require "../cluster/web_rtc_transport_provider"
require "../controller/webrtc_requestor_client"

module Matter
  module Camera
    # Outbound Provider-to-Requestor signaling. The media host supplies the
    # authenticated CASE session and peer address; it owns SDP/ICE generation,
    # media tracks and session teardown.
    class RequestorSignalingSink(I)
      alias Provider = Cluster::WebRtcTransportProvider
      alias Requestor = Controller::WebrtcRequestorClient

      record Destination, session : Session::SecureContext, address : Socket::IPAddress
      alias Resolver = Proc(UInt8, UInt64, Destination?)

      def initialize(@provider : Provider, @client : Requestor(I), @resolve : Resolver)
      end

      def offer(session : Provider::Session, sdp : String,
                ice_servers : Array(Provider::IceServer)? = nil,
                ice_transport_policy : String? = nil) : Nil
        with_cleanup(session) do
          destination, binding = binding_for(session)
          servers = ice_servers.try(&.map do |server|
            Requestor::IceServer.new(server.urls, server.username, server.credential, server.caid)
          end)
          @client.offer(binding, destination.session, destination.address, sdp,
            servers, ice_transport_policy)
        end
      end

      def answer(session : Provider::Session, sdp : String) : Nil
        with_cleanup(session) do
          destination, binding = binding_for(session)
          @client.answer(binding, destination.session, destination.address, sdp)
        end
      end

      def ice_candidates(session : Provider::Session,
                         candidates : Array(Provider::IceCandidate)) : Nil
        with_cleanup(session, Provider::EndReason::IceFailed) do
          destination, binding = binding_for(session)
          wire = candidates.map do |candidate|
            Requestor::IceCandidate.new(candidate.candidate, candidate.sdp_mid,
              candidate.sdp_m_line_index)
          end
          @client.ice_candidates(binding, destination.session, destination.address, wire)
        end
      end

      def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
        with_cleanup(session, reason) do
          destination, binding = binding_for(session)
          @client.end_session(binding, destination.session, destination.address,
            Requestor::EndReason.from_value(reason.value))
        end
      end

      private def with_cleanup(session : Provider::Session,
                               reason : Provider::EndReason = Provider::EndReason::UnknownReason,
                               & : -> Nil) : Nil
        yield
      rescue error
        @provider.end_host_session(session.fabric_index, session.peer_node_id, session.id, reason)
        raise error
      end

      private def binding_for(session : Provider::Session) : Tuple(Destination, Requestor::Binding)
        destination = @resolve.call(session.fabric_index, session.peer_node_id) ||
                      raise SessionError.new("WebRTC Requestor destination is unavailable")
        secure = destination.session
        unless secure.case_session? && secure.fabric_index == session.fabric_index &&
               secure.peer_node_id.try(&.id) == session.peer_node_id
          raise SessionError.new("WebRTC Requestor destination differs from Provider fabric or peer")
        end
        {destination, @client.bind(secure, session.peer_endpoint_id, session.id)}
      end
    end
  end
end
