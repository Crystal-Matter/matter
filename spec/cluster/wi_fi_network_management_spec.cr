require "../spec_helper"
require "../../src/matter/cluster/wi_fi_network_management"

alias WiFi = Matter::Cluster::WiFiNetworkManagement
alias StatusCode = Matter::InteractionModel::StatusCode

describe Matter::Cluster::WiFiNetworkManagement do
  it "advertises the Matter 1.6 revision 1 schema with nullable credentials" do
    cluster = build(WiFi)

    cluster.cluster_id.id.should eq(0x0451_u32)
    read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(1_u16)
    read(cluster, WiFi::ATTR_SSID).should be_nil
    read(cluster, WiFi::ATTR_PASSPHRASE_SURROGATE).should be_nil
    attribute_ids(cluster).should contain(WiFi::ATTR_SSID)
    attribute_ids(cluster).should contain(WiFi::ATTR_PASSPHRASE_SURROGATE)
    accepted_command_ids(cluster).should contain(WiFi::CMD_NETWORK_PASSPHRASE_REQUEST)
    generated_command_ids(cluster).should contain(WiFi::CMD_NETWORK_PASSPHRASE_REQUEST_RESPONSE)
    cluster.get_attribute_metadata(WiFi::ATTR_PASSPHRASE_SURROGATE).as(Matter::Cluster::AttributeMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    cluster.get_command_metadata(WiFi::CMD_NETWORK_PASSPHRASE_REQUEST).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
  end

  it "requires CASE and provisioned credentials before returning a passphrase" do
    cluster = build(WiFi)

    expect_status(invoke(cluster, WiFi::CMD_NETWORK_PASSPHRASE_REQUEST, is_case_session: true), StatusCode::InvalidInState)
    cluster.update_credentials("Test Wi-Fi".to_slice, "correct horse".to_slice, 1_u64)
    expect_status(invoke(cluster, WiFi::CMD_NETWORK_PASSPHRASE_REQUEST), StatusCode::UnsupportedAccess)
    response = invoke(cluster, WiFi::CMD_NETWORK_PASSPHRASE_REQUEST, is_case_session: true).as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(WiFi::CMD_NETWORK_PASSPHRASE_REQUEST_RESPONSE)
    WiFi::NetworkPassphraseResponse.from_tlv(response.response.as(TLV::Any)).passphrase.should eq("correct horse".to_slice)
  end

  it "validates credentials before mutation and updates the surrogate only when the passphrase changes" do
    cluster = build(WiFi)
    expect_raises(Matter::ConfigurationError) { cluster.update_credentials(Bytes.empty, "correct horse".to_slice, 1_u64) }
    expect_raises(Matter::ConfigurationError) { cluster.update_credentials("a".to_slice, "short".to_slice, 1_u64) }
    expect_raises(Matter::ConfigurationError) { cluster.update_credentials("a".to_slice, Bytes.new(64, 'G'.ord.to_u8), 1_u64) }
    read(cluster, WiFi::ATTR_SSID).should be_nil

    cluster.update_credentials("First".to_slice, "correct horse".to_slice, 1_u64)
    first_surrogate = read(cluster, WiFi::ATTR_PASSPHRASE_SURROGATE).as(Number).to_u64
    first_version = cluster.data_version
    cluster.update_credentials("First".to_slice, "correct horse".to_slice, 1_u64)
    cluster.data_version.should eq(first_version)
    cluster.update_credentials("Second".to_slice, "correct horse".to_slice, 1_u64)
    read(cluster, WiFi::ATTR_PASSPHRASE_SURROGATE).should eq(first_surrogate)
    expect_raises(Matter::ConfigurationError) { cluster.update_credentials("Second".to_slice, "another horse".to_slice, 1_u64) }
    cluster.update_credentials("Second".to_slice, "another horse".to_slice, 2_u64)
    second_surrogate = read(cluster, WiFi::ATTR_PASSPHRASE_SURROGATE).as(Number).to_u64
    second_surrogate.should eq(2_u64)
    read(cluster, WiFi::ATTR_SSID).should eq("Second".to_slice)

    cluster.clear_credentials
    read(cluster, WiFi::ATTR_SSID).should be_nil
    read(cluster, WiFi::ATTR_PASSPHRASE_SURROGATE).should be_nil
    expect_status(invoke(cluster, WiFi::CMD_NETWORK_PASSPHRASE_REQUEST, is_case_session: true), StatusCode::InvalidInState)
    expect_raises(Matter::ConfigurationError) { cluster.update_credentials("Second".to_slice, "another horse".to_slice, 2_u64) }
    cluster.update_credentials("Second".to_slice, "another horse".to_slice, 3_u64)
    read(cluster, WiFi::ATTR_PASSPHRASE_SURROGATE).as(Number).to_u64.should eq(3_u64)
    cluster.save_state.should be_nil
  end

  it "copies host-provided credential buffers and accepts a valid 64-digit hex PSK" do
    cluster = build(WiFi)
    ssid = "Test".to_slice.dup
    psk = Bytes.new(64, 'a'.ord.to_u8)
    cluster.update_credentials(ssid, psk, 7_u64)
    ssid.fill(0_u8)
    psk.fill(0_u8)

    read(cluster, WiFi::ATTR_SSID).should eq("Test".to_slice)
    response = invoke(cluster, WiFi::CMD_NETWORK_PASSPHRASE_REQUEST, is_case_session: true).as(Matter::Cluster::CommandResponse)
    WiFi::NetworkPassphraseResponse.from_tlv(response.response.as(TLV::Any)).passphrase.should eq(Bytes.new(64, 'a'.ord.to_u8))
  end

  it "restores the host's durable surrogate unchanged after a cluster restart" do
    original = build(WiFi)
    original.update_credentials("Test".to_slice, "correct horse".to_slice, 42_u64)

    restarted = build(WiFi)
    restarted.update_credentials("Test".to_slice, "correct horse".to_slice, 42_u64)
    read(restarted, WiFi::ATTR_PASSPHRASE_SURROGATE).should eq(42_u64)
    restarted.save_state.should be_nil
  end
end
