require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"
require "tlv"
require "../support/network_commissioning_failsafe"

private class EmptyScanBackend < Matter::Network::TestBackend
  def scan_wifi(ssid : String?) : Array(Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult)
    [] of Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult
  end

  def scan_thread : Array(Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult)
    [] of Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult
  end
end

describe Matter::Cluster::NetworkCommissioning do
  # Matter 1.6 NetworkCommissioningCluster.xml: ScanNetworksResponse's
  # WiFiScanResults (tag 2) is mandatory for WI, and ThreadScanResults (tag 3)
  # is mandatory for TH, even when a successful scan finds no networks.
  it "encodes an empty Wi-Fi result list for a WI-only scan" do
    cluster = build(Matter::Cluster::NetworkCommissioning,
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
      backend: EmptyScanBackend.new)
    arm_network_commissioning(cluster)
    request = Matter::Cluster::NetworkCommissioning::Tlv::ScanAvailableNetworksRequest.new.to_tlv(nil)

    result = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_SCAN_NETWORKS, request)
    result.should be_a(Matter::Cluster::CommandResponse)
    wire = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
    fields = wire.value.as(TLV::Structure)
    fields.has_key?(2_u8).should be_true
    fields.has_key?(3_u8).should be_false
    decoded = Matter::Cluster::NetworkCommissioning::Tlv::ScanNetworksResponse.from_tlv(wire)
    decoded.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::Success)
    decoded.wifi_scan_results.should eq([] of Matter::Cluster::NetworkCommissioning::Tlv::WiFiInterfaceScanResult)
  end

  it "encodes an empty Thread result list for a TH-only scan" do
    cluster = build(Matter::Cluster::NetworkCommissioning,
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::Thread,
      backend: EmptyScanBackend.new)
    arm_network_commissioning(cluster)
    request = Matter::Cluster::NetworkCommissioning::Tlv::ScanAvailableNetworksRequest.new.to_tlv(nil)

    result = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_SCAN_NETWORKS, request)
    result.should be_a(Matter::Cluster::CommandResponse)
    wire = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
    fields = wire.value.as(TLV::Structure)
    fields.has_key?(2_u8).should be_false
    fields.has_key?(3_u8).should be_true
    decoded = Matter::Cluster::NetworkCommissioning::Tlv::ScanNetworksResponse.from_tlv(wire)
    decoded.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::Success)
    decoded.thread_scan_results.should eq([] of Matter::Cluster::NetworkCommissioning::Tlv::ThreadInterfaceScanResult)
  end

  it "keeps the WI-required list present when the scan backend is unavailable" do
    cluster = build(Matter::Cluster::NetworkCommissioning,
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi)
    arm_network_commissioning(cluster)
    request = Matter::Cluster::NetworkCommissioning::Tlv::ScanAvailableNetworksRequest.new.to_tlv(nil)

    result = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_SCAN_NETWORKS, request)
    result.should be_a(Matter::Cluster::CommandResponse)
    wire = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
    fields = wire.value.as(TLV::Structure)
    fields.has_key?(2_u8).should be_true
    fields.has_key?(3_u8).should be_false
    decoded = Matter::Cluster::NetworkCommissioning::Tlv::ScanNetworksResponse.from_tlv(wire)
    decoded.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::UnknownError)
    decoded.wifi_scan_results.should eq([] of Matter::Cluster::NetworkCommissioning::Tlv::WiFiInterfaceScanResult)
  end
end
