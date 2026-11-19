require "../spec_helper"

private CHIME_DEVICE_TYPE_ID = 0x0146_u32
private CHIME_ENDPOINT       = Matter::DataType::EndpointNumber.new(1_u16)

describe "Matter 1.6 Chime device composition" do
  it "declares revision one with the Chime server required and Identify optional" do
    chime = Matter::DeviceType.for(CHIME_DEVICE_TYPE_ID)

    chime.name.should eq("Chime")
    chime.revision.should eq(1_u16)
    chime.required_server_clusters.should contain(Matter::Cluster::Descriptor::CLUSTER_ID)
    chime.required_server_clusters.should contain(Matter::Cluster::Chime::CLUSTER_ID)
    chime.optional_server_clusters.should contain(Matter::Cluster::Identify::CLUSTER_ID)
  end

  it "rejects an endpoint without its required Chime server" do
    endpoint = Matter::Endpoint.new(CHIME_ENDPOINT, Matter::DeviceType.for(CHIME_DEVICE_TYPE_ID))
    endpoint.add_cluster(Matter::Cluster::Descriptor.new(CHIME_ENDPOINT))

    endpoint.validate.join.should contain("Missing required cluster")
  end
end
