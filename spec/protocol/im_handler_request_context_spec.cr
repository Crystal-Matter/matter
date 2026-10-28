require "../spec_helper"
require "../../src/matter/cluster/access_control"
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
    acl = Matter::Cluster::AccessControl.new(endpoint(0))
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [0x101_u64], nil, 1_u8)
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [0x202_u64], nil, 2_u8)
    clusters = {
      {0_u16, Matter::Cluster::AccessControl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
      {1_u16, Matter::Cluster::OnOff::CLUSTER_ID}         => cluster.as(Matter::Cluster::Base),
    }
    read_path = Matter::InteractionModel::AttributePath.new(1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)
    command_path = Matter::InteractionModel::CommandPath.new(1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)
    command = Matter::InteractionModel::CommandDataIBTlv.new(command_path, nil)
    reader_done = Channel(Bool).new
    writer_done = Channel(Bool).new
    writer_started = Channel(Nil).new

    spawn do
      response = Matter::Protocol::IMHandler.read_attributes([read_path], clusters,
        fabric_index: 1_u8, is_case_session: true, session_id: 10_u64,
        peer_subject_ids: [0x101_u64])
      reader_done.send(!response.first.attribute_data.nil?)
    end
    select
    when entered.receive
    when timeout(5.seconds)
      fail "The authorized CASE read did not enter the cluster"
    end
    spawn do
      writer_started.send(nil)
      response = Matter::Protocol::IMHandler.invoke_commands([command], clusters,
        fabric_index: 2_u8, is_case_session: true, session_id: 20_u64,
        peer_subject_ids: [0x202_u64])
      writer_done.send(response.first.command_status.try(&.status.status) ==
                       Matter::InteractionModel::StatusCode::Success.value)
    end
    select
    when writer_started.receive
    when timeout(5.seconds)
      fail "The concurrent CASE invoke did not start"
    end
    10.times { Fiber.yield }
    select
    when release.send(nil)
    when timeout(5.seconds)
      fail "The parked CASE read did not resume"
    end
    select
    when success = reader_done.receive
      success.should be_true
    when timeout(5.seconds)
      fail "The authorized CASE read did not finish"
    end
    select
    when success = writer_done.receive
      success.should be_true
    when timeout(5.seconds)
      fail "The authorized CASE invoke did not finish"
    end

    cluster.observed.should eq({10_u64, 1_u8})
  end
end
