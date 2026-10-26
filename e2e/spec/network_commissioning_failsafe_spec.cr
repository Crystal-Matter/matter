require "./e2e_helper"

describe "Network Commissioning fail-safe rollback over chip-tool" do
  device = E2E::Device["matter_network_failsafe"]
  state_path = File.join(E2E::LOG_DIR, "matter_network_failsafe.state")
  baseline = "Crystal Baseline"
  tentative = "Crystal Tentative"
  baseline_id = baseline.to_slice.hexstring
  tentative_id = tentative.to_slice.hexstring
  credentials = "correct horse battery"

  it "restores a removed network and evicts a tentative one from the host backend on expiry" do
    device.commission!
    read_int(device, "networkcommissioning", "max-networks", "MaxNetworks", 0).should eq(1)

    # Commit the baseline so the next fail-safe has an earlier state to restore.
    expect_success(device.invoke("generalcommissioning", "arm-fail-safe", ["60", "0"], endpoint: 0))
    added = expect_success(device.invoke("networkcommissioning", "add-or-update-wi-fi-network",
      ["hex:#{baseline_id}", "hex:#{credentials.to_slice.hexstring}"], endpoint: 0))
    added.output.should match(/\bnetworkingStatus:\s*0\b/i)
    expect_success(device.invoke("generalcommissioning", "commissioning-complete", endpoint: 0))

    baseline_state = File.read(state_path)
    baseline_state.should contain("network_ids=#{baseline_id}\n")
    restores_before = baseline_state.match(/\brestores=(\d+)/).try(&.[1].to_i) ||
                      fail("fixture backend did not report its restore counter: #{baseline_state}")

    # MaxNetworks is one. Removing the committed network creates room for the
    # tentative add, and both operations must be undone at the same deadline.
    expect_success(device.invoke("generalcommissioning", "arm-fail-safe", ["60", "0"], endpoint: 0))
    removed = expect_success(device.invoke("networkcommissioning", "remove-network",
      ["hex:#{baseline_id}"], endpoint: 0))
    removed.output.should match(/\bnetworkingStatus:\s*0\b/i)
    provisional = expect_success(device.invoke("networkcommissioning", "add-or-update-wi-fi-network",
      ["hex:#{tentative_id}", "hex:#{credentials.to_slice.hexstring}"], endpoint: 0))
    provisional.output.should match(/\bnetworkingStatus:\s*0\b/i)
    File.read(state_path).should contain("network_ids=#{tentative_id}\n")
    before_expiry = expect_success(device.read("networkcommissioning", "networks", 0))
    before_expiry.output.downcase.should contain(tentative_id)
    before_expiry.output.downcase.should_not contain(baseline_id)

    expect_success(device.invoke("generalcommissioning", "arm-fail-safe", ["1", "0"], endpoint: 0))
    sleep 2.seconds
    after_expiry = expect_success(device.read("networkcommissioning", "networks", 0))
    after_expiry.output.downcase.should contain(baseline_id)
    after_expiry.output.downcase.should_not contain(tentative_id)
    restored_state = File.read(state_path)
    restored_state.should contain("restores=#{restores_before + 1}\n")
    restored_state.should contain("network_ids=#{baseline_id}\n")

    # ConnectNetwork reaches the platform backend after the restored cluster
    # metadata has passed its network-ID lookup.
    expect_success(device.invoke("generalcommissioning", "arm-fail-safe", ["60", "0"], endpoint: 0))
    connected = expect_success(device.invoke("networkcommissioning", "connect-network",
      ["hex:#{baseline_id}"], endpoint: 0))
    connected.output.should match(/\bnetworkingStatus:\s*0\b/i)
    expect_success(device.invoke("generalcommissioning", "commissioning-complete", endpoint: 0))
  end
end
