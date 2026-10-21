require "../spec_helper"

private alias Ota = Matter::Cluster::OtaRequestor
private alias IMStatus = Matter::InteractionModel::StatusCode

private def write_provider(cluster : Ota, fabric_index : UInt8,
                           provider_node_id : UInt64) : Matter::InteractionModel::Status
  cluster.request_fabric_index = fabric_index
  provider = Ota::ProviderLocation.new(provider_node_id, 0_u16, fabric_index)
  cluster.write_attribute(Ota::ATTR_DEFAULT_OTA_PROVIDERS,
    TLV::Serializable.serialize_value([provider], nil))
end

describe Ota do
  it "does not advertise update capability before an update engine is installed" do
    cluster = Ota.new
    cluster.update_possible?.should be_false
    read_tlv(cluster, Ota::ATTR_UPDATE_POSSIBLE).as_bool.should be_false
  end

  it "accepts a commissioned fabric's TLV write without a client-supplied FabricIndex" do
    cluster = Ota.new
    provider = Ota::ProviderLocation.new(0x1001_u64, 0_u16)
    request = Matter::InteractionModel::WriteRequestMessage.new(
      suppress_response: false,
      timed_request: false,
      write_requests: [Matter::InteractionModel::AttributeDataIB.new(
        path: Matter::InteractionModel::AttributePath.new(
          endpoint: 0_u16, cluster: Ota::CLUSTER_ID,
          attribute: Ota::ATTR_DEFAULT_OTA_PROVIDERS),
        data: TLV::Serializable.serialize_value([provider], nil),
      )]
    )
    parsed = Matter::Protocol::IMHandler.parse_write_request(request.to_slice).as(Matter::InteractionModel::WriteRequestMessage)
    statuses = Matter::Protocol::IMHandler.write_attributes(parsed.write_requests,
      { {0_u16, Ota::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x123_u64])
    statuses.first.status.status.should eq(IMStatus::Success.value)

    result = read_tlv(cluster, Ota::ATTR_DEFAULT_OTA_PROVIDERS, 1_u8).as_list
    result.size.should eq(1)
    Ota::ProviderLocation.from_tlv(result.first).fabric_index.should eq(1_u8)
    read_tlv(cluster, Ota::ATTR_DEFAULT_OTA_PROVIDERS, 2_u8).as_list.should be_empty
  end

  it "retains independent default providers on two fabrics and after restart" do
    cluster = Ota.new
    write_provider(cluster, 1_u8, 0x1001_u64).status.should eq(IMStatus::Success)
    write_provider(cluster, 2_u8, 0x2002_u64).status.should eq(IMStatus::Success)

    cluster.request_fabric_index = 1_u8
    cluster.default_ota_providers.map(&.provider_node_id).should eq([0x1001_u64])
    cluster.request_fabric_index = 2_u8
    cluster.default_ota_providers.map(&.provider_node_id).should eq([0x2002_u64])

    document = cluster.as(Matter::Cluster::Base).save_state.as(Matter::Storage::Document)
    restored = Ota.new
    restored.restore_state(document)
    restored.request_fabric_index = 1_u8
    restored.default_ota_providers.map(&.provider_node_id).should eq([0x1001_u64])
    restored.request_fabric_index = 2_u8
    restored.default_ota_providers.map(&.provider_node_id).should eq([0x2002_u64])
  end

  it "rejects a second provider for one fabric without changing the current choice" do
    cluster = Ota.new
    write_provider(cluster, 1_u8, 0x1001_u64).status.should eq(IMStatus::Success)
    cluster.request_fabric_index = 1_u8
    proposed = [
      Ota::ProviderLocation.new(0x1002_u64, 0_u16),
      Ota::ProviderLocation.new(0x1003_u64, 1_u16),
    ]
    cluster.write_attribute(Ota::ATTR_DEFAULT_OTA_PROVIDERS,
      TLV::Serializable.serialize_value(proposed, nil)).status.should eq(IMStatus::ConstraintError)
    cluster.default_ota_providers.map(&.provider_node_id).should eq([0x1001_u64])
  end

  it "binds an incoming provider to the authenticated fabric and removes only that fabric" do
    cluster = Ota.new
    cluster.request_fabric_index = 1_u8
    spoofed = Ota::ProviderLocation.new(0x1001_u64, 0_u16, 2_u8)
    cluster.write_attribute(Ota::ATTR_DEFAULT_OTA_PROVIDERS,
      TLV::Serializable.serialize_value([spoofed], nil)).status.should eq(IMStatus::Success)
    cluster.default_ota_providers.first.fabric_index.should eq(1_u8)

    write_provider(cluster, 2_u8, 0x2002_u64).status.should eq(IMStatus::Success)
    cluster.remove_fabric(1_u8)
    cluster.request_fabric_index = 1_u8
    cluster.default_ota_providers.should be_empty
    cluster.request_fabric_index = 2_u8
    cluster.default_ota_providers.map(&.provider_node_id).should eq([0x2002_u64])

    document = cluster.as(Matter::Cluster::Base).save_state.as(Matter::Storage::Document)
    restored = Ota.new
    restored.restore_state(document)
    restored.request_fabric_index = 1_u8
    restored.default_ota_providers.should be_empty
    restored.request_fabric_index = 2_u8
    restored.default_ota_providers.map(&.provider_node_id).should eq([0x2002_u64])
  end

  it "does not expose or accept default providers without a fabric context" do
    cluster = Ota.new
    write_provider(cluster, 1_u8, 0x1001_u64).status.should eq(IMStatus::Success)
    cluster.request_fabric_index = nil
    cluster.default_ota_providers.should be_empty
    read_tlv(cluster, Ota::ATTR_DEFAULT_OTA_PROVIDERS).as_list.should be_empty

    proposal = Ota::ProviderLocation.new(0x2002_u64, 0_u16)
    cluster.write_attribute(Ota::ATTR_DEFAULT_OTA_PROVIDERS,
      TLV::Serializable.serialize_value([proposal], nil)).status.should eq(IMStatus::UnsupportedAccess)
  end
end
