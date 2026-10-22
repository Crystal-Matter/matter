require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private alias DeferredLowPower = Matter::Cluster::LowPower
private LOW_POWER_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private class LowPowerFailingTransport < Matter::Spec::CaptureTransport
  property? fail_next : Bool = false

  protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
    if @fail_next
      @fail_next = false
      raise IO::Error.new("synthetic response send failure")
    end
    super
  end
end

private def low_power_fixture
  transport = LowPowerFailingTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(transport,
    setup_pin: 20202021_u32, discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  handler.clusters.delete({0_u16, Matter::Cluster::AccessControl::CLUSTER_ID})
  session = Matter::Spec::ProtocolMessages.case_session(242_u16)
  handler.sessions[session.session_id] = session
  cluster = DeferredLowPower.new(Matter::DataType::EndpointNumber.new(1_u16))
  handler.clusters[{1_u16, DeferredLowPower::CLUSTER_ID}] = cluster
  {handler, transport, session, cluster}
end

private def low_power_invoke(handler : Matter::Protocol::MessageHandler,
                             session : Matter::Session::SecureContext,
                             counter : UInt32, exchange : UInt16,
                             suppress_response : Bool = false) : Nil
  path = Matter::InteractionModel::CommandPath.new(1_u16, DeferredLowPower::CLUSTER_ID, DeferredLowPower::CMD_SLEEP)
  request = Matter::InteractionModel::InvokeRequestMessage.new([
    Matter::InteractionModel::CommandDataIBTlv.new(path, nil),
  ], suppress_response: suppress_response)
  inbound = Matter::Spec::ProtocolMessages.from_peer(session,
    Matter::InteractionModel::MessageType::InvokeRequest.value,
    request.to_slice, counter, exchange)
  handler.handle_message(inbound, LOW_POWER_PEER)
end

describe "Low Power response handoff" do
  it "starts the physical transition only after the matching InvokeResponse is sent" do
    handler, transport, session, cluster = low_power_fixture
    started = Channel(Int32).new(1)
    cluster.configure_host(
      -> { Matter::InteractionModel::Status.success },
      -> { started.send(transport.sent_packets.size); nil })
    low_power_invoke(handler, session, 1_u32, 50_u16)
    select
    when sent_count = started.receive
      sent_count.should eq(1)
    when timeout(1.second)
      fail "physical transition did not start"
    end
    handler.close
  end

  it "never starts the physical transition when the InvokeResponse send fails" do
    handler, transport, session, cluster = low_power_fixture
    started = Channel(Nil).new(1)
    cluster.configure_host(
      -> { Matter::InteractionModel::Status.success },
      -> { started.send(nil); nil })
    transport.fail_next = true
    low_power_invoke(handler, session, 1_u32, 51_u16)
    cluster.take_pending_sleep(session.object_id.to_u64, 51_u16).should be_nil
    # Retransmitting the failed message must not recover a response or work.
    low_power_invoke(handler, session, 1_u32, 51_u16)
    select
    when started.receive
      fail "failed send started physical sleep"
    when timeout(20.milliseconds)
    end
    handler.close
  end

  it "discards physical work for a suppressed status-only response" do
    handler, transport, session, cluster = low_power_fixture
    started = Channel(Nil).new(1)
    cluster.configure_host(
      -> { Matter::InteractionModel::Status.success },
      -> { started.send(nil); nil })
    low_power_invoke(handler, session, 1_u32, 52_u16, suppress_response: true)
    transport.sent_packets.should be_empty
    cluster.take_pending_sleep(session.object_id.to_u64, 52_u16).should be_nil
    select
    when started.receive
      fail "suppressed response started physical sleep"
    when timeout(20.milliseconds)
    end
    handler.close
  end
end
