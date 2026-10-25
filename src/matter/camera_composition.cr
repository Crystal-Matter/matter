require "./node"
require "./cluster/camera_av_stream_management"
require "./cluster/web_rtc_transport_provider"
require "./cluster/time_synchronization"
require "./cluster/tls_certificate_management"
require "./cluster/tls_client_management"
require "./cluster/power_source"
require "./cluster/zone_management"

module Matter
  # Structural requirements for a Matter 1.6 Camera endpoint. This does not
  # prove host media delivery or device-to-device interoperability.
  module CameraComposition
    REQUESTOR_CLUSTER_ID    = 0x0554_u32
    TIME_SYNC_CLUSTER_ID    = Cluster::TimeSynchronization::CLUSTER_ID
    POWER_SOURCE_CLUSTER_ID = Cluster::PowerSource::CLUSTER_ID
    TIME_ZONE_BIT           = 0x01_u32
    NTP_CLIENT_BIT          = 0x02_u32
    TIME_SYNC_CLIENT_BIT    = 0x08_u32

    def self.validate(node : Node, camera_endpoint_id : UInt16) : Array(String)
      errors = [] of String
      camera = node.endpoint(camera_endpoint_id)
      unless camera
        return ["Camera endpoint #{camera_endpoint_id} is absent"]
      end

      av = camera.get_cluster(Cluster::CameraAvStreamManagement)
      if av
        features = av.feature_map
        errors << "Camera AV Stream Management needs Audio" unless features.audio?
        errors << "Camera AV Stream Management needs Video" unless features.video?
        errors << "Camera AV Stream Management needs Snapshot" unless features.snapshot?
      else
        errors << "Camera AV Stream Management server is absent"
      end
      unless camera.get_cluster(Cluster::WebRtcTransportProvider)
        errors << "WebRTC Transport Provider server is absent"
      end
      unless camera.descriptor.has_client_cluster?(REQUESTOR_CLUSTER_ID)
        errors << "WebRTC Transport Requestor client is absent"
      end
      if zone = camera.get_cluster(Cluster::ZoneManagement)
        unless zone.feature_map.two_d_cartesian_zone?
          errors << "Zone Management needs TWODCART"
        end
      end

      root = node.endpoint(Node::ROOT_ENDPOINT_ID)
      unless root
        errors << "Root Node endpoint is absent"
        return errors
      end
      unless root.device_types.any? { |type| type.device_type_id.id == DeviceType::ROOT_NODE }
        errors << "Root Node device type is absent on Root Node endpoint"
      end
      unless root.device_types.any? { |type| type.device_type_id.id == DeviceType::POWER_SOURCE } &&
             root.has_cluster?(POWER_SOURCE_CLUSTER_ID)
        errors << "Power Source device type and server must be on Root Node"
      end
      unless root.get_cluster(Cluster::TlsCertificateManagement)
        errors << "TLS Certificate Management server is absent on Root Node"
      end
      unless root.get_cluster(Cluster::TlsClientManagement)
        errors << "TLS Client Management server is absent on Root Node"
      end
      time_sync = root.get_cluster(Cluster::TimeSynchronization)
      if time_sync
        features = time_sync.feature_map.value.to_u32
        errors << "Time Synchronization TimeZone feature is absent" if features & TIME_ZONE_BIT == 0
        errors << "Time Synchronization NTPClient feature is absent" if features & NTP_CLIENT_BIT == 0
        errors << "Time Synchronization TimeSyncClient feature is absent" if features & TIME_SYNC_CLIENT_BIT == 0
      else
        errors << "Time Synchronization server is absent on Root Node"
      end
      unless root.descriptor.has_client_cluster?(TIME_SYNC_CLUSTER_ID)
        errors << "Time Synchronization client is absent on Root Node"
      end
      errors
    end
  end
end
