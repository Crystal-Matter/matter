require "./e2e_helper"

describe "synthetic Operational State interoperability" do
  device = E2E::Device["matter_operational_state"]

  it "advertises revision three and readable phase, countdown and state values" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0060_i64)
    read_int(device, "operationalstate", "cluster-revision", "ClusterRevision", 1).should eq(3_i64)
    read_int(device, "operationalstate", "current-phase", "CurrentPhase", 1).should eq(0_i64)
    read_int(device, "operationalstate", "countdown-time", "CountdownTime", 1).should eq(120_i64)
    read_int(device, "operationalstate", "operational-state", "OperationalState", 1).should eq(0_i64)
  end

  it "responds to Start, Pause, Resume and Stop with status structs and state changes" do
    invalid_pause = expect_success(device.invoke("operationalstate", "pause", endpoint: 1))
    invalid_pause.int("ErrorStateID").should eq(3_i64)

    { {"start", 1_i64}, {"pause", 2_i64}, {"resume", 1_i64}, {"stop", 0_i64} }.each do |command, expected_state|
      response = expect_success(device.invoke("operationalstate", command, endpoint: 1))
      response.int("ErrorStateID").should eq(0_i64)
      read_int(device, "operationalstate", "operational-state", "OperationalState", 1).should eq(expected_state)
    end
  end
end
