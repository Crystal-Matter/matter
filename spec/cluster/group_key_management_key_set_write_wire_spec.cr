require "../support/group_key_management_helpers"

private alias GKM = Matter::Cluster::GroupKeyManagement
private alias IMStatus = Matter::InteractionModel::Status
private alias IMCode = Matter::InteractionModel::StatusCode

private def write_key_set(cluster : GKM, key_set : GKM::GroupKeySetStruct) : IMStatus
  request = GKM::KeySetWriteRequest.new(key_set)
  cluster.invoke_command(GKM::CMD_KEY_SET_WRITE, request.to_tlv(nil),
    is_case_session: true, fabric_index: 1_u8).as(IMStatus)
end

describe "GroupKeyManagement KeySetWrite wire validation" do
  it "rejects a null EpochKey0 and EpochStartTime0 with InvalidCommand" do
    cluster = build(GKM, 0)
    key_set = Matter::Cluster.create_key_set(key0: nil, time0: nil)

    write_key_set(cluster, key_set).status.should eq(IMCode::InvalidCommand)
    cluster.handle_key_set_read_all_indices(1_u8).group_key_set_i_ds.should be_empty
    cluster.data_version.should eq(0_u32)
  end

  it "rejects an isolated EpochKey2 with InvalidCommand" do
    cluster = build(GKM, 0)
    key_set = Matter::Cluster.create_key_set(key2: Matter::Cluster.test_key(0x03_u8), time2: 3_000_u64)

    write_key_set(cluster, key_set).status.should eq(IMCode::InvalidCommand)
    cluster.handle_key_set_read_all_indices(1_u8).group_key_set_i_ds.should be_empty
    cluster.data_version.should eq(0_u32)
  end

  it "reports ConstraintError for an epoch key with the wrong length" do
    cluster = build(GKM, 0)
    key_set = Matter::Cluster.create_key_set(key0: Bytes.new(15, 0x01_u8))

    write_key_set(cluster, key_set).status.should eq(IMCode::ConstraintError)
    cluster.handle_key_set_read_all_indices(1_u8).group_key_set_i_ds.should be_empty
    cluster.data_version.should eq(0_u32)
  end

  it "preserves an existing key set when an invalid update is rejected" do
    cluster = build(GKM, 0)
    original = Matter::Cluster.create_key_set(key0: Matter::Cluster.test_key(0xAA_u8))
    write_key_set(cluster, original).status.should eq(IMCode::Success)
    version = cluster.data_version

    invalid = Matter::Cluster.create_key_set(key0: nil, time0: nil)
    write_key_set(cluster, invalid).status.should eq(IMCode::InvalidCommand)
    cluster.get_key_set(1_u16, 1_u8).as(GKM::GroupKeySetStruct).epoch_key0.should eq(original.epoch_key0)
    cluster.data_version.should eq(version)
  end
end
