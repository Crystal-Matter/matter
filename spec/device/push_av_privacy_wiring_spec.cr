require "../spec_helper"
require "../../src/matter/device"

private alias PushAvCamera = Matter::Cluster::CameraAvStreamManagement

private class PushAvPrivacyDevice < Matter::Device
  def initialize
    super(Matter::Storage::Memory.new, port: 0)
  end

  def device_name : String
    "Push AV privacy fixture"
  end

  def vendor_id : UInt16
    0xFFF1_u16
  end

  def product_id : UInt16
    0x8000_u16
  end

  def discriminator : UInt16
    3840_u16
  end

  def setup_pin : UInt32
    20202021_u32
  end

  def primary_device_type_id : UInt32
    Matter::DeviceType::ROOT_NODE
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    endpoint = Matter::DataType::EndpointNumber.new(1_u16)
    capabilities = PushAvCamera::AudioCapabilities.new(2_u8, [PushAvCamera::AudioCodec::Opus],
      [16_000_u32, 48_000_u32], [16_u8, 24_u8])
    [
      Matter::Cluster::TlsCertificateManagement.new,
      Matter::Cluster::TlsClientManagement.new,
      PushAvCamera.new(endpoint, capabilities, [PushAvCamera::StreamUsage::Recording, PushAvCamera::StreamUsage::LiveView],
        65_536_u32, 128_000_u32, feature_map: PushAvCamera::Feature::Audio | PushAvCamera::Feature::Privacy),
      Matter::Cluster::PushAvStreamTransport.new(endpoint),
    ] of Matter::Cluster::Base
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {1_u16 => Matter::DeviceType::AGGREGATOR}
  end
end

describe "Push AV camera privacy wiring" do
  it "tracks camera hard and soft privacy modes" do
    device = PushAvPrivacyDevice.new
    clusters = device.message_handler.clusters
    camera = clusters[{1_u16, Matter::Cluster::CameraAvStreamManagement::CLUSTER_ID}]
      .as(Matter::Cluster::CameraAvStreamManagement)
    push = clusters[{1_u16, Matter::Cluster::PushAvStreamTransport::CLUSTER_ID}]
      .as(Matter::Cluster::PushAvStreamTransport)
    allows = push.privacy_allows.as(Proc(Matter::Cluster::PushAvStreamTransport::StreamUsage, Bool))
    allows.call(Matter::Cluster::PushAvStreamTransport::StreamUsage::Recording).should be_true
    camera.hard_privacy_mode_on = true
    allows.call(Matter::Cluster::PushAvStreamTransport::StreamUsage::Recording).should be_false
    camera.hard_privacy_mode_on = false
    camera.soft_recording_privacy_mode_enabled = true
    allows.call(Matter::Cluster::PushAvStreamTransport::StreamUsage::Recording).should be_false
    allows.call(Matter::Cluster::PushAvStreamTransport::StreamUsage::LiveView).should be_true
    camera.soft_livestream_privacy_mode_enabled = true
    allows.call(Matter::Cluster::PushAvStreamTransport::StreamUsage::LiveView).should be_false
  end
end
