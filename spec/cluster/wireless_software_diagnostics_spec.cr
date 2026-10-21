require "../spec_helper"

describe "Matter 1.6 node diagnostics" do
  it "reports nullable Wi-Fi link fields and validates observed link data" do
    cluster = build(Matter::Cluster::WiFiNetworkDiagnostics)
    cluster.cluster_id.id.should eq(0x0036_u32)
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_BSSID).should be_nil
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_RSSI).should be_nil

    expect_raises(ArgumentError, /six bytes/) do
      cluster.update_link(Bytes[1, 2, 3],
        Matter::Cluster::WiFiNetworkDiagnostics::SecurityType::Wpa2,
        Matter::Cluster::WiFiNetworkDiagnostics::WiFiVersion::N, 6_u16, -60_i8)
    end
    cluster.update_link(Bytes[1, 2, 3, 4, 5, 6],
      Matter::Cluster::WiFiNetworkDiagnostics::SecurityType::Wpa2,
      Matter::Cluster::WiFiNetworkDiagnostics::WiFiVersion::N, 6_u16, -60_i8)
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_RSSI).should eq(-60_i8)
    expect_raises(ArgumentError, /RSSI/) do
      cluster.update_link(Bytes[1, 2, 3, 4, 5, 6],
        Matter::Cluster::WiFiNetworkDiagnostics::SecurityType::Wpa2,
        Matter::Cluster::WiFiNetworkDiagnostics::WiFiVersion::N, 6_u16, -121_i8)
    end
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_RSSI).should eq(-60_i8)
  end

  it "gates Wi-Fi counters and resets only when the error-count feature is enabled" do
    plain = build(Matter::Cluster::WiFiNetworkDiagnostics)
    read_status(plain, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_BEACON_LOST_COUNT).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    expect_status(invoke(plain, Matter::Cluster::WiFiNetworkDiagnostics::CMD_RESET_COUNTS),
      Matter::InteractionModel::StatusCode::UnsupportedCommand)

    cluster = build(Matter::Cluster::WiFiNetworkDiagnostics,
      feature_map: Matter::Cluster::WiFiNetworkDiagnostics::Feature::PacketCounts |
                   Matter::Cluster::WiFiNetworkDiagnostics::Feature::ErrorCounts)
    cluster.record_beacon_loss
    cluster.record_beacon_rx
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_BEACON_LOST_COUNT).should eq(1_u32)
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_BEACON_RX_COUNT).should eq(1_u32)
    expect_success(invoke(cluster, Matter::Cluster::WiFiNetworkDiagnostics::CMD_RESET_COUNTS))
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_BEACON_LOST_COUNT).should eq(0_u32)
    read(cluster, Matter::Cluster::WiFiNetworkDiagnostics::ATTR_BEACON_RX_COUNT).should eq(0_u32)
  end

  it "gates software heap watermarks and resets the high watermark" do
    plain = build(Matter::Cluster::SoftwareDiagnostics)
    plain.cluster_id.id.should eq(0x0034_u32)
    read_status(plain, Matter::Cluster::SoftwareDiagnostics::ATTR_CURRENT_HEAP_HIGH_WATERMARK).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    expect_status(invoke(plain, Matter::Cluster::SoftwareDiagnostics::CMD_RESET_WATERMARKS),
      Matter::InteractionModel::StatusCode::UnsupportedCommand)

    cluster = build(Matter::Cluster::SoftwareDiagnostics,
      feature_map: Matter::Cluster::SoftwareDiagnostics::Feature::Watermarks)
    cluster.update_heap(100_u64, 200_u64)
    cluster.update_heap(50_u64, 250_u64)
    read(cluster, Matter::Cluster::SoftwareDiagnostics::ATTR_CURRENT_HEAP_HIGH_WATERMARK).should eq(250_u64)
    expect_success(invoke(cluster, Matter::Cluster::SoftwareDiagnostics::CMD_RESET_WATERMARKS))
    read(cluster, Matter::Cluster::SoftwareDiagnostics::ATTR_CURRENT_HEAP_HIGH_WATERMARK).should eq(250_u64)
    cluster.update_heap(80_u64, 220_u64)
    read(cluster, Matter::Cluster::SoftwareDiagnostics::ATTR_CURRENT_HEAP_HIGH_WATERMARK).should eq(250_u64)
    expect_raises(ArgumentError, /64 entries/) do
      cluster.update_thread_metrics((0_u64..64_u64).map do |id|
        Matter::Cluster::SoftwareDiagnostics::ThreadMetricsStruct.new(id)
      end)
    end
    expect_raises(ArgumentError, /1024 bytes/) do
      cluster.emit_software_fault(1_u64, fault_recording: Bytes.new(1025))
    end
  end
end
