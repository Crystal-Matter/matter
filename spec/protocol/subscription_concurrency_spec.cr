require "../spec_helper"

require "../../src/matter/cluster/on_off"
require "../../src/matter/codec/message_codec"
require "../../src/matter/protocol/message_handler"

# An OnOff cluster that runs a probe on every attribute read.
#
# Both paths under test read attributes: the subscription report reads the
# changed attribute, and the inbound ReadRequest reads the requested one. The
# probe is therefore inside both critical sections.
private class ProbedOnOff < Matter::Cluster::OnOff
  property on_read : Proc(Nil)?

  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    @on_read.try(&.call)
    super
  end
end

private PEER = Socket::IPAddress.new("127.0.0.1", 5540)

describe "Protocol concurrency" do
  it "serialises subscription reports raised on another fiber against inbound message handling" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    storage = Matter::Storage::Memory.new
    handler = Matter::Protocol::MessageHandler.new(
      transport: transport,
      setup_pin: 20202021_u32,
      discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(storage)
    )

    endpoint = endpoint(1)
    on_off = ProbedOnOff.new(endpoint, on_off: false)
    handler.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = on_off

    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    session.peer_subject_ids = [session.peer_node_id.as(Matter::DataType::NodeId).id]
    handler.sessions[session.session_id] = session

    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16,
      cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::OnOff::ATTR_ON_OFF
    )
    handler.active_subscriptions[1_u32] = Matter::Protocol::ActiveSubscription.new(
      subscription_id: 1_u32,
      min_interval: 0_u16,
      max_interval: 60_u16,
      peer: PEER,
      session: session,
      attribute_paths: [path],
      exchange_id: 0x1234_u16
    )

    # The probe suspends the first reader inside its critical section and
    # records whether anyone else gets in behind it. `inside_critical` is only
    # ever true while the reporting fiber sits parked inside `read_attribute`.
    inside_critical = false
    overlapped = false
    first_reader = true
    parked = Channel(Nil).new
    release = Channel(Nil).new

    on_off.on_read = -> do
      if first_reader
        first_reader = false
        inside_critical = true
        parked.send(nil)
        release.receive
        inside_critical = false
      elsif inside_critical
        overlapped = true
      end
      nil
    end

    read_request = Matter::InteractionModel::ReadRequestMessage.new(attribute_requests: [path])
    message = Matter::Spec::ProtocolMessages.from_peer(
      session,
      Matter::InteractionModel::MessageType::ReadRequest.value,
      read_request.to_slice,
      message_counter: 5_u32,
      exchange_id: 7_u16
    )

    reported = Channel(Nil).new
    spawn do
      handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)
      reported.send(nil)
    end

    # The reporting fiber is now parked inside the report path.
    parked.receive

    # Releases it once this fiber blocks - which it must, on the shared lock.
    spawn { release.send(nil) }

    handler.handle_message(message, PEER)
    reported.receive

    # A report raised on another fiber and an inbound message never overlap.
    overlapped.should be_false

    # Both paths ran, each sending exactly one packet, and the session's
    # message counter advanced once per packet with no reuse.
    transport.sent_packets.size.should eq(2)
    counters = transport.sent_packets.map do |packet_bytes, _|
      Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes).header.message_id
    end
    counters.uniq.size.should eq(2)
    counters.should eq(counters.sort)

    handler.close
  end
end
