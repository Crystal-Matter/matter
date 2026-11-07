require "./e2e_helper"

# Host-injected Walking observation exercises the provisional HA wire surface
# without depending on simulated sensor timing.
describe "synthetic Ambient Context Sensing examples" do
  device = E2E::Device["matter_ambient_context"]
  trigger = File.join(E2E::LOG_DIR, "matter_ambient_context.trigger")
  ack = "#{trigger}.ack"

  it "commissions the HA, OC+OI, AUD, HA+PRED, and AUD+PRED fixture" do
    device.commission!
  end

  it "reads host-published AUD predictions and prunes them when the test clock advances" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 5).should eq(24)
    expect_success(device.read("ambientcontextsensing", "audio-context-detected", 5))
      .bool("AudioContextDetected").should be_false
    initial = expect_success(device.read("ambientcontextsensing", "predicted-activity", 5))
    initial.output.should_not contain("StartTimestamp")

    File.delete(ack) if File.exists?(ack)
    nonce = "predict-barking:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not publish sound prediction" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", 5))
    forecast.output.should contain("StartTimestamp")
    forecast.output.should contain("EndTimestamp")
    forecast.output.should contain("Tag: 4")
    forecast.output.should contain("Confidence: 80")
    forecast.output.should contain("Confidence: 60")

    File.delete(ack)
    nonce = "advance-sound-prediction-clock:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not advance sound prediction clock" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    remaining = expect_success(device.read("ambientcontextsensing", "predicted-activity", 5))
    remaining.output.should_not contain("Confidence: 80")
    remaining.output.should contain("Confidence: 60")

    File.delete(ack)
    nonce = "barking-pred:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not classify sound on predicted endpoint" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    expect_success(device.read("ambientcontextsensing", "audio-context-detected", 5))
      .bool("AudioContextDetected").should be_true
    expect_success(device.read("ambientcontextsensing", "ambient-context-type", 5))
      .output.should contain("Tag: 4")
    expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, "5"]))
      .output.should contain("Tag: 4")
  end

  it "reads host-published HA predictions and prunes them when the test clock advances" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 4).should eq(17)
    initial = expect_success(device.read("ambientcontextsensing", "predicted-activity", 4))
    initial.output.should_not contain("StartTimestamp")

    File.delete(ack) if File.exists?(ack)
    nonce = "predict-walking:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not publish prediction" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", 4))
    forecast.output.should contain("StartTimestamp")
    forecast.output.should contain("EndTimestamp")
    forecast.output.should contain("Tag: 3")
    forecast.output.should contain("Confidence: 80")
    forecast.output.should contain("Confidence: 60")

    File.delete(ack)
    nonce = "advance-prediction-clock:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not advance prediction clock" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    remaining = expect_success(device.read("ambientcontextsensing", "predicted-activity", 4))
    remaining.output.should_not contain("Confidence: 80")
    remaining.output.should contain("Confidence: 60")
  end

  it "advertises AUD and reports a host-classified sound and expiry" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 3).should eq(8)
    expect_success(device.read("ambientcontextsensing", "audio-context-detected", 3))
      .bool("AudioContextDetected").should be_false
    supported = expect_success(device.read("ambientcontextsensing", "ambient-context-type-supported", 3))
    supported.output.should contain("NamespaceID")
    supported.output.should contain("Tag: 4")

    File.delete(ack) if File.exists?(ack)
    nonce = "barking:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not acknowledge Barking" if Time.instant >= deadline
      sleep 100.milliseconds
    end

    expect_success(device.read("ambientcontextsensing", "audio-context-detected", 3))
      .bool("AudioContextDetected").should be_true
    expect_success(device.read("ambientcontextsensing", "ambient-context-type", 3)).output.should contain("Tag: 4")
    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, "3"]))
    started.output.should contain("Tag: 4")

    expect_success(device.write("ambientcontextsensing", "hold-time", 1, 3))
    deadline = Time.instant + 10.seconds
    loop do
      break if expect_success(device.read("ambientcontextsensing", "audio-context-detected", 3))
                 .bool("AudioContextDetected") == false
      raise "Ambient Context sound detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, "3"]))
    start_time = ended.int("EventStartTime") || ended.int("EventStartTimePos")
    start_time.as(Int64).should be > 0_i64
    expect_success(device.read("ambientcontextsensing", "ambient-context-type", 3)).output.should contain("Tag: 0")
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

  it "ends a repeated HA detection at the advertised HoldTimeMax" do
    started = "#{trigger}.started"
    File.delete(started) if File.exists?(started)
    File.delete(ack) if File.exists?(ack)
    nonce = "walking-cap:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(started) && File.read(started) == nonce
      raise "Ambient Context host did not start repeated Walking" if Time.instant >= deadline
      sleep 100.milliseconds
    end

    expect_success(device.read("ambientcontextsensing", "human-activity-detected", 4))
      .bool("HumanActivityDetected").should be_true
    deadline = Time.instant + 15.seconds
    until File.exists?(ack) && File.read(ack).starts_with?(nonce)
      raise "Ambient Context host did not complete HoldTimeMax probe" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    File.read(ack).should eq("#{nonce}:expired")
    expect_success(device.read("ambientcontextsensing", "human-activity-detected", 4))
      .bool("HumanActivityDetected").should be_false
    expect_success(device.read("ambientcontextsensing", "ambient-context-type", 4)).output.should contain("Tag: 0")
    expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, "4"]))
      .output.should contain("EventStartTime")
  end
end
