require "../spec_helper"

private CAMERA_CONTROLLER_DEVICE_TYPE_ID = 0x0147_u32
private CAMERA_CONTROLLER_ENDPOINT       = Matter::DataType::EndpointNumber.new(1_u16)

describe "Matter 1.6 Camera Controller device type" do
  it "declares revision 1 with Requestor server and Provider client roles" do
    controller = Matter::DeviceType.for(CAMERA_CONTROLLER_DEVICE_TYPE_ID)

    controller.name.should eq("Camera Controller")
    controller.revision.should eq(1_u16)
    controller.required_server_clusters.should contain(Matter::Cluster::WebRtcTransportRequestor::CLUSTER_ID)
    controller.required_client_clusters.should contain(Matter::Cluster::WebRtcTransportProvider::CLUSTER_ID)
  end

  it "rejects an advertised endpoint without either mandatory WebRTC role" do
    endpoint = Matter::Endpoint.new(CAMERA_CONTROLLER_ENDPOINT,
      Matter::DeviceType.for(CAMERA_CONTROLLER_DEVICE_TYPE_ID))

    errors = endpoint.validate.join
    errors.should contain("Missing required cluster")
    errors.should contain("#{Matter::Hex.u16(Matter::Cluster::WebRtcTransportRequestor::CLUSTER_ID)}")
    errors.should contain("Missing required client cluster")
    errors.should contain("#{Matter::Hex.u16(Matter::Cluster::WebRtcTransportProvider::CLUSTER_ID)}")
  end
end
