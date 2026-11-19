require "../spec_helper"

private DOORBELL_DEVICE_TYPE_ID = 0x0148_u32
private DOORBELL_ENDPOINT       = Matter::DataType::EndpointNumber.new(1_u16)

private def doorbell_endpoint(feature : Matter::Cluster::Switch::Feature,
                              chime_client : Bool = true) : Matter::Endpoint
  endpoint = Matter::Endpoint.new(DOORBELL_ENDPOINT, Matter::DeviceType.for(DOORBELL_DEVICE_TYPE_ID))
  endpoint.add_cluster(Matter::Cluster::Descriptor.new(DOORBELL_ENDPOINT))
  endpoint.add_cluster(Matter::Cluster::Identify.new(DOORBELL_ENDPOINT))
  endpoint.add_cluster(Matter::Cluster::Switch.new(DOORBELL_ENDPOINT, feature_map: feature))
  endpoint.add_client_cluster(Matter::Cluster::Chime::CLUSTER_ID) if chime_client
  endpoint
end

describe "Matter 1.6 standalone Doorbell device composition" do
  it "requires revision two, Identify and momentary Switch servers, and a Chime client" do
    doorbell = Matter::DeviceType.for(DOORBELL_DEVICE_TYPE_ID)

    doorbell.name.should eq("Doorbell")
    doorbell.revision.should eq(2_u16)
    doorbell.required_server_clusters.should contain(Matter::Cluster::Identify::CLUSTER_ID)
    doorbell.required_server_clusters.should contain(Matter::Cluster::Switch::CLUSTER_ID)
    doorbell.required_client_clusters.should contain(Matter::Cluster::Chime::CLUSTER_ID)
    doorbell.required_server_features[Matter::Cluster::Switch::CLUSTER_ID].should eq(
      Matter::Cluster::Switch::Feature::MomentarySwitch.value)
  end

  it "accepts the mandatory momentary profile" do
    doorbell_endpoint(Matter::Cluster::Switch::Feature::MomentarySwitch).validate.should be_empty
  end

  it "rejects a latching Switch and a missing Chime client" do
    latching = doorbell_endpoint(Matter::Cluster::Switch::Feature::LatchingSwitch)
    latching.validate.join.should contain("Missing required feature")

    missing_chime = doorbell_endpoint(Matter::Cluster::Switch::Feature::MomentarySwitch,
      chime_client: false)
    missing_chime.validate.join.should contain("Missing required client cluster")
  end
end
