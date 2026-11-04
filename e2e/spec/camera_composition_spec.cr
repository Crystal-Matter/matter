require "./e2e_helper"

private CAMERA_ENDPOINT_ID = 1
private ROOT_ENDPOINT_ID   = 0

describe "Matter 1.6 Camera composition on the official chip-tool wire" do
  device = E2E::Device["matter_camera_composition_probe"]

  it "commissions the test-only Camera type with mandatory endpoint and root roles" do
    device.commission!

    camera_type = expect_success(device.read("descriptor", "device-type-list", CAMERA_ENDPOINT_ID))
    camera_type.int("DeviceType").should eq(Matter::DeviceType::CAMERA.to_i64)
    camera_type.int("Revision").should eq(1_i64)
    camera_servers = expect_success(device.read("descriptor", "server-list", CAMERA_ENDPOINT_ID))
      .int_list("ServerList")
    camera_servers.should contain(Matter::Cluster::CameraAvStreamManagement::CLUSTER_ID.to_i64)
    camera_servers.should contain(Matter::Cluster::WebRtcTransportProvider::CLUSTER_ID.to_i64)
    camera_clients = expect_success(device.read("descriptor", "client-list", CAMERA_ENDPOINT_ID))
      .int_list("ClientList")
    camera_clients.should contain(Matter::Cluster::WebRtcTransportRequestor::CLUSTER_ID.to_i64)
    camera_features = read_int(device, "cameraavstreammanagement", "feature-map", "FeatureMap", CAMERA_ENDPOINT_ID)
    required_av_features = Matter::Cluster::CameraAvStreamManagement::Feature::Audio.value |
                           Matter::Cluster::CameraAvStreamManagement::Feature::Video.value |
                           Matter::Cluster::CameraAvStreamManagement::Feature::Snapshot.value
    (camera_features & required_av_features.to_i64).should eq(required_av_features.to_i64)

    root_types = expect_success(device.read("descriptor", "device-type-list", ROOT_ENDPOINT_ID))
      .ints("DeviceType")
    root_types.should contain(Matter::DeviceType::ROOT_NODE.to_i64)
    root_types.should contain(Matter::DeviceType::POWER_SOURCE.to_i64)
    root_servers = expect_success(device.read("descriptor", "server-list", ROOT_ENDPOINT_ID))
      .int_list("ServerList")
    root_servers.should contain(Matter::Cluster::PowerSource::CLUSTER_ID.to_i64)
    root_servers.should contain(Matter::Cluster::TimeSynchronization::CLUSTER_ID.to_i64)
    root_servers.should contain(Matter::Cluster::TlsCertificateManagement::CLUSTER_ID.to_i64)
    root_servers.should contain(Matter::Cluster::TlsClientManagement::CLUSTER_ID.to_i64)
    root_clients = expect_success(device.read("descriptor", "client-list", ROOT_ENDPOINT_ID))
      .int_list("ClientList")
    root_clients.should contain(Matter::Cluster::TimeSynchronization::CLUSTER_ID.to_i64)
    expect_success(device.read("powersource", "endpoint-list", ROOT_ENDPOINT_ID))
      .int_list("EndpointList").should eq([CAMERA_ENDPOINT_ID.to_i64])

    time_features = read_int(device, "timesynchronization", "feature-map", "FeatureMap", ROOT_ENDPOINT_ID)
    required_time_features = Matter::Cluster::TimeSynchronization::Feature::TimeZone.value |
                             Matter::Cluster::TimeSynchronization::Feature::NtpClient.value |
                             Matter::Cluster::TimeSynchronization::Feature::TrustedTimeClient.value
    (time_features & required_time_features.to_i64).should eq(required_time_features.to_i64)
    expect_success(device.read("timesynchronization", "default-ntp", ROOT_ENDPOINT_ID))
    expect_success(device.read("timesynchronization", "trusted-time-source", ROOT_ENDPOINT_ID))

    device.restart!
    expect_success(device.read("descriptor", "device-type-list", CAMERA_ENDPOINT_ID))
      .int("DeviceType").should eq(Matter::DeviceType::CAMERA.to_i64)
    expect_success(device.read("descriptor", "client-list", CAMERA_ENDPOINT_ID))
      .int_list("ClientList").should contain(Matter::Cluster::WebRtcTransportRequestor::CLUSTER_ID.to_i64)
  end
end
