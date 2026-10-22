require "../spec_helper"

private def tcp_route_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16, peer_session_id: 2_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 1_u8),
    decryption_key: Bytes.new(16, 2_u8),
    case_session: true)
end

describe "Matter TCP secure session routing" do
  it "pins a session to one ephemeral TCP connection token" do
    session = tcp_route_session
    first = Socket::IPAddress.new("fd00::1", 0)
    second = Socket::IPAddress.new("fd00::2", 0)
    udp = Socket::IPAddress.new("::1", 5540)

    session.accepts_peer?(udp).should be_true
    session.accepts_peer?(first).should be_false
    session.bind_tcp_peer(first)
    session.accepts_peer?(first).should be_true
    session.accepts_peer?(second).should be_false
    session.accepts_peer?(udp).should be_false
  end

  it "does not restore a stale TCP connection route across restart" do
    session = tcp_route_session
    peer = Socket::IPAddress.new("fd00::1", 0)
    session.bind_tcp_peer(peer)

    restored = Matter::Session::SecureContext.from_record(session.to_record)
    restored.tcp_session?.should be_true
    restored.tcp_peer.should be_nil
    restored.accepts_peer?(peer).should be_false
    restored.accepts_peer?(Socket::IPAddress.new("::1", 5540)).should be_false
  end
end
