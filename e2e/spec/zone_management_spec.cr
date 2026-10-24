require "./e2e_helper"

private ZONE_CLUSTER   = "zonemanagement"
private ZONE_ENDPOINT  = 1
private MOTION_ZONE    = %({"name":"Door","use":0,"vertices":[{"x":0,"y":0},{"x":100,"y":0},{"x":100,"y":100},{"x":0,"y":100}],"color":"#00FFFF"})
private UPDATED_ZONE   = %({"name":"Porch","use":0,"vertices":[{"x":0,"y":0},{"x":80,"y":0},{"x":80,"y":80},{"x":0,"y":80}]})
private MOTION_TRIGGER = %({"zoneID":0,"initialDuration":2,"augmentationDuration":1,"maxDuration":4,"blindDuration":1})

describe "Matter 1.6 Zone Management interoperability" do
  device = E2E::Device["matter_zone_management"]

  it "commissions and exposes the Cartesian user-zone profile" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", ZONE_ENDPOINT)).int_list("ServerList").should contain(0x0550_i64)
    read_int(device, ZONE_CLUSTER, "cluster-revision", "ClusterRevision", ZONE_ENDPOINT).should eq(1_i64)
    read_int(device, ZONE_CLUSTER, "feature-map", "FeatureMap", ZONE_ENDPOINT).should eq(5_i64)
    read_int(device, ZONE_CLUSTER, "max-user-defined-zones", "MaxUserDefinedZones", ZONE_ENDPOINT).should eq(5_i64)
    read_int(device, ZONE_CLUSTER, "sensitivity", "Sensitivity", ZONE_ENDPOINT).should eq(3_i64)
    expect_failure(device.write(ZONE_CLUSTER, "sensitivity", 6, ZONE_ENDPOINT), "CONSTRAINT_ERROR")
    expect_success(device.write(ZONE_CLUSTER, "sensitivity", 4, ZONE_ENDPOINT))
  end

  it "creates a zone and trigger, reads events, updates geometry, and restores them" do
    created = expect_success(device.invoke(ZONE_CLUSTER, "create-two-dcartesian-zone", [MOTION_ZONE], endpoint: ZONE_ENDPOINT))
    created.output.should contain("zoneID: 0")
    zones = expect_success(device.read(ZONE_CLUSTER, "zones", ZONE_ENDPOINT)).output
    zones.should contain("Door")
    expect_success(device.invoke(ZONE_CLUSTER, "create-or-update-trigger", [MOTION_TRIGGER], endpoint: ZONE_ENDPOINT))
    expect_success(device.read(ZONE_CLUSTER, "triggers", ZONE_ENDPOINT)).output.should contain("InitialDuration")

    deadline = Time.monotonic + 10.seconds
    loop do
      event = device.chip([ZONE_CLUSTER, "read-event", "zone-triggered", device.node, ZONE_ENDPOINT.to_s])
      break if event.success? && event.output.includes?("ZoneTriggered")
      if Time.monotonic >= deadline
        relevant = event.output.lines.select { |line| line.includes?("Zone") || line.includes?("Reason") || line.includes?("reason") }
        raise "ZoneTriggered was not reported: #{relevant.join}"
      end
      sleep 250.milliseconds
    end
    deadline = Time.monotonic + 10.seconds
    loop do
      event = device.chip([ZONE_CLUSTER, "read-event", "zone-stopped", device.node, ZONE_ENDPOINT.to_s])
      break if event.success? && event.output.includes?("ZoneStopped")
      if Time.monotonic >= deadline
        relevant = event.output.lines.select { |line| line.includes?("Zone") || line.includes?("Reason") || line.includes?("reason") }
        raise "ZoneStopped was not reported: #{relevant.join}"
      end
      sleep 250.milliseconds
    end
    expect_success(device.invoke(ZONE_CLUSTER, "update-two-dcartesian-zone", ["0", UPDATED_ZONE], endpoint: ZONE_ENDPOINT))
    expect_success(device.read(ZONE_CLUSTER, "zones", ZONE_ENDPOINT)).output.should contain("Porch")
    device.restart!
    expect_success(device.read(ZONE_CLUSTER, "zones", ZONE_ENDPOINT)).output.should contain("Porch")
    expect_success(device.read(ZONE_CLUSTER, "triggers", ZONE_ENDPOINT)).output.should contain("InitialDuration")
    read_int(device, ZONE_CLUSTER, "sensitivity", "Sensitivity", ZONE_ENDPOINT).should eq(4_i64)
    expect_success(device.invoke(ZONE_CLUSTER, "remove-trigger", ["0"], endpoint: ZONE_ENDPOINT))
    expect_success(device.invoke(ZONE_CLUSTER, "remove-zone", ["0"], endpoint: ZONE_ENDPOINT))
    expect_success(device.read(ZONE_CLUSTER, "zones", ZONE_ENDPOINT)).output.should_not contain("Porch")
  end
end
