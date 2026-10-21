require "../spec_helper"
require "../../src/matter/controller"

private alias CommissioningCluster = Matter::Cluster::GeneralCommissioning

private class CommissionerResponseProbe < Matter::Controller::Commissioning::Commissioner
  def check_complete(response : Matter::InteractionModel::InvokeResponseMessage) : Nil
    assert_commissioning_complete!(response)
  end

  def check_tc(response : Matter::InteractionModel::InvokeResponseMessage) : Nil
    assert_tc_acknowledged!(response)
  end
end

private def set_tc_response(error : Matter::Commissioning::ErrorCode) : Matter::InteractionModel::InvokeResponseMessage
  path = Matter::InteractionModel::CommandPath.new(endpoint: 0_u16, cluster: CommissioningCluster::CLUSTER_ID,
    command: CommissioningCluster::CMD_SET_TC_ACKNOWLEDGEMENTS_RESPONSE)
  fields = TLV::Any.from_slice(CommissioningCluster::SetTCAcknowledgementsResponse.new(error).to_slice)
  data = Matter::InteractionModel::CommandDataIBTlv.new(path, fields)
  Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
    Matter::InteractionModel::InvokeResponseIB.new(command_data: data),
  ])
end

private def commissioning_complete_response(error : Matter::Commissioning::ErrorCode) : Matter::InteractionModel::InvokeResponseMessage
  path = Matter::InteractionModel::CommandPath.new(endpoint: 0_u16, cluster: CommissioningCluster::CLUSTER_ID,
    command: CommissioningCluster::CMD_COMMISSIONING_COMPLETE_RESPONSE)
  fields = TLV::Any.from_slice(CommissioningCluster::CommissioningCompleteResponse.new(error).to_slice)
  data = Matter::InteractionModel::CommandDataIBTlv.new(path, fields)
  Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
    Matter::InteractionModel::InvokeResponseIB.new(command_data: data),
  ])
end

describe Matter::Controller::Commissioning::Commissioner do
  it "checks the error code in CommissioningCompleteResponse" do
    probe = CommissionerResponseProbe.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new))
    probe.check_complete(commissioning_complete_response(Matter::Commissioning::ErrorCode::OK))
    expect_raises(Matter::CommissioningError, /NoFailSafe/) do
      probe.check_complete(commissioning_complete_response(Matter::Commissioning::ErrorCode::NoFailSafe))
    end
  ensure
    probe.try(&.close)
  end

  it "checks SetTCAcknowledgementsResponse before continuing commissioning" do
    probe = CommissionerResponseProbe.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new))
    probe.check_tc(set_tc_response(Matter::Commissioning::ErrorCode::OK))
    expect_raises(Matter::CommissioningError, /TCMinVersionNotMet/) do
      probe.check_tc(set_tc_response(Matter::Commissioning::ErrorCode::TCMinVersionNotMet))
    end
  ensure
    probe.try(&.close)
  end
end
