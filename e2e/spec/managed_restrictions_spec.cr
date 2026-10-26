require "./e2e_helper"

private MANAGED_ACCESS_CONTROL_CLUSTER = "0x1f"
private MANAGED_REVIEW_COMMAND         = "0x0"

describe "Matter 1.6 managed restriction interoperability" do
  device = E2E::Device["matter_managed_restrictions"]
  review_path = File.join(E2E::LOG_DIR, "matter_managed_restrictions.review")
  update_path = File.join(E2E::LOG_DIR, "matter_managed_restrictions.update")

  it "commissions an opt-in MNGD host and completes a token-correlated review" do
    device.commission!
    read_int(device, "accesscontrol", "feature-map", "FeatureMap", 0).should eq(3_i64)
    expect_success(device.read("accesscontrol", "commissioning-arl", 0)).output.should contain("0 entries")
    expect_success(device.read("accesscontrol", "arl", 0)).output.should contain("0 entries")
    commands = expect_success(device.read("accesscontrol", "accepted-command-list", 0))
    commands.int_list("AcceptedCommandList").should contain(0_i64)

    File.delete(review_path) if File.exists?(review_path)
    File.delete(update_path) if File.exists?(update_path)
    expect_success(device.chip("any", "command-by-id", MANAGED_ACCESS_CONTROL_CLUSTER,
      MANAGED_REVIEW_COMMAND, %({"0":[]}), device.node, "0"))

    token = File.read(review_path).strip.to_u64
    token.should be > 0_u64
    File.read(update_path).strip.to_u64.should eq(token)
    event = expect_success(device.chip("accesscontrol", "read-event",
      "fabric-restriction-review-update", device.node, "0"))
    event.output.should contain(token.to_s)
    event.output.should contain("Synthetic host denial")
    expect_success(device.read("accesscontrol", "arl", 0)).output.should contain("0 entries")

    device.restart!
    read_int(device, "accesscontrol", "feature-map", "FeatureMap", 0).should eq(3_i64)
    expect_success(device.read("accesscontrol", "arl", 0)).output.should contain("0 entries")
  end
end
