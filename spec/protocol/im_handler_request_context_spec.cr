require "../spec_helper"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/im_handler"

private class RequestContextProbe < Matter::Cluster::OnOff
  property entered : Channel(Nil)?
  property release : Channel(Nil)?
  getter observed : Tuple(UInt64?, UInt8?)?

  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    if entered = @entered
      entered.send(nil)
      @release.try(&.receive)
      @observed = {request_session_id, request_fabric_index}
    end
    super
  end
end

describe "IMHandler request context" do
  it "keeps a parked read's authenticated context while another fiber invokes the same cluster" do
    cluster = RequestContextProbe.new(endpoint(1))
    entered = Channel(Nil).new
    release = Channel(Nil).new
    cluster.entered = entered
    cluster.release = release
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) }
    read_path = Matter::InteractionModel::AttributePath.new(1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)
    command_path = Matter::InteractionModel::CommandPath.new(1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)
    command = Matter::InteractionModel::CommandDataIBTlv.new(command_path, nil)
    reader_done = Channel(Nil).new
    writer_done = Channel(Nil).new
    writer_started = Channel(Nil).new

    spawn do
      Matter::Protocol::IMHandler.read_attributes([read_path], clusters,
        fabric_index: 1_u8, is_case_session: true, session_id: 10_u64,
        peer_subject_ids: [0x101_u64])
      reader_done.send(nil)
    end
    entered.receive
    spawn do
      writer_started.send(nil)
      Matter::Protocol::IMHandler.invoke_commands([command], clusters,
        fabric_index: 2_u8, is_case_session: true, session_id: 20_u64,
        peer_subject_ids: [0x202_u64])
      writer_done.send(nil)
    end
    writer_started.receive
    10.times { Fiber.yield }
    release.send(nil)
    reader_done.receive
    writer_done.receive

    cluster.observed.should eq({10_u64, 1_u8})
  end
end
