require "../spec_helper"

private class ThreadDiagnosticsDevice < Matter::Device
  identity vendor: "Crystal", product: "Thread Diagnostics",
    vendor_id: 0xFFF1_u16, product_id: 0x0035_u16,
    discriminator: 3840_u16, pin: 20202021_u32,
    device_type: Matter::DeviceType::ROOT_NODE

  storage :memory
  network :thread
end

describe Matter::Cluster::ThreadNetworkDiagnostics do
  it "advertises the mandatory Thread root cluster and nullable link state" do
    device = ThreadDiagnosticsDevice.new(port: 0)
    cluster = device.node.get_cluster!(Matter::Node::ROOT_ENDPOINT_ID,
      Matter::Cluster::ThreadNetworkDiagnostics)
    cluster.cluster_id.id.should eq(0x0035_u32)
    cluster.cluster_revision.should eq(3_u16)
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_CHANNEL).should be_nil
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_NEIGHBOR_TABLE)
      .should eq([] of Matter::Cluster::ThreadNetworkDiagnostics::NeighborTableStruct)
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_ACTIVE_NETWORK_FAULTS_LIST)
      .should eq([] of Matter::Cluster::ThreadNetworkDiagnostics::NetworkFault)
  end

  it "validates Thread identity and link data before publishing it" do
    cluster = build(Matter::Cluster::ThreadNetworkDiagnostics)
    expect_raises(ArgumentError, /network name/) do
      cluster.update_network_name("a" * 17)
    end
    expect_raises(ArgumentError, /mesh-local prefix/) do
      cluster.update_mesh_local_prefix(Bytes.new(18))
    end
    expect_raises(ArgumentError, /channel mask/) do
      cluster.update_channel_page0_mask(Bytes.new(3))
    end
    cluster.update_network_name("Thread Lab")
    cluster.update_channel_page0_mask(Bytes[0, 0, 0, 1])
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_NETWORK_NAME).should eq("Thread Lab")
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_CHANNEL_PAGE0_MASK).should eq(Bytes[0, 0, 0, 1])
  end

  it "gates optional counters by feature and resets their values" do
    plain = build(Matter::Cluster::ThreadNetworkDiagnostics)
    read_status(plain, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_OVERRUN_COUNT).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    expect_status(invoke(plain, Matter::Cluster::ThreadNetworkDiagnostics::CMD_RESET_COUNTS),
      Matter::InteractionModel::StatusCode::UnsupportedCommand)

    cluster = build(Matter::Cluster::ThreadNetworkDiagnostics,
      feature_map: Matter::Cluster::ThreadNetworkDiagnostics::Feature::ErrorCounts |
                   Matter::Cluster::ThreadNetworkDiagnostics::Feature::MleCounts |
                   Matter::Cluster::ThreadNetworkDiagnostics::Feature::MacCounts)
    cluster.record_overrun
    cluster.record_detached_role
    cluster.record_tx_total
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_OVERRUN_COUNT).should eq(1_u64)
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_DETACHED_ROLE_COUNT).should eq(1_u16)
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_TX_TOTAL_COUNT).should eq(1_u32)
    expect_success(invoke(cluster, Matter::Cluster::ThreadNetworkDiagnostics::CMD_RESET_COUNTS))
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_OVERRUN_COUNT).should eq(0_u64)
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_DETACHED_ROLE_COUNT).should eq(0_u16)
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_TX_TOTAL_COUNT).should eq(0_u32)
  end

  it "bounds active faults and emits typed network events" do
    cluster = build(Matter::Cluster::ThreadNetworkDiagnostics)
    faults = Array.new(5, Matter::Cluster::ThreadNetworkDiagnostics::NetworkFault::LinkDown)
    expect_raises(ArgumentError, /four/) { cluster.update_active_network_faults(faults) }
    cluster.update_active_network_faults([Matter::Cluster::ThreadNetworkDiagnostics::NetworkFault::LinkDown])
    cluster.active_network_faults_list.should eq([Matter::Cluster::ThreadNetworkDiagnostics::NetworkFault::LinkDown])
    read(cluster, Matter::Cluster::ThreadNetworkDiagnostics::ATTR_ACTIVE_NETWORK_FAULTS_LIST)
      .as(Array(TLV::Any)).map(&.value).should eq([1_u8])
    cluster.emit_connection_status(Matter::Cluster::ThreadNetworkDiagnostics::ConnectionStatus::Connected)
    cluster.emit_network_fault_change([] of Matter::Cluster::ThreadNetworkDiagnostics::NetworkFault,
      [Matter::Cluster::ThreadNetworkDiagnostics::NetworkFault::LinkDown])
  end
end
