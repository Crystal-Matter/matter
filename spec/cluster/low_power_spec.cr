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

  it "requires a host and queues transitions only after successful admission" do
    cluster = build(LowPower)
    expect_status(invoke(cluster, LowPower::CMD_SLEEP), Matter::InteractionModel::StatusCode::InvalidInState)
    cluster.request_session_identity = 42_u64
    cluster.request_exchange_id = 9_u16
    transitions = 0
    cluster.configure_host(-> { Matter::InteractionModel::Status.busy }, -> { transitions += 1; nil })
    expect_status(invoke(cluster, LowPower::CMD_SLEEP), Matter::InteractionModel::StatusCode::Busy)
    cluster.take_pending_sleep(42_u64, 9_u16).should be_nil
    cluster.configure_host(-> { Matter::InteractionModel::Status.success }, -> { transitions += 1; nil })
    expect_success(invoke(cluster, LowPower::CMD_SLEEP))
    transitions.should eq(0)
    expect_status(invoke(cluster, LowPower::CMD_SLEEP), Matter::InteractionModel::StatusCode::Busy)
    cluster.take_pending_sleep(42_u64, 10_u16).should be_nil
    transition = cluster.take_pending_sleep(42_u64, 9_u16)
    if transition
      transition.call
    else
      fail "accepted Sleep did not queue a transition"
    end
    transitions.should eq(1)
  end

  it "refuses a full pending queue before invoking host admission" do
    cluster = build(LowPower)
    cluster.request_session_identity = 43_u64
    accepted = 0
    cluster.configure_host(
      -> { accepted += 1; Matter::InteractionModel::Status.success },
      -> { nil })
    LowPower::MAX_PENDING_SLEEPS.times do |index|
      cluster.request_exchange_id = index.to_u16
      expect_success(invoke(cluster, LowPower::CMD_SLEEP))
    end
    cluster.request_exchange_id = LowPower::MAX_PENDING_SLEEPS.to_u16
    expect_status(invoke(cluster, LowPower::CMD_SLEEP), Matter::InteractionModel::StatusCode::Busy)
    accepted.should eq(LowPower::MAX_PENDING_SLEEPS)
  end
end
