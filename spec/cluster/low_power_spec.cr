require "../spec_helper"

private alias LowPower = Matter::Cluster::LowPower

describe "Matter 1.6 Low Power" do
  it "declares revision 1 with the mandatory Sleep command" do
    cluster = build(LowPower)
    cluster.cluster_id.id.should eq(0x0508_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.should be_empty
    cluster.commands.map(&.id.id).should eq([LowPower::CMD_SLEEP])
    cluster.commands.first.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
  end

  it "requires a host low-power handler and passes its status through" do
    cluster = build(LowPower)
    expect_status(invoke(cluster, LowPower::CMD_SLEEP), Matter::InteractionModel::StatusCode::InvalidInState)
    calls = 0
    cluster.on_sleep do
      calls += 1
      Matter::InteractionModel::Status.busy
    end
    expect_status(invoke(cluster, LowPower::CMD_SLEEP), Matter::InteractionModel::StatusCode::Busy)
    calls.should eq(1)
    cluster.on_sleep do
      calls += 1
      Matter::InteractionModel::Status.success
    end
    expect_success(invoke(cluster, LowPower::CMD_SLEEP))
    calls.should eq(2)
  end
end
