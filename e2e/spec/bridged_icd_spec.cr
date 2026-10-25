require "./e2e_helper"

# Positive wire path uses a test-only external ICD check-in trigger. The
# ordinary bridge in bridge_spec.cr verifies that BIS stays disabled by default.
describe "synthetic bridged ICD KeepActive" do
  device = E2E::Device["matter_bridged_icd"]
  checkin = File.join(E2E::LOG_DIR, "matter_bridged_icd.checkin")
  ack = "#{checkin}.ack"

  it "commissions and advertises BIS on the bridged endpoint" do
    device.commission!
    read_int(device, "bridgeddevicebasicinformation", "cluster-revision", "ClusterRevision", 1).should eq(6_i64)
    read_int(device, "bridgeddevicebasicinformation", "feature-map", "FeatureMap", 1).should eq(1_i64 << 20)
    commands = expect_success(device.read("bridgeddevicebasicinformation", "accepted-command-list", 1)).int_list("AcceptedCommandList")
    commands.should contain(0x80_i64)
  end

  it "validates TimeoutMs and only emits ActiveChanged after a confirmed external check-in" do
    File.delete(checkin) if File.exists?(checkin)
    File.delete(ack) if File.exists?(ack)

    expect_failure(device.invoke("bridgeddevicebasicinformation", "keep-active", ["1000", "29999"], endpoint: 1),
      "CONSTRAINT_ERROR")
    expect_failure(device.invoke("bridgeddevicebasicinformation", "keep-active", ["1000", "3600001"], endpoint: 1),
      "CONSTRAINT_ERROR")
    expect_success(device.invoke("bridgeddevicebasicinformation", "keep-active", ["1000", "30000"], endpoint: 1))
    expect_success(device.invoke("bridgeddevicebasicinformation", "keep-active", ["800", "30000"], endpoint: 1))

    # This file stands in for the bridged device's own check-in and confirmed
    # StayActiveResponse duration. The fixture does not simulate a wake-up.
    File.write("#{checkin}.tmp", "1200")
    File.rename("#{checkin}.tmp", checkin)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack)
      raise "Bridged ICD host did not acknowledge external check-in" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    File.read(ack).strip.should eq("1200")
    event = expect_success(device.chip(
      ["bridgeddevicebasicinformation", "read-event", "active-changed", device.node, "1"]))
    event.int("PromisedActiveDuration").should eq(1200_i64)
  end
end
