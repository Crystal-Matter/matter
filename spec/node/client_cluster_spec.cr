require "../spec_helper"

private CLIENT_CLUSTER = 0x0554_u32

describe Matter::Endpoint do
  it "advertises declared client clusters separately from server clusters" do
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16))
    endpoint.add_client_cluster(CLIENT_CLUSTER)
    endpoint.add_client_cluster(CLIENT_CLUSTER)
    descriptor = endpoint.populate_descriptor
    descriptor.client_list.should eq([CLIENT_CLUSTER])
    descriptor.server_list.should_not contain(CLIENT_CLUSTER)
  end

  it "checks required client clusters for a device type" do
    type = Matter::DeviceType.new(Matter::DataType::DeviceTypeId.new(0xF000_u32),
      "Client Device", 1_u16, required_client_clusters: [CLIENT_CLUSTER])
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16), type)
    endpoint.validate.join.should contain("required client cluster")
    endpoint.add_client_cluster(CLIENT_CLUSTER)
    endpoint.validate.should be_empty
  end
end
