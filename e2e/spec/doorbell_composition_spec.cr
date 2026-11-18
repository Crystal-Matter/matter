require "./e2e_helper"

private DOORBELL_DEVICE_TYPE_ID = 0x0148_u32
private DOORBELL_ENDPOINT       =          1

describe "Matter 1.6 standalone Doorbell composition interoperability" do
  device = E2E::Device["matter_doorbell"]

  it "commissions and advertises the revision two momentary Doorbell roles" do
    device.commission!

    device_type = expect_success(device.read("descriptor", "device-type-list", DOORBELL_ENDPOINT))
    device_type.int("DeviceType").should eq(DOORBELL_DEVICE_TYPE_ID.to_i64)
    device_type.int("Revision").should eq(2_i64)

    servers = expect_success(device.read("descriptor", "server-list", DOORBELL_ENDPOINT)).int_list("ServerList")
    servers.should contain(Matter::Cluster::Identify::CLUSTER_ID.to_i64)
    servers.should contain(Matter::Cluster::Switch::CLUSTER_ID.to_i64)
    clients = expect_success(device.read("descriptor", "client-list", DOORBELL_ENDPOINT)).int_list("ClientList")
    clients.should contain(Matter::Cluster::Chime::CLUSTER_ID.to_i64)

    features = expect_success(device.read("switch", "feature-map", DOORBELL_ENDPOINT)).int("FeatureMap")
    features.should eq(Matter::Cluster::Switch::Feature::MomentarySwitch.value.to_i64)
    expect_success(device.read("switch", "cluster-revision", DOORBELL_ENDPOINT))
      .int("ClusterRevision").should eq(2_i64)
  end

  it "reports a host-originated InitialPress after commissioning" do
    deadline = Time.monotonic + 15.seconds
    loop do
      event = device.chip("switch", "read-event", "initial-press", device.node, DOORBELL_ENDPOINT.to_s)
      break if event.success? && event.output.includes?("InitialPress")
      if Time.monotonic >= deadline
        fail("InitialPress was not reported by the commissioned Doorbell: #{event.tail}")
      end
      sleep 250.milliseconds
    end
    expect_success(device.read("switch", "current-position", DOORBELL_ENDPOINT))
      .int("CurrentPosition").should eq(1_i64)
  end
end
