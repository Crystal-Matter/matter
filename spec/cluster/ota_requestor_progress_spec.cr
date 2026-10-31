require "../spec_helper"

private alias ProgressRequestor = Matter::Cluster::OtaRequestor

describe "OTA Requestor UpdateStateProgress" do
  it "publishes valid progress and rejects out-of-range host updates without changing state" do
    cluster = ProgressRequestor.new
    cluster.update_state_progress.should be_nil

    changes = capture_changes(cluster) { cluster.update_state_progress = 100_u8 }
    changes.map(&.attribute).should eq([ProgressRequestor::ATTR_UPDATE_STATE_PROGRESS])
    read_tlv(cluster, ProgressRequestor::ATTR_UPDATE_STATE_PROGRESS).as_u64.should eq(100_u64)

    version = cluster.data_version
    changes = capture_changes(cluster) do
      expect_raises(Matter::ConfigurationError) { cluster.update_state_progress = 101_u8 }
    end
    changes.should be_empty
    cluster.data_version.should eq(version)
    cluster.update_state_progress.should eq(100_u8)
    read_tlv(cluster, ProgressRequestor::ATTR_UPDATE_STATE_PROGRESS).as_u64.should eq(100_u64)

    changes = capture_changes(cluster) { cluster.update_state_progress = nil }
    changes.map(&.attribute).should eq([ProgressRequestor::ATTR_UPDATE_STATE_PROGRESS])
    read_tlv(cluster, ProgressRequestor::ATTR_UPDATE_STATE_PROGRESS).value.should be_nil
  end

  it "rejects out-of-range progress at construction" do
    expect_raises(Matter::ConfigurationError) do
      ProgressRequestor.new(update_state_progress: 101_u8)
    end
  end
end
