require "../spec_helper"
require "../../src/matter/device/persistence"

private alias AliroDoorLock = Matter::Cluster::DoorLock
private ALIRO_READER_VERIFICATION_KEY_ATTRIBUTE = 0x80_u32
private SET_ALIRO_READER_CONFIG_COMMAND         = 0x28_u32

private def aliro_management_lock(
  issuer_limit : UInt16 = 2_u16,
  endpoint_limit : UInt16 = 2_u16,
) : AliroDoorLock
  build(AliroDoorLock,
    number_of_aliro_credential_issuer_keys_supported: issuer_limit,
    number_of_aliro_endpoint_keys_supported: endpoint_limit)
end

private def aliro_key_pair : Tuple(Bytes, Bytes)
  key = Matter::Crypto::Key.generate_key_pair
  {key.private_key, key.public_key}
end

describe "Door Lock internal Aliro management" do
  it "keeps Aliro feature bits off the wire until an Aliro reader exists" do
    lock = aliro_management_lock
    lock.feature_map.aliro_provisioning?.should be_false
    lock.feature_map.aliro_bleuwb?.should be_false
    lock.attributes.any? { |attribute| attribute.id.id == ALIRO_READER_VERIFICATION_KEY_ATTRIBUTE }.should be_false
    lock.commands.any? { |command| command.id.id == SET_ALIRO_READER_CONFIG_COMMAND }.should be_false
    expect_raises(ArgumentError, /Aliro/) do
      build(AliroDoorLock, feature_map: AliroDoorLock::Feature::User | AliroDoorLock::Feature::AliroProvisioning)
    end
  end

  it "stores reader configuration across restart and requires explicit clear before replacement" do
    lock = aliro_management_lock
    signing_key, verification_key = aliro_key_pair
    group_identifier = Bytes.new(16, 0xA5_u8)
    config = AliroDoorLock::AliroReaderConfig.new(signing_key, verification_key, group_identifier)

    lock.configure_aliro_reader(config).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.configure_aliro_reader(config).status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    lock.aliro_reader_config.try(&.verification_key).should eq(verification_key)

    restored = aliro_management_lock
    restored.restore_state(lock.save_state.as(Matter::Storage::Document))
    restored.aliro_reader_config.try(&.signing_key).should eq(signing_key)
    restored.aliro_reader_config.try(&.group_identifier).should eq(group_identifier)

    restored.clear_aliro_reader_config.status.should eq(Matter::InteractionModel::StatusCode::Success)
    cleared = aliro_management_lock
    cleared.restore_state(restored.save_state.as(Matter::Storage::Document))
    cleared.aliro_reader_config.should be_nil
  end

  it "rejects malformed or mismatched reader keys without changing state" do
    lock = aliro_management_lock
    signing_key, verification_key = aliro_key_pair
    other_signing_key, _ = aliro_key_pair
    group_identifier = Bytes.new(16)

    bad = AliroDoorLock::AliroReaderConfig.new(other_signing_key, verification_key, group_identifier)
    lock.configure_aliro_reader(bad).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    lock.aliro_reader_config.should be_nil

    short_group = AliroDoorLock::AliroReaderConfig.new(signing_key, verification_key, Bytes.new(15))
    lock.configure_aliro_reader(short_group).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    lock.aliro_reader_config.should be_nil
  end

  it "validates public keys and enforces issuer and shared endpoint capacity" do
    lock = aliro_management_lock(issuer_limit: 1_u16, endpoint_limit: 1_u16)
    _, issuer_key = aliro_key_pair
    _, extra_issuer_key = aliro_key_pair
    _, endpoint_key = aliro_key_pair
    _, replacement_key = aliro_key_pair

    issuer = AliroDoorLock::CredentialType::AliroCredentialIssuerKey
    evictable = AliroDoorLock::CredentialType::AliroEvictableEndpointKey
    non_evictable = AliroDoorLock::CredentialType::AliroNonEvictableEndpointKey

    lock.provision_aliro_key(issuer, 1_u16, 1_u16, issuer_key).should eq(AliroDoorLock::StatusCode::Success)
    lock.provision_aliro_key(evictable, 1_u16, 1_u16, issuer_key).should eq(AliroDoorLock::StatusCode::Duplicate)
    lock.provision_aliro_key(issuer, 2_u16, 1_u16, extra_issuer_key).should eq(AliroDoorLock::StatusCode::InvalidField)
    lock.provision_aliro_key(evictable, 1_u16, 1_u16, endpoint_key).should eq(AliroDoorLock::StatusCode::Success)
    lock.provision_aliro_key(non_evictable, 1_u16, 1_u16, replacement_key).should eq(AliroDoorLock::StatusCode::ResourceExhausted)
    lock.provision_aliro_key(non_evictable, 1_u16, 1_u16, Bytes.new(65)).should eq(AliroDoorLock::StatusCode::InvalidField)
    malformed_point = Bytes.new(65, 0xFF_u8)
    malformed_point[0] = 0x04_u8
    lock.provision_aliro_key(non_evictable, 1_u16, 1_u16, malformed_point).should eq(AliroDoorLock::StatusCode::InvalidField)
    lock.aliro_key_data(issuer, 1_u16).should eq(issuer_key)

    restored = aliro_management_lock(issuer_limit: 1_u16, endpoint_limit: 1_u16)
    restored.restore_state(lock.save_state.as(Matter::Storage::Document))
    restored.aliro_key_data(evictable, 1_u16).should eq(endpoint_key)
    restored.clear_aliro_key(evictable, 1_u16).should eq(AliroDoorLock::StatusCode::Success)
    restored.provision_aliro_key(non_evictable, 1_u16, 1_u16, replacement_key).should eq(AliroDoorLock::StatusCode::Success)
  end

  it "keeps staged Aliro keys out of unsupported wire credential operations" do
    lock = aliro_management_lock
    _, public_key = aliro_key_pair
    issuer = AliroDoorLock::CredentialType::AliroCredentialIssuerKey
    lock.provision_aliro_key(issuer, 1_u16, 1_u16, public_key).should eq(AliroDoorLock::StatusCode::Success)

    status = lock.get_credential_status(AliroDoorLock::GetCredentialStatusRequest.new(AliroDoorLock::Credential.new(issuer, 1_u16)))
    status.credential_exists?.should be_false
    lock.get_user(AliroDoorLock::GetUserRequest.new(1_u16)).credentials.should be_nil
    lock.clear_credential(AliroDoorLock::ClearCredentialRequest.new).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.aliro_key_data(issuer, 1_u16).should eq(public_key)
  end

  it "retains explicit fabric attribution when a host clears a staged key" do
    lock = aliro_management_lock
    _, public_key = aliro_key_pair
    issuer = AliroDoorLock::CredentialType::AliroCredentialIssuerKey
    lock.provision_aliro_key(issuer, 1_u16, 1_u16, public_key, fabric_index: 2_u8).should eq(AliroDoorLock::StatusCode::Success)
    lock.clear_aliro_key(issuer, 1_u16).should eq(AliroDoorLock::StatusCode::Success)
    lock.get_user(AliroDoorLock::GetUserRequest.new(1_u16)).last_modified_fabric_index.should eq(2_u8)
  end

  it "rejects corrupt persisted reader configuration before mutating live state" do
    lock = aliro_management_lock
    signing_key, verification_key = aliro_key_pair
    lock.configure_aliro_reader(AliroDoorLock::AliroReaderConfig.new(signing_key, verification_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    document = lock.save_state.as(Matter::Storage::Document)
    database = document[AliroDoorLock::PERSISTED_DATABASE_KEY].as(Matter::Storage::Document)
    config = database["aliro_reader_config"].as(Matter::Storage::Document)
    config["signing_key"] = Bytes.new(31)

    target = aliro_management_lock
    target.restore_state(document)
    target.aliro_reader_config.should be_nil
    target.get_user(AliroDoorLock::GetUserRequest.new(1_u16)).user_name.should eq("Admin")
  end

  it "rejects persisted Aliro keys above configured capacity before applying any key" do
    source = aliro_management_lock(endpoint_limit: 2_u16)
    _, first_key = aliro_key_pair
    _, second_key = aliro_key_pair
    evictable = AliroDoorLock::CredentialType::AliroEvictableEndpointKey
    non_evictable = AliroDoorLock::CredentialType::AliroNonEvictableEndpointKey
    source.provision_aliro_key(evictable, 1_u16, 1_u16, first_key).should eq(AliroDoorLock::StatusCode::Success)
    source.provision_aliro_key(non_evictable, 1_u16, 1_u16, second_key).should eq(AliroDoorLock::StatusCode::Success)

    target = aliro_management_lock(endpoint_limit: 1_u16)
    target.restore_state(source.save_state.as(Matter::Storage::Document))
    target.aliro_key_data(evictable, 1_u16).should be_nil
    target.get_user(AliroDoorLock::GetUserRequest.new(1_u16)).user_name.should eq("Admin")
  end

  it "restores reader material and fabric-attributed keys after a storage flush" do
    path = File.join(Dir.tempdir, "matter-aliro-#{Random::Secure.hex(6)}.yml")
    first = aliro_management_lock
    signing_key, verification_key = aliro_key_pair
    _, issuer_key = aliro_key_pair
    config = AliroDoorLock::AliroReaderConfig.new(signing_key, verification_key, Bytes.new(16, 0xA5_u8))
    first.configure_aliro_reader(config).status.should eq(Matter::InteractionModel::StatusCode::Success)
    issuer = AliroDoorLock::CredentialType::AliroCredentialIssuerKey
    first.provision_aliro_key(issuer, 1_u16, 1_u16, issuer_key, fabric_index: 2_u8).should eq(AliroDoorLock::StatusCode::Success)

    storage = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    storage.track(first)
    storage.save_cluster(first).should be_true
    storage.close

    restored = aliro_management_lock
    reopened = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    reopened.restore_clusters([restored] of Matter::Cluster::Base).should eq(1)
    restored.aliro_reader_config.try(&.verification_key).should eq(verification_key)
    restored.aliro_key_data(issuer, 1_u16).should eq(issuer_key)
    record = restored.save_state.as(Matter::Storage::Document)[AliroDoorLock::PERSISTED_DATABASE_KEY]
      .as(Matter::Storage::Document)["credentials"].as(Array(Matter::Storage::Type)).first.as(Matter::Storage::Document)
    record["creator_fabric_index"].should eq(2_i64)
    reopened.close
  ensure
    File.delete?(path) if path
  end
end
