require "../spec_helper"
require "../../src/matter/protocol/response_sender"

describe Matter::Protocol::ResponseSender do
  it "retains a device ReportData as the same ciphertext for retransmission" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    sender = Matter::Protocol::ResponseSender.new(transport, Matter::Protocol::MrpCache.new(transport))
    session = Matter::Session::SecureContext.new(
      session_id: 4_u16, peer_session_id: 5_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 4_u8), decryption_key: Bytes.new(16, 4_u8)
    )
    peer = Socket::IPAddress.new("::1", 5540)
    sender.send_report(session, peer, Bytes[1, 2])
    counter = session.local_message_counter
    transport.pending_reliable_count.should eq(1)
    transport.retransmit_due(Time.instant + 2.seconds)
    transport.sent_packets.map(&.[0]).should eq([transport.sent_packets[0][0], transport.sent_packets[0][0]])
    session.local_message_counter.should eq(counter)
    transport.close
  end
end
