require "./e2e_helper"

# Host-injected Walking observation exercises the provisional HA wire surface
# without depending on simulated sensor timing.
describe "synthetic Ambient Context Sensing examples" do
  device = E2E::Device["matter_ambient_context"]
  trigger = File.join(E2E::LOG_DIR, "matter_ambient_context.trigger")
  ack = "#{trigger}.ack"

  it "commissions the HA and OC+OI fixture" do
    device.commission!
  end

  it "advertises OC+OI on endpoint 2 and reports threshold observations" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 2).should eq(6)
    expect_success(device.read("ambientcontextsensing", "object-count-config", 2)).output
      .should contain("ObjectCountThreshold: 2")
    expect_success(device.read("ambientcontextsensing", "object-identified", 2))
      .bool("ObjectIdentified").should be_false
    # The pinned chip-tool predates the 1.6 ObjectCountReached rename.
    expect_success(device.read("ambientcontextsensing", "object-count-threshold-reached", 2))
      .bool("ObjectCountThresholdReached").should be_false

    File.delete(ack) if File.exists?(ack)
    nonce = "person-count:2:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not acknowledge object count" if Time.instant >= deadline
      sleep 100.milliseconds
    end

    expect_success(device.read("ambientcontextsensing", "object-identified", 2))
      .bool("ObjectIdentified").should be_true
    expect_success(device.read("ambientcontextsensing", "object-count-threshold-reached", 2))
      .bool("ObjectCountThresholdReached").should be_true
    read_int(device, "ambientcontextsensing", "object-count", "ObjectCount", 2).should eq(2)
    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, "2"]))
    started.output.should contain("ObjectCountThresholdReached")
    started.output.should contain("ObjectCount: 2")
  end

  it "advertises only HA and reads canonical default and supported tags" do
    read_int(device, "ambientcontextsensing", "cluster-revision", "ClusterRevision").should eq(1)
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap").should eq(1)
    read_int(device, "ambientcontextsensing", "simultaneous-detection-limit", "SimultaneousDetectionLimit").should eq(1)
    expect_success(device.read("ambientcontextsensing", "ambient-context-type-supported")).output.should contain("NamespaceID")
    expect_success(device.read("ambientcontextsensing", "ambient-context-type")).output.should contain("AmbientContextSensed")
    expect_success(device.read("ambientcontextsensing", "human-activity-detected")).bool("HumanActivityDetected").should be_false
  end

  it "reads a host-triggered start event, HoldTime expiry, and end event" do
    File.delete(ack) if File.exists?(ack)
    nonce = "walking:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not acknowledge Walking" if Time.instant >= deadline
      sleep 100.milliseconds
    end

    expect_success(device.read("ambientcontextsensing", "human-activity-detected")).bool("HumanActivityDetected").should be_true
    current = expect_success(device.read("ambientcontextsensing", "ambient-context-type"))
    current.output.should contain("NamespaceID")
    current.output.should contain("Tag: 3")
    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, "1"]))
    started.output.should contain("AmbientContextDetected")
    started.output.should contain("Tag: 3")

    expect_success(device.write("ambientcontextsensing", "hold-time", 1))
    deadline = Time.instant + 10.seconds
    loop do
      break if expect_success(device.read("ambientcontextsensing", "human-activity-detected")).bool("HumanActivityDetected") == false
      raise "Ambient Context detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, "1"]))
    # The pinned chip-tool may label context tag 0 using its generated
    # EventStartTimePos name, while the tagged 1.6 XML names it EventStartTime.
    start_time = ended.int("EventStartTime") || ended.int("EventStartTimePos")
    start_time.as(Int64).should be > 0_i64
    expect_success(device.read("ambientcontextsensing", "ambient-context-type")).output.should contain("Tag: 0")
  end
end
