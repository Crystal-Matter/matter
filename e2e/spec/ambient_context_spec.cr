require "./e2e_helper"

# Host-injected Walking observation exercises the provisional HA wire surface
# without depending on simulated sensor timing.
describe "synthetic Ambient Context Sensing examples" do
  device = E2E::Device["matter_ambient_context"]
  trigger = File.join(E2E::LOG_DIR, "matter_ambient_context.trigger")
  ack = "#{trigger}.ack"

  it "commissions the HA, OC+OI, AUD, HA+PRED, AUD+PRED, OI, OC+PRED, OI+PRED, OC+OI+PRED, OC, HA+OI, HA+OI+PRED, HA+AUD, and HA+AUD+PRED fixture" do
    device.commission!
  end

  it "switches HA+AUD live detection between human activity and sound without count fields" do
    endpoint = 13
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", endpoint).should eq(9)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", endpoint)).int_list("AttributeList")
    [0, 2, 3, 4, 8, 9, 10].each { |id| attributes.should contain(id) }
    [1, 5, 6, 7, 11].each { |id| attributes.should_not contain(id) }
    read_int(device, "ambientcontextsensing", "hold-time", "HoldTime", endpoint).should eq(60)
    expect_success(device.read("ambientcontextsensing", "ambient-context-type-supported", endpoint))
      .output.scan(/NamespaceID/).size.should eq(4)
    expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
      .bool("HumanActivityDetected").should be_false
    expect_success(device.read("ambientcontextsensing", "audio-context-detected", endpoint))
      .bool("AudioContextDetected").should be_false

    ["walking-human-sound", "barking-human-sound", "walking-human-sound", "barking-human-sound"].each do |action|
      File.delete(ack) if File.exists?(ack)
      nonce = "#{action}:#{Time.utc.to_unix_ms}"
      File.write("#{trigger}.tmp", nonce)
      File.rename("#{trigger}.tmp", trigger)
      deadline = Time.instant + 10.seconds
      until File.exists?(ack) && File.read(ack) == nonce
        raise "Ambient Context host did not acknowledge #{action}" if Time.instant >= deadline
        sleep 100.milliseconds
      end
      human = expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
        .bool("HumanActivityDetected")
      sound = expect_success(device.read("ambientcontextsensing", "audio-context-detected", endpoint))
        .bool("AudioContextDetected")
      human.should eq(action == "walking-human-sound")
      sound.should eq(action == "barking-human-sound")
    end

    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, endpoint.to_s]))
    started.output.should contain("AmbientContextDetected")
    started.output.should_not contain("ObjectCountThresholdReached")
    started.output.should_not contain("ObjectCount:")
    expect_success(device.write("ambientcontextsensing", "hold-time", 1, endpoint))
    deadline = Time.instant + 10.seconds
    loop do
      break unless expect_success(device.read("ambientcontextsensing", "audio-context-detected", endpoint))
                     .bool("AudioContextDetected")
      raise "Ambient Context HA+AUD sound detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
      .bool("HumanActivityDetected").should be_false
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, endpoint.to_s]))
    (ended.int("EventStartTime") || ended.int("EventStartTimePos")).as(Int64).should be > 0_i64
  end

  it "reads HA+AUD+PRED forecasts for both modalities and live switching without crowd fields" do
    endpoint = 14
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", endpoint).should eq(25)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", endpoint)).int_list("AttributeList")
    [0, 2, 3, 4, 8, 9, 10, 11].each { |id| attributes.should contain(id) }
    [1, 5, 6, 7].each { |id| attributes.should_not contain(id) }
    read_int(device, "ambientcontextsensing", "hold-time", "HoldTime", endpoint).should eq(60)
    expect_success(device.read("ambientcontextsensing", "ambient-context-type-supported", endpoint))
      .output.scan(/NamespaceID/).size.should eq(4)
    expect_success(device.read("ambientcontextsensing", "predicted-activity", endpoint))
      .output.should_not contain("StartTimestamp")

    ["predict-human-sound", "advance-human-sound-prediction-clock",
     "walking-human-sound-pred", "barking-human-sound-pred"].each do |action|
      File.delete(ack) if File.exists?(ack)
      nonce = "#{action}:#{Time.utc.to_unix_ms}"
      File.write("#{trigger}.tmp", nonce)
      File.rename("#{trigger}.tmp", trigger)
      deadline = Time.instant + 10.seconds
      until File.exists?(ack) && File.read(ack) == nonce
        raise "Ambient Context host did not acknowledge #{action}" if Time.instant >= deadline
        sleep 100.milliseconds
      end
      case action
      when "predict-human-sound"
        forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", endpoint)).output
        forecast.should contain("StartTimestamp")
        forecast.should contain("AmbientContextType")
        forecast.should contain("Confidence: 80")
        forecast.should contain("Confidence: 60")
        forecast.should_not contain("CrowdDetected")
        forecast.should_not contain("CrowdCount")
      when "advance-human-sound-prediction-clock"
        forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", endpoint)).output
        forecast.should_not contain("Confidence: 80")
        forecast.should contain("Confidence: 60")
      when "walking-human-sound-pred", "barking-human-sound-pred"
        human = expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
          .bool("HumanActivityDetected")
        sound = expect_success(device.read("ambientcontextsensing", "audio-context-detected", endpoint))
          .bool("AudioContextDetected")
        human.should eq(action == "walking-human-sound-pred")
        sound.should eq(action == "barking-human-sound-pred")
      end
    end

    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, endpoint.to_s]))
    started.output.should contain("AmbientContextDetected")
    started.output.should_not contain("ObjectCountThresholdReached")
    started.output.should_not contain("ObjectCount:")
    expect_success(device.write("ambientcontextsensing", "hold-time", 1, endpoint))
    deadline = Time.instant + 10.seconds
    loop do
      break unless expect_success(device.read("ambientcontextsensing", "audio-context-detected", endpoint))
                     .bool("AudioContextDetected")
      raise "Ambient Context HA+AUD+PRED sound detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
      .bool("HumanActivityDetected").should be_false
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, endpoint.to_s]))
    (ended.int("EventStartTime") || ended.int("EventStartTimePos")).as(Int64).should be > 0_i64
  end

  it "reads HA+OI+PRED forecasts from both modalities and live switching without crowd fields" do
    endpoint = 12
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", endpoint).should eq(21)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", endpoint)).int_list("AttributeList")
    [0, 1, 3, 4, 8, 9, 10, 11].each { |id| attributes.should contain(id) }
    [2, 5, 6, 7].each { |id| attributes.should_not contain(id) }
    read_int(device, "ambientcontextsensing", "hold-time", "HoldTime", endpoint).should eq(60)
    expect_success(device.read("ambientcontextsensing", "ambient-context-type-supported", endpoint))
      .output.scan(/NamespaceID/).size.should eq(4)
    expect_success(device.read("ambientcontextsensing", "predicted-activity", endpoint))
      .output.should_not contain("StartTimestamp")

    ["predict-human-object", "advance-human-object-prediction-clock",
     "walking-mixed-pred", "person-present-mixed-pred"].each do |action|
      File.delete(ack) if File.exists?(ack)
      nonce = "#{action}:#{Time.utc.to_unix_ms}"
      File.write("#{trigger}.tmp", nonce)
      File.rename("#{trigger}.tmp", trigger)
      deadline = Time.instant + 10.seconds
      until File.exists?(ack) && File.read(ack) == nonce
        raise "Ambient Context host did not acknowledge #{action}" if Time.instant >= deadline
        sleep 100.milliseconds
      end
      case action
      when "predict-human-object"
        forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", endpoint)).output
        forecast.should contain("StartTimestamp")
        forecast.should contain("AmbientContextType")
        forecast.should contain("Confidence: 80")
        forecast.should contain("Confidence: 60")
        forecast.should_not contain("CrowdDetected")
        forecast.should_not contain("CrowdCount")
      when "advance-human-object-prediction-clock"
        forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", endpoint)).output
        forecast.should_not contain("Confidence: 80")
        forecast.should contain("Confidence: 60")
      when "walking-mixed-pred", "person-present-mixed-pred"
        human = expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
          .bool("HumanActivityDetected")
        object = expect_success(device.read("ambientcontextsensing", "object-identified", endpoint))
          .bool("ObjectIdentified")
        human.should eq(action == "walking-mixed-pred")
        object.should eq(action == "person-present-mixed-pred")
      end
    end

    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, endpoint.to_s]))
    started.output.should contain("AmbientContextDetected")
    started.output.should_not contain("ObjectCountThresholdReached")
    started.output.should_not contain("ObjectCount:")
    expect_success(device.write("ambientcontextsensing", "hold-time", 1, endpoint))
    deadline = Time.instant + 10.seconds
    loop do
      break unless expect_success(device.read("ambientcontextsensing", "object-identified", endpoint))
                     .bool("ObjectIdentified")
      raise "Ambient Context HA+OI+PRED object detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
      .bool("HumanActivityDetected").should be_false
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, endpoint.to_s]))
    (ended.int("EventStartTime") || ended.int("EventStartTimePos")).as(Int64).should be > 0_i64
  end

  it "switches a combined HA+OI detection between independent human and object flags" do
    endpoint = 11
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", endpoint).should eq(5)
    read_int(device, "ambientcontextsensing", "hold-time", "HoldTime", endpoint).should eq(60)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", endpoint)).int_list("AttributeList")
    [0, 1, 3, 4, 8, 9, 10].each { |id| attributes.should contain(id) }
    [2, 5, 6, 7, 11].each { |id| attributes.should_not contain(id) }
    expect_success(device.read("ambientcontextsensing", "ambient-context-type-supported", endpoint))
      .output.scan(/NamespaceID/).size.should eq(4)
    expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
      .bool("HumanActivityDetected").should be_false
    expect_success(device.read("ambientcontextsensing", "object-identified", endpoint))
      .bool("ObjectIdentified").should be_false

    ["walking-mixed", "person-present-mixed"].each do |action|
      File.delete(ack) if File.exists?(ack)
      nonce = "#{action}:#{Time.utc.to_unix_ms}"
      File.write("#{trigger}.tmp", nonce)
      File.rename("#{trigger}.tmp", trigger)
      deadline = Time.instant + 10.seconds
      until File.exists?(ack) && File.read(ack) == nonce
        raise "Ambient Context host did not acknowledge #{action}" if Time.instant >= deadline
        sleep 100.milliseconds
      end
      human = expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
        .bool("HumanActivityDetected")
      object = expect_success(device.read("ambientcontextsensing", "object-identified", endpoint))
        .bool("ObjectIdentified")
      human.should eq(action == "walking-mixed")
      object.should eq(action == "person-present-mixed")
    end

    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, endpoint.to_s]))
    started.output.should contain("AmbientContextDetected")
    started.output.should_not contain("ObjectCountThresholdReached")
    started.output.should_not contain("ObjectCount:")
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, endpoint.to_s]))
    (ended.int("EventStartTime") || ended.int("EventStartTimePos")).as(Int64).should be > 0_i64

    expect_success(device.write("ambientcontextsensing", "hold-time", 1, endpoint))
    deadline = Time.instant + 10.seconds
    loop do
      break unless expect_success(device.read("ambientcontextsensing", "object-identified", endpoint))
                     .bool("ObjectIdentified")
      raise "Ambient Context mixed object detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    expect_success(device.read("ambientcontextsensing", "human-activity-detected", endpoint))
      .bool("HumanActivityDetected").should be_false
  end

  it "advertises standalone OC with only universal attributes and no count or detection surface" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 10).should eq(2)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", 10)).int_list("AttributeList")
    [8, 9, 10].each { |id| attributes.should contain(id) }
    [0, 1, 2, 3, 4, 5, 6, 7, 11].each { |id| attributes.should_not contain(id) }
    read_int(device, "ambientcontextsensing", "simultaneous-detection-limit", "SimultaneousDetectionLimit", 10)
      .should eq(1)
    expect_failure(device.read("ambientcontextsensing", "object-count", 10), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.read("ambientcontextsensing", "object-identified", 10), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.read("ambientcontextsensing", "predicted-activity", 10), "UNSUPPORTED_ATTRIBUTE")
    expect_success(device.write("ambientcontextsensing", "hold-time", 1, 10))
    read_int(device, "ambientcontextsensing", "hold-time", "HoldTime", 10).should eq(1)
  end

  it "reads OC+OI+PRED identity and crowd forecasts with live count events and expiry" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 9).should eq(22)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", 9)).int_list("AttributeList")
    [1, 3, 4, 5, 6, 7, 8, 9, 10, 11].each { |id| attributes.should contain(id) }
    [0, 2].each { |id| attributes.should_not contain(id) }
    expect_success(device.read("ambientcontextsensing", "object-count-config", 9))
      .output.should contain("ObjectCountThreshold: 2")
    expect_success(device.read("ambientcontextsensing", "object-identified", 9))
      .bool("ObjectIdentified").should be_false
    expect_success(device.read("ambientcontextsensing", "object-count-threshold-reached", 9))
      .bool("ObjectCountThresholdReached").should be_false
    expect_success(device.read("ambientcontextsensing", "predicted-activity", 9))
      .output.should_not contain("StartTimestamp")

    File.delete(ack) if File.exists?(ack)
    nonce = "predict-counted-person:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not publish counted object prediction" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", 9))
    forecast.output.should contain("StartTimestamp")
    forecast.output.should contain("EndTimestamp")
    forecast.output.should contain("AmbientContextType")
    forecast.output.should contain("Tag: 3")
    forecast.output.should contain("CrowdDetected")
    forecast.output.should contain("CrowdCount: 12")
    forecast.output.should contain("Confidence: 80")
    forecast.output.should contain("Confidence: 60")

    File.delete(ack)
    nonce = "advance-counted-object-prediction-clock:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not advance counted object prediction clock" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    remaining = expect_success(device.read("ambientcontextsensing", "predicted-activity", 9))
    remaining.output.should_not contain("CrowdCount")
    remaining.output.should_not contain("Confidence: 80")
    remaining.output.should contain("Confidence: 60")

    File.delete(ack)
    nonce = "person-count-pred:2:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not report counted object" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    expect_success(device.read("ambientcontextsensing", "object-identified", 9))
      .bool("ObjectIdentified").should be_true
    expect_success(device.read("ambientcontextsensing", "object-count-threshold-reached", 9))
      .bool("ObjectCountThresholdReached").should be_true
    read_int(device, "ambientcontextsensing", "object-count", "ObjectCount", 9).should eq(2)
    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, "9"]))
    started.output.should contain("Tag: 3")
    started.output.should contain("ObjectCountThresholdReached")
    started.output.should contain("ObjectCount: 2")

    expect_success(device.write("ambientcontextsensing", "hold-time", 1, 9))
    deadline = Time.instant + 10.seconds
    loop do
      break if expect_success(device.read("ambientcontextsensing", "object-identified", 9))
                 .bool("ObjectIdentified") == false
      raise "Ambient Context counted object detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, "9"]))
    (ended.int("EventStartTime") || ended.int("EventStartTimePos")).as(Int64).should be > 0_i64
  end

  it "reads OI+PRED tagged object forecasts, presence events, and expiry without count fields" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 8).should eq(20)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", 8)).int_list("AttributeList")
    [1, 3, 4, 8, 9, 10, 11].each { |id| attributes.should contain(id) }
    [0, 2, 5, 6, 7].each { |id| attributes.should_not contain(id) }
    expect_failure(device.read("ambientcontextsensing", "object-count", 8), "UNSUPPORTED_ATTRIBUTE")
    expect_success(device.read("ambientcontextsensing", "object-identified", 8))
      .bool("ObjectIdentified").should be_false
    supported = expect_success(device.read("ambientcontextsensing", "ambient-context-type-supported", 8))
    supported.output.should contain("Tag: 3")
    expect_success(device.read("ambientcontextsensing", "predicted-activity", 8))
      .output.should_not contain("StartTimestamp")

    File.delete(ack) if File.exists?(ack)
    nonce = "predict-person:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not publish object prediction" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", 8))
    forecast.output.should contain("StartTimestamp")
    forecast.output.should contain("EndTimestamp")
    forecast.output.should contain("AmbientContextType")
    forecast.output.should contain("Tag: 3")
    forecast.output.should contain("Confidence: 80")
    forecast.output.should contain("Confidence: 60")
    forecast.output.should_not contain("CrowdDetected")
    forecast.output.should_not contain("CrowdCount")

    File.delete(ack)
    nonce = "advance-object-prediction-clock:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not advance object prediction clock" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    remaining = expect_success(device.read("ambientcontextsensing", "predicted-activity", 8))
    remaining.output.should_not contain("Confidence: 80")
    remaining.output.should contain("Confidence: 60")

    File.delete(ack)
    nonce = "person-present-pred:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not classify object on predicted endpoint" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    expect_success(device.read("ambientcontextsensing", "object-identified", 8))
      .bool("ObjectIdentified").should be_true
    expect_success(device.read("ambientcontextsensing", "ambient-context-type", 8))
      .output.should contain("Tag: 3")
    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, "8"]))
    started.output.should contain("Tag: 3")
    started.output.should_not contain("ObjectCountThresholdReached")
    started.output.should_not contain("ObjectCount:")

    expect_success(device.write("ambientcontextsensing", "hold-time", 1, 8))
    deadline = Time.instant + 10.seconds
    loop do
      break if expect_success(device.read("ambientcontextsensing", "object-identified", 8))
                 .bool("ObjectIdentified") == false
      raise "Ambient Context object detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, "8"]))
    (ended.int("EventStartTime") || ended.int("EventStartTimePos")).as(Int64).should be > 0_i64
  end

  it "reads OC+PRED crowd-only forecasts and prunes them on clock advance" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 7).should eq(18)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", 7)).int_list("AttributeList")
    [8, 9, 10, 11].each { |id| attributes.should contain(id) }
    [0, 1, 2, 3, 4, 5, 6, 7].each { |id| attributes.should_not contain(id) }
    expect_failure(device.read("ambientcontextsensing", "object-count", 7), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.read("ambientcontextsensing", "ambient-context-type", 7), "UNSUPPORTED_ATTRIBUTE")
    initial = expect_success(device.read("ambientcontextsensing", "predicted-activity", 7))
    initial.output.should_not contain("StartTimestamp")

    File.delete(ack) if File.exists?(ack)
    nonce = "predict-crowd:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not publish crowd prediction" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    forecast = expect_success(device.read("ambientcontextsensing", "predicted-activity", 7))
    forecast.output.should contain("StartTimestamp")
    forecast.output.should contain("EndTimestamp")
    forecast.output.should contain("CrowdDetected")
    forecast.output.should contain("CrowdCount: 12")
    forecast.output.should contain("Confidence: 80")
    forecast.output.should contain("Confidence: 60")
    forecast.output.should_not contain("AmbientContextType")

    File.delete(ack)
    nonce = "advance-crowd-prediction-clock:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not advance crowd prediction clock" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    remaining = expect_success(device.read("ambientcontextsensing", "predicted-activity", 7))
    remaining.output.should_not contain("CrowdCount")
    remaining.output.should_not contain("Confidence: 80")
    remaining.output.should contain("Confidence: 60")
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

  it "advertises standalone OI without count fields and reports presence and expiry" do
    read_int(device, "ambientcontextsensing", "feature-map", "FeatureMap", 6).should eq(4)
    attributes = expect_success(device.read("ambientcontextsensing", "attribute-list", 6)).int_list("AttributeList")
    [1, 3, 4, 8, 9, 10].each { |id| attributes.should contain(id) }
    [0, 2, 5, 6, 7, 11].each { |id| attributes.should_not contain(id) }
    expect_success(device.read("ambientcontextsensing", "object-identified", 6))
      .bool("ObjectIdentified").should be_false
    expect_failure(device.read("ambientcontextsensing", "object-count", 6), "UNSUPPORTED_ATTRIBUTE")

    File.delete(ack) if File.exists?(ack)
    nonce = "person-present:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", nonce)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack) == nonce
      raise "Ambient Context host did not acknowledge object presence" if Time.instant >= deadline
      sleep 100.milliseconds
    end

    expect_success(device.read("ambientcontextsensing", "object-identified", 6))
      .bool("ObjectIdentified").should be_true
    expect_success(device.read("ambientcontextsensing", "ambient-context-type", 6)).output.should contain("Tag: 3")
    started = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-started", device.node, "6"]))
    started.output.should contain("AmbientContextDetected")
    started.output.should contain("Tag: 3")
    started.output.should_not contain("ObjectCountThresholdReached")
    started.output.should_not contain("ObjectCount:")

    expect_success(device.write("ambientcontextsensing", "hold-time", 1, 6))
    deadline = Time.instant + 10.seconds
    loop do
      break if expect_success(device.read("ambientcontextsensing", "object-identified", 6))
                 .bool("ObjectIdentified") == false
      raise "Ambient Context object detection did not expire" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    ended = expect_success(device.chip(
      ["ambientcontextsensing", "read-event", "ambient-context-detect-ended", device.node, "6"]))
    start_time = ended.int("EventStartTime") || ended.int("EventStartTimePos")
    start_time.as(Int64).should be > 0_i64
    expect_success(device.read("ambientcontextsensing", "ambient-context-type", 6)).output.should contain("Tag: 0")
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
