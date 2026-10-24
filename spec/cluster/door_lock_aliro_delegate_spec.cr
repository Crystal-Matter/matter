require "../spec_helper"

private alias AliroLock = Matter::Cluster::DoorLock

private class TestAliroReader < AliroLock::AliroReaderDelegate
  property authenticated : AliroLock::AliroAuthenticatedAccess? = nil
  property on_authenticate : Proc(Nil)? = nil
  property? allow_clear = true
  property? accept_config = true
  property? ready : Bool = true
  property? fail_authenticate = false
  property? fail_clear = false
  getter configured : AliroLock::AliroReaderConfig? = nil

  def supported_protocol_versions : Array(Bytes)
    [Bytes[0x01, 0x00]]
  end

  def group_sub_identifier : Bytes
    Bytes.new(16, 0xAA_u8)
  end

  def configure(config : AliroLock::AliroReaderConfig) : Bool
    return false unless @accept_config
    @configured = config
    true
  end

  def clear_with_user_permission : Bool
    raise "reader clear failed" if @fail_clear
    return false unless @allow_clear
    @configured = nil
    true
  end

  def authenticate(transaction : Bytes, required_step_up_data_element : String) : AliroLock::AliroAuthenticatedAccess?
    raise "reader authentication failed" if @fail_authenticate
    required_step_up_data_element.should eq("matter1")
    @on_authenticate.try(&.call)
    @authenticated
  end
end

private class TestAliroBleUwbReader < AliroLock::AliroBleUwbReaderDelegate
  property? ready : Bool = true
  property? radio_ready : Bool = true
  property versions : Array(Bytes) = [Bytes[0x01, 0x00]]
  property? authenticated_called = false
  property authenticated : AliroLock::AliroAuthenticatedAccess? = nil
  property on_authenticate : Proc(Nil)? = nil
  getter configured : AliroLock::AliroReaderConfig? = nil

  def supported_protocol_versions : Array(Bytes)
    [Bytes[0x01, 0x00]]
  end

  def group_sub_identifier : Bytes
    Bytes.new(16, 0xAA_u8)
  end

  def supported_bleuwb_protocol_versions : Array(Bytes)
    @versions
  end

  def ble_advertising_version : UInt8
    1_u8
  end

  def configure(config : AliroLock::AliroReaderConfig) : Bool
    @configured = config
    true
  end

  def clear_with_user_permission : Bool
    @configured = nil
    true
  end

  def authenticate(transaction : Bytes, required_step_up_data_element : String) : AliroLock::AliroAuthenticatedAccess?
    @authenticated_called = true
    @on_authenticate.try(&.call)
    @authenticated
  end
end

private def aliro_bleuwb_lock(reader : TestAliroBleUwbReader) : AliroLock
  build(AliroLock,
    feature_map: AliroLock::Feature::User | AliroLock::Feature::AliroProvisioning | AliroLock::Feature::AliroBleuwb,
    aliro_reader_delegate: reader,
    number_of_aliro_credential_issuer_keys_supported: 2_u16,
    number_of_aliro_endpoint_keys_supported: 2_u16)
end

describe "Door Lock Aliro BLE/UWB delegate boundary" do
  it "gates ALBU on a ready physical radio with valid fixed protocol data" do
    reader = TestAliroBleUwbReader.new
    reader.radio_ready = false
    expect_raises(ArgumentError, /radio/) { aliro_bleuwb_lock(reader) }
    reader.radio_ready = true
    reader.versions = [Bytes[0x01]]
    expect_raises(ArgumentError, /protocol/) { aliro_bleuwb_lock(reader) }
    reader.versions = [Bytes[0x01, 0x00]]
    lock = aliro_bleuwb_lock(reader)
    lock.feature_map.aliro_bleuwb?.should be_true
    read_tlv(lock, AliroLock::ATTR_ALIRO_SUPPORTED_BLEUWB_PROTOCOL_VERSIONS).as_list.map(&.value).should eq(reader.versions)
    read(lock, AliroLock::ATTR_ALIRO_BLE_ADVERTISING_VERSION).should eq(1_u8)
    read(lock, AliroLock::ATTR_ALIRO_GROUP_RESOLVING_KEY).should be_nil
    [AliroLock::ATTR_ALIRO_GROUP_RESOLVING_KEY,
     AliroLock::ATTR_ALIRO_SUPPORTED_BLEUWB_PROTOCOL_VERSIONS,
     AliroLock::ATTR_ALIRO_BLE_ADVERTISING_VERSION].each do |id|
      metadata = lock.get_attribute_metadata(id) || raise "Missing Aliro BLE/UWB attribute #{id}"
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    end
    versions = lock.get_attribute_metadata(AliroLock::ATTR_ALIRO_SUPPORTED_BLEUWB_PROTOCOL_VERSIONS) || raise "Missing Aliro protocol versions"
    versions.fixed?.should be_true
    advertising = lock.get_attribute_metadata(AliroLock::ATTR_ALIRO_BLE_ADVERTISING_VERSION) || raise "Missing Aliro advertising version"
    advertising.fixed?.should be_true
  end

  it "requires the 16-byte resolving key for ALBU and restores it after restart" do
    reader = TestAliroBleUwbReader.new
    lock = aliro_bleuwb_lock(reader)
    key = Matter::Crypto::Key.generate_key_pair
    without_resolving_key = AliroLock::SetAliroReaderConfigRequest.new(key.private_key, key.public_key, Bytes.new(16))
    lock.handle_set_aliro_reader_config(without_resolving_key).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    reader.configured.should be_nil

    resolving_key = Bytes.new(16, 0xAB_u8)
    request = AliroLock::SetAliroReaderConfigRequest.new(key.private_key, key.public_key, Bytes.new(16), resolving_key)
    lock.handle_set_aliro_reader_config(request).success?.should be_true
    read(lock, AliroLock::ATTR_ALIRO_GROUP_RESOLVING_KEY).should eq(resolving_key)

    restored_reader = TestAliroBleUwbReader.new
    restored = aliro_bleuwb_lock(restored_reader)
    restored.restore_state(lock.save_state.as(Matter::Storage::Document))
    restored_reader.configured.try(&.group_resolving_key).should eq(resolving_key)
    read(restored, AliroLock::ATTR_ALIRO_GROUP_RESOLVING_KEY).should eq(resolving_key)
    restored.handle_clear_aliro_reader_config.success?.should be_true
    read(restored, AliroLock::ATTR_ALIRO_GROUP_RESOLVING_KEY).should be_nil
  end

  it "refuses transactions and restored configuration when the radio becomes unavailable" do
    reader = TestAliroBleUwbReader.new
    lock = aliro_bleuwb_lock(reader)
    key = Matter::Crypto::Key.generate_key_pair
    resolving_key = Bytes.new(16, 0xAB_u8)
    config = AliroLock::AliroReaderConfig.new(key.private_key, key.public_key, Bytes.new(16), resolving_key)
    lock.configure_aliro_reader(config).success?.should be_true
    document = lock.save_state.as(Matter::Storage::Document)

    reader.radio_ready = false
    lock.perform_aliro_transaction(Bytes[0x01]).success?.should be_false
    reader.authenticated_called?.should be_false

    restored_reader = TestAliroBleUwbReader.new
    restored = aliro_bleuwb_lock(restored_reader)
    restored_reader.radio_ready = false
    restored.restore_state(document)
    restored.feature_map.aliro_provisioning?.should be_false
    restored.feature_map.aliro_bleuwb?.should be_false
  end

  it "rejects a transaction if the radio drops during authentication" do
    reader = TestAliroBleUwbReader.new
    lock = aliro_bleuwb_lock(reader)
    signing = Matter::Crypto::Key.generate_key_pair
    endpoint = Matter::Crypto::Key.generate_key_pair
    config = AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key,
      Bytes.new(16), Bytes.new(16, 0xAB_u8))
    lock.configure_aliro_reader(config).success?.should be_true
    lock.provision_aliro_key(AliroLock::CredentialType::AliroNonEvictableEndpointKey,
      1_u16, 1_u16, endpoint.public_key).should eq(AliroLock::StatusCode::Success)
    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(endpoint.public_key)
    reader.on_authenticate = -> { reader.radio_ready = false; nil }

    lock.perform_aliro_transaction(Bytes[0x01]).success?.should be_false
    lock.locked?.should be_true
  end
end

private def aliro_delegate_lock(reader : TestAliroReader? = TestAliroReader.new, endpoint_limit : UInt16 = 2_u16) : AliroLock
  build(AliroLock,
    feature_map: AliroLock::Feature::User | AliroLock::Feature::AliroProvisioning,
    aliro_reader_delegate: reader,
    number_of_aliro_credential_issuer_keys_supported: 2_u16,
    number_of_aliro_endpoint_keys_supported: endpoint_limit)
end

describe "Door Lock trusted Aliro reader" do
  it "requires a delegate and advertises ALIRO mandatory attributes and commands only with one" do
    expect_raises(ArgumentError, /Aliro/) { aliro_delegate_lock(nil) }
    unavailable = TestAliroReader.new
    unavailable.ready = false
    expect_raises(ArgumentError, /not ready/) { aliro_delegate_lock(unavailable) }
    expect_raises(ArgumentError, /BLE\/UWB/) do
      build(AliroLock,
        feature_map: AliroLock::Feature::User | AliroLock::Feature::AliroProvisioning | AliroLock::Feature::AliroBleuwb,
        aliro_reader_delegate: TestAliroReader.new)
    end
    lock = aliro_delegate_lock
    lock.feature_map.aliro_provisioning?.should be_true
    lock.feature_map.aliro_bleuwb?.should be_false
    [0x80_u32, 0x81_u32, 0x82_u32, 0x83_u32, 0x87_u32, 0x88_u32].each do |id|
      lock.attributes.any? { |attribute| attribute.id.id == id }.should be_true
    end
    [0x28_u32, 0x29_u32].each do |id|
      lock.commands.any? { |command| command.id.id == id }.should be_true
      command = lock.get_command_metadata(id) || raise "Missing Aliro command #{id}"
      command.access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
      command.timed?.should be_true
    end
  end

  it "configures the reader only with matching keys and clears only after permission" do
    reader = TestAliroReader.new
    lock = aliro_delegate_lock(reader)
    key = Matter::Crypto::Key.generate_key_pair
    request = AliroLock::SetAliroReaderConfigRequest.new(key.private_key, key.public_key, Bytes.new(16, 0xCC_u8))
    changed = [] of UInt32
    lock.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attribute : UInt32) { changed << attribute; nil }
    initial_version = lock.data_version
    lock.handle_set_aliro_reader_config(request).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.data_version.should eq(initial_version &+ 1_u32)
    changed.should eq([0x0080_u32, 0x0081_u32])
    reader.configured.try(&.verification_key).should eq(key.public_key)
    lock.aliro_reader_verification_key.should eq(key.public_key)
    lock.handle_set_aliro_reader_config(request).status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    reader.allow_clear = false
    lock.handle_clear_aliro_reader_config.status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.clear_aliro_reader_config.status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.aliro_reader_verification_key.should eq(key.public_key)
    reader.fail_clear = true
    lock.handle_clear_aliro_reader_config.status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.aliro_reader_verification_key.should eq(key.public_key)
    lock.data_version.should eq(initial_version &+ 1_u32)
    changed.should eq([0x0080_u32, 0x0081_u32])
    reader.fail_clear = false
    reader.allow_clear = true
    lock.handle_clear_aliro_reader_config.status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.data_version.should eq(initial_version &+ 2_u32)
    changed.should eq([0x0080_u32, 0x0081_u32, 0x0080_u32, 0x0081_u32])
    reader.configured.should be_nil
    lock.aliro_reader_verification_key.should be_nil
  end

  it "never unlocks for an unverified reader transaction" do
    reader = TestAliroReader.new
    lock = aliro_delegate_lock(reader)
    signing = Matter::Crypto::Key.generate_key_pair
    lock.configure_aliro_reader(AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.perform_aliro_transaction(Bytes[0x01]).status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.locked?.should be_true
    reader.fail_authenticate = true
    lock.perform_aliro_transaction(Bytes[0x02]).status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.locked?.should be_true
  end

  it "rejects an authentication result from a reader config cleared during verification" do
    reader = TestAliroReader.new
    lock = aliro_delegate_lock(reader)
    signing = Matter::Crypto::Key.generate_key_pair
    endpoint = Matter::Crypto::Key.generate_key_pair
    lock.configure_aliro_reader(AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.provision_aliro_key(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16, 1_u16, endpoint.public_key).should eq(AliroLock::StatusCode::Success)
    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(endpoint.public_key)
    reader.on_authenticate = -> { lock.clear_aliro_reader_config; nil }
    lock.perform_aliro_transaction(Bytes[0x01]).status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.locked?.should be_true
  end

  it "serves Aliro public-key CredentialData and enforces shared endpoint capacity on Matter commands" do
    lock = aliro_delegate_lock(endpoint_limit: 1_u16)
    first = Matter::Crypto::Key.generate_key_pair
    second = Matter::Crypto::Key.generate_key_pair
    evictable = AliroLock::Credential.new(AliroLock::CredentialType::AliroEvictableEndpointKey, 1_u16)
    non_evictable = AliroLock::Credential.new(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16)
    request = AliroLock::SetCredentialRequest.new(AliroLock::DataOperationType::Add, evictable, first.public_key, 1_u16)
    lock.handle_set_credential(request).status_code.should eq(AliroLock::StatusCode::Success)
    status = lock.get_credential_status(AliroLock::GetCredentialStatusRequest.new(evictable))
    status.credential_data.should eq(first.public_key)
    wire = invoke(lock, AliroLock::CMD_GET_CREDENTIAL_STATUS, AliroLock::GetCredentialStatusRequest.new(evictable))
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    wire[5_u8].value.should eq(first.public_key)

    empty_aliro = invoke(lock, AliroLock::CMD_GET_CREDENTIAL_STATUS, AliroLock::GetCredentialStatusRequest.new(non_evictable))
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    empty_aliro.has_key?(5_u8).should be_true
    empty_aliro[5_u8].value.should be_nil

    non_aliro = invoke(lock, AliroLock::CMD_GET_CREDENTIAL_STATUS,
      AliroLock::GetCredentialStatusRequest.new(AliroLock::Credential.new(AliroLock::CredentialType::Pin, 1_u16)))
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    non_aliro.has_key?(5_u8).should be_false

    duplicate = AliroLock::SetCredentialRequest.new(AliroLock::DataOperationType::Add, non_evictable, first.public_key, 1_u16)
    lock.handle_set_credential(duplicate).status_code.should eq(AliroLock::StatusCode::Duplicate)
    full = AliroLock::SetCredentialRequest.new(AliroLock::DataOperationType::Add, non_evictable, second.public_key, 1_u16)
    lock.handle_set_credential(full).status_code.should eq(AliroLock::StatusCode::ResourceExhausted)
  end

  it "creates an owned user when SetCredential omits UserIndex" do
    lock = aliro_delegate_lock
    endpoint = Matter::Crypto::Key.generate_key_pair
    credential = AliroLock::Credential.new(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16)
    request = AliroLock::SetCredentialRequest.new(AliroLock::DataOperationType::Add, credential, endpoint.public_key)
    fields = request.to_tlv(nil).as_structure
    [3_u8, 4_u8, 5_u8].each { |tag| fields[tag].value.should be_nil }
    response = lock.handle_set_credential(request)
    response.status_code.should eq(AliroLock::StatusCode::Success)
    response.user_index.should eq(2_u16)
    lock.get_credential_status(AliroLock::GetCredentialStatusRequest.new(credential)).user_index.should eq(2_u16)
  end

  it "unlocks only for a verified endpoint key and journals its user and credential" do
    reader = TestAliroReader.new
    lock = aliro_delegate_lock(reader)
    signing = Matter::Crypto::Key.generate_key_pair
    lock.configure_aliro_reader(AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    endpoint = Matter::Crypto::Key.generate_key_pair
    credential = AliroLock::Credential.new(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16)
    lock.provision_aliro_key(credential.credential_type, credential.credential_index, 1_u16, endpoint.public_key).should eq(AliroLock::StatusCode::Success)
    emitted = [] of Tuple(UInt32, TLV::Any)
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      emitted << {event, data}
      nil
    end

    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(endpoint.public_key)
    lock.perform_aliro_transaction(Bytes[0x42]).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.unlocked?.should be_true
    event = emitted.find! { |id, _| id == AliroLock::EVENT_LOCK_OPERATION }[1]
    operation = AliroLock::Events::LockOperation.from_tlv(event)
    operation.operation_source.should eq(AliroLock::OperationSource::Aliro)
    operation.user_index.should eq(1_u16)
    operation.credentials.should eq([credential])
    operation.fabric_index.should be_nil
  end

  it "creates a same-user evictable endpoint key after verified matter1 step-up" do
    reader = TestAliroReader.new
    lock = aliro_delegate_lock(reader, endpoint_limit: 1_u16)
    signing = Matter::Crypto::Key.generate_key_pair
    lock.configure_aliro_reader(AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    issuer = Matter::Crypto::Key.generate_key_pair
    old_endpoint = Matter::Crypto::Key.generate_key_pair
    new_endpoint = Matter::Crypto::Key.generate_key_pair
    issuer_type = AliroLock::CredentialType::AliroCredentialIssuerKey
    evictable = AliroLock::CredentialType::AliroEvictableEndpointKey
    lock.provision_aliro_key(issuer_type, 1_u16, 1_u16, issuer.public_key).should eq(AliroLock::StatusCode::Success)
    lock.provision_aliro_key(evictable, 1_u16, 1_u16, old_endpoint.public_key).should eq(AliroLock::StatusCode::Success)
    emitted = [] of Tuple(UInt32, TLV::Any, UInt8?)
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
      emitted << {event, data, fabric}
      nil
    end

    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(issuer.public_key, issuer.public_key, new_endpoint.public_key)
    lock.perform_aliro_transaction(Bytes[0x55]).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.aliro_key_data(evictable, 1_u16).should eq(new_endpoint.public_key)
    changes = emitted.select { |id, _, _| id == AliroLock::EVENT_LOCK_USER_CHANGE }
    changes.size.should eq(2)
    changes.map { |_, data, _| AliroLock::Events::LockUserChange.from_tlv(data).data_operation_type }
      .should eq([AliroLock::DataOperationType::Clear, AliroLock::DataOperationType::Add])
    changes.each do |_, data, fabric|
      change = AliroLock::Events::LockUserChange.from_tlv(data)
      change.operation_source.should eq(AliroLock::OperationSource::Aliro)
      change.user_index.should eq(1_u16)
      change.fabric_index.should be_nil
      fabric.should be_nil
    end
    operation = emitted.find! { |id, _, _| id == AliroLock::EVENT_LOCK_OPERATION }
    AliroLock::Events::LockOperation.from_tlv(operation[1]).credentials
      .should eq([AliroLock::Credential.new(evictable, 1_u16)])

    restored = aliro_delegate_lock(TestAliroReader.new, endpoint_limit: 1_u16)
    restored.restore_state(lock.save_state.as(Matter::Storage::Document))
    restored.aliro_key_data(evictable, 1_u16).should eq(new_endpoint.public_key)
  end

  it "keeps a non-evictable endpoint key and attributes a full-capacity step-up to its issuer" do
    reader = TestAliroReader.new
    lock = aliro_delegate_lock(reader, endpoint_limit: 1_u16)
    signing = Matter::Crypto::Key.generate_key_pair
    lock.configure_aliro_reader(AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    issuer_key = Matter::Crypto::Key.generate_key_pair
    existing_key = Matter::Crypto::Key.generate_key_pair
    proposed_key = Matter::Crypto::Key.generate_key_pair
    issuer = AliroLock::Credential.new(AliroLock::CredentialType::AliroCredentialIssuerKey, 1_u16)
    protected_credential = AliroLock::Credential.new(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16)
    lock.provision_aliro_key(issuer.credential_type, issuer.credential_index, 1_u16, issuer_key.public_key).should eq(AliroLock::StatusCode::Success)
    lock.provision_aliro_key(protected_credential.credential_type, protected_credential.credential_index, 1_u16, existing_key.public_key).should eq(AliroLock::StatusCode::Success)
    events = [] of Tuple(UInt32, TLV::Any)
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end

    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(issuer_key.public_key, issuer_key.public_key)
    lock.perform_aliro_transaction(Bytes[0x76]).status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.locked?.should be_true
    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(issuer_key.public_key, issuer_key.public_key, Bytes.new(65, 0_u8))
    lock.perform_aliro_transaction(Bytes[0x75]).status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.locked?.should be_true

    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(issuer_key.public_key, issuer_key.public_key, proposed_key.public_key)
    lock.perform_aliro_transaction(Bytes[0x77]).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.unlocked?.should be_true
    lock.aliro_key_data(protected_credential.credential_type, protected_credential.credential_index).should eq(existing_key.public_key)
    lock.aliro_key_data(AliroLock::CredentialType::AliroEvictableEndpointKey, 1_u16).should be_nil
    events.count { |id, _| id == AliroLock::EVENT_LOCK_USER_CHANGE }.should eq(0)
    operation = events.find! { |id, _| id == AliroLock::EVENT_LOCK_OPERATION }[1]
    AliroLock::Events::LockOperation.from_tlv(operation).credentials.should eq([issuer])
  end

  it "honors disabled and non-access user policy for authenticated Aliro keys" do
    reader = TestAliroReader.new
    lock = aliro_delegate_lock(reader)
    signing = Matter::Crypto::Key.generate_key_pair
    endpoint = Matter::Crypto::Key.generate_key_pair
    lock.configure_aliro_reader(AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.provision_aliro_key(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16, 1_u16, endpoint.public_key).should eq(AliroLock::StatusCode::Success)
    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(endpoint.public_key)

    disable = AliroLock::SetUserRequest.new(AliroLock::DataOperationType::Modify, 1_u16,
      user_status: AliroLock::UserStatus::OccupiedDisabled)
    lock.handle_set_user(disable).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.perform_aliro_transaction(Bytes[0x01]).status.should_not eq(Matter::InteractionModel::StatusCode::Success)
    lock.locked?.should be_true

    non_access = AliroLock::SetUserRequest.new(AliroLock::DataOperationType::Modify, 1_u16,
      user_status: AliroLock::UserStatus::OccupiedEnabled,
      user_type: AliroLock::UserType::NonAccessUser)
    lock.handle_set_user(non_access).status.should eq(Matter::InteractionModel::StatusCode::Success)
    events = [] of TLV::Any
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << data if id == AliroLock::EVENT_LOCK_OPERATION
      nil
    end
    lock.perform_aliro_transaction(Bytes[0x02]).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.locked?.should be_true
    AliroLock::Events::LockOperation.from_tlv(events.last).lock_operation_type.should eq(AliroLock::LockOperationType::NonAccessUserEvent)

    forced = AliroLock::SetUserRequest.new(AliroLock::DataOperationType::Modify, 1_u16,
      user_type: AliroLock::UserType::ForcedUser)
    lock.handle_set_user(forced).status.should eq(Matter::InteractionModel::StatusCode::Success)
    alarms = [] of TLV::Any
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << data if id == AliroLock::EVENT_LOCK_OPERATION
      alarms << data if id == AliroLock::EVENT_DOOR_LOCK_ALARM
      nil
    end
    lock.perform_aliro_transaction(Bytes[0x03]).status.should eq(Matter::InteractionModel::StatusCode::Success)
    lock.unlocked?.should be_true
    AliroLock::Events::LockOperation.from_tlv(events.last).lock_operation_type.should eq(AliroLock::LockOperationType::ForcedUserEvent)
    AliroLock::Events::DoorLockAlarm.from_tlv(alarms.last).alarm_code.should eq(AliroLock::AlarmCode::ForcedUser)
  end

  it "reapplies durable reader configuration and keys before allowing Aliro access after restart" do
    first = aliro_delegate_lock
    signing = Matter::Crypto::Key.generate_key_pair
    endpoint = Matter::Crypto::Key.generate_key_pair
    first.configure_aliro_reader(AliroLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).status.should eq(Matter::InteractionModel::StatusCode::Success)
    first.provision_aliro_key(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16, 1_u16, endpoint.public_key).should eq(AliroLock::StatusCode::Success)
    document = first.save_state.as(Matter::Storage::Document)

    reader = TestAliroReader.new
    restored = aliro_delegate_lock(reader)
    restored.restore_state(document)
    reader.configured.try(&.verification_key).should eq(signing.public_key)
    reader.authenticated = AliroLock::AliroAuthenticatedAccess.new(endpoint.public_key)
    restored.perform_aliro_transaction(Bytes[0x01]).status.should eq(Matter::InteractionModel::StatusCode::Success)

    rejecting = TestAliroReader.new
    rejecting.accept_config = false
    failed = aliro_delegate_lock(rejecting)
    failed.restore_state(document)
    failed.feature_map.aliro_provisioning?.should be_false
    failed.aliro_key_data(AliroLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16).should be_nil
  end
end
