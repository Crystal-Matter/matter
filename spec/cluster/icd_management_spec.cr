require "../spec_helper"
require "../../src/matter/cluster/icd_management"

alias Icd = Matter::Cluster::IcdManagement

private def icd_register(
  cluster : Icd,
  node_id : UInt64,
  key : Bytes,
  fabric : UInt8 = 1_u8,
  verification_key : Bytes? = nil,
  administrator : Bool = false,
) : Matter::Cluster::CommandResponse | Matter::InteractionModel::Status
  cluster.request_administer_privilege = administrator
  request = Icd::RegisterClientRequest.new(node_id, node_id, key, verification_key, Icd::ClientType::Permanent)
  cluster.invoke_command(Icd::CMD_REGISTER_CLIENT, request.to_tlv(nil),
    is_case_session: true, fabric_index: fabric)
end

describe Matter::Cluster::IcdManagement do
  key_a = Bytes.new(16, 0x01_u8)
  key_b = Bytes.new(16, 0x02_u8)

  it "exposes feature-gated Matter 1.6 metadata and wire tags" do
    sit = Icd.new
    sit.get_attribute_metadata(Icd::ATTR_REGISTERED_CLIENTS).should be_nil
    sit.get_command_metadata(Icd::CMD_REGISTER_CLIENT).should be_nil
    sit.get_command_metadata(Icd::CMD_STAY_ACTIVE_REQUEST).should_not be_nil

    cip = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport)
    cip.get_attribute_metadata(Icd::ATTR_REGISTERED_CLIENTS).as(Matter::Cluster::AttributeMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    cip.get_attribute_metadata(Icd::ATTR_ICD_COUNTER).should_not be_nil
    cip.get_attribute_metadata(Icd::ATTR_ICD_COUNTER).as(Matter::Cluster::AttributeMetadata).omit_changes?
      .should be_true
    cip.get_command_metadata(Icd::CMD_REGISTER_CLIENT).as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    cip.get_command_metadata(Icd::CMD_UNREGISTER_CLIENT).should_not be_nil
    cip.get_attribute_metadata(Icd::ATTR_OPERATING_MODE).should be_nil
    cip.events.should be_empty # The Matter 1.6 ICD cluster declares no wire events.

    long_idle = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport |
                                     Icd::Feature::LongIdleTimeSupport |
                                     Icd::Feature::UserActiveModeTrigger,
      active_mode_threshold: 5_000_u16)
    long_idle.get_attribute_metadata(Icd::ATTR_OPERATING_MODE).should_not be_nil
    long_idle.get_attribute_metadata(Icd::ATTR_USER_ACTIVE_MODE_TRIGGER_HINT).should_not be_nil

    expect_raises(ArgumentError) do
      Icd.new(feature_map: Icd::Feature::LongIdleTimeSupport)
    end

    request = Icd::RegisterClientRequest.new(123_u64, 456_u64, key_a, nil, Icd::ClientType::Permanent)
    decoded = Icd::RegisterClientRequest.from_tlv(request.to_tlv(nil))
    decoded.check_in_node_id.should eq(123_u64)
    decoded.monitored_subject.should eq(456_u64)
    decoded.key.should eq(key_a)
    decoded.client_type.should eq(Icd::ClientType::Permanent)
  end

  it "isolates registrations per fabric and enforces quota, verification and statuses" do
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport,
      clients_supported_per_fabric: 1_u16)

    response = icd_register(cluster, 123_u64, key_a)
      .as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(Icd::CMD_REGISTER_CLIENT_RESPONSE)
    Icd::RegisterClientResponse.from_tlv(response.response.as(TLV::Any)).icd_counter
      .should eq(cluster.icd_counter)

    icd_register(cluster, 124_u64, key_a).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
    icd_register(cluster, 125_u64, Bytes.new(15, 0_u8), fabric: 2_u8)
      .as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    icd_register(cluster, 123_u64, key_b).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::Failure)
    icd_register(cluster, 123_u64, key_b, verification_key: key_a)
      .should be_a(Matter::Cluster::CommandResponse)
    icd_register(cluster, 123_u64, key_a, fabric: 2_u8)
      .should be_a(Matter::Cluster::CommandResponse)

    cluster.request_fabric_index = nil
    cluster.registered_clients.should be_empty

    cluster.request_fabric_index = 1_u8
    cluster.registered_clients.map(&.check_in_node_id).should eq([123_u64])
    cluster.request_fabric_filtered = false
    cluster.registered_clients.size.should eq(2)
    cluster.request_fabric_filtered = true
    cluster.request_fabric_index = 2_u8
    cluster.registered_clients.map(&.check_in_node_id).should eq([123_u64])

    request = Icd::UnregisterClientRequest.new(123_u64, nil)
    cluster.request_administer_privilege = false
    cluster.invoke_command(Icd::CMD_UNREGISTER_CLIENT, request.to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::Failure)

    cluster.request_administer_privilege = true
    cluster.invoke_command(Icd::CMD_UNREGISTER_CLIENT, request.to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.request_fabric_index = 1_u8
    cluster.registered_clients.should be_empty
    cluster.request_fabric_index = 2_u8
    cluster.registered_clients.size.should eq(1)
  end

  it "checks in for a permanent client on an application-driven idle-to-active transition" do
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport,
      idle_mode_duration: 60_u32, active_mode_duration: 3_000_u32,
      active_mode_threshold: 5_000_u16, counter_seed: 10_u32)
    icd_register(cluster, 123_u64, key_a).should be_a(Matter::Cluster::CommandResponse)
    delivered = [] of Tuple(UInt8, UInt64, Bytes, UInt32, UInt16)
    cluster.on_check_in = ->(fabric : UInt8, node : UInt64, key : Bytes, counter : UInt32, threshold : UInt16) do
      delivered << {fabric, node, key, counter, threshold}
      nil
    end

    cluster.enter_idle_mode
    cluster.request_active_mode
    delivered.size.should eq(1)
    delivered.first[0].should eq(1_u8)
    delivered.first[1].should eq(123_u64)
    delivered.first[2].should eq(key_a)
    delivered.first[4].should eq(5_000_u16)
    cluster.icd_counter.should eq(delivered.first[3])
    cluster.request_active_mode
    delivered.size.should eq(1) # Only the idle-to-active edge sends Check-In.
  end

  it "persists keys and counter, bumps counter at restart, and removes a fabric" do
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport, counter_seed: 10_u32)
    icd_register(cluster, 123_u64, key_a).should be_a(Matter::Cluster::CommandResponse)
    initial_counter = cluster.icd_counter
    saved = cluster.save_state.as(Matter::Storage::Document)

    restored = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport)
    restored.restore_state(saved)
    restored.icd_counter.should be > initial_counter
    restored.request_fabric_index = 1_u8
    restored.registered_clients.size.should eq(1)
    restored.check_in_key(1_u8, 123_u64).should eq(key_a)

    restored.remove_fabric(1_u8)
    restored.registered_clients.should be_empty
    restored.check_in_key(1_u8, 123_u64).should be_nil
    again = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport)
    again.restore_state(restored.save_state.as(Matter::Storage::Document))
    again.request_fabric_index = 1_u8
    again.registered_clients.should be_empty
  end

  it "returns a bounded StayActive promise and rejects invalid timing" do
    expect_raises(ArgumentError) { Icd.new(idle_mode_duration: 1_u32, active_mode_duration: 2_000_u32) }
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport,
      idle_mode_duration: 60_u32, active_mode_duration: 3_000_u32)
    response = cluster.invoke_command(Icd::CMD_STAY_ACTIVE_REQUEST,
      Icd::StayActiveRequest.new(5_000_u32).to_tlv(nil), is_case_session: true)
      .as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(Icd::CMD_STAY_ACTIVE_RESPONSE)
    Icd::StayActiveResponse.from_tlv(response.response.as(TLV::Any)).promised_active_duration
      .should be >= 5_000_u32
  end

  it "changes a long-idle device from SIT to LIT with registrations" do
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport |
                                   Icd::Feature::UserActiveModeTrigger |
                                   Icd::Feature::LongIdleTimeSupport,
      idle_mode_duration: 60_u32,
      active_mode_duration: 3_000_u32,
      active_mode_threshold: 5_000_u16)
    cluster.operating_mode.should eq(Icd::OperatingMode::Sit)
    icd_register(cluster, 123_u64, key_a).should be_a(Matter::Cluster::CommandResponse)
    cluster.operating_mode.should eq(Icd::OperatingMode::Lit)
    cluster.request_administer_privilege = true
    cluster.invoke_command(Icd::CMD_UNREGISTER_CLIENT,
      Icd::UnregisterClientRequest.new(123_u64, nil).to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8)
    cluster.operating_mode.should eq(Icd::OperatingMode::Sit)
  end

  it "backs off Check-Ins per permanent client and resets after a user trigger" do
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport |
                                   Icd::Feature::UserActiveModeTrigger,
      idle_mode_duration: 60_u32, maximum_check_in_backoff: 240_u32,
      active_mode_duration: 3_000_u32)
    icd_register(cluster, 123_u64, key_a).should be_a(Matter::Cluster::CommandResponse)
    counters = [] of UInt32
    cluster.on_check_in = ->(_fabric : UInt8, _node : UInt64, _key : Bytes, counter : UInt32, _threshold : UInt16) do
      counters << counter
      nil
    end
    5.times do
      cluster.enter_idle_mode
      cluster.request_active_mode
    end
    counters.size.should eq(3) # wakes 1, 2, and 4
    cluster.enter_idle_mode
    cluster.trigger_user_active_mode
    counters.size.should eq(4)
    cluster.on_monitored_subject_covered = ->(_fabric : UInt8, _subject : UInt64) { true }
    cluster.enter_idle_mode
    cluster.request_active_mode
    counters.size.should eq(4)
  end

  it "does not acknowledge a registration whose durable write fails" do
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport)
    cluster.on_persist_registration = -> { false }
    icd_register(cluster, 123_u64, key_a).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.request_fabric_index = 1_u8
    cluster.registered_clients.should be_empty
  end

  it "honors a StayActive promise before an application can enter idle" do
    cluster = Icd.new(feature_map: Icd::Feature::CheckInProtocolSupport,
      idle_mode_duration: 60_u32, active_mode_duration: 3_000_u32)
    icd_register(cluster, 123_u64, key_a).should be_a(Matter::Cluster::CommandResponse)
    sent = 0
    cluster.on_check_in = ->(_fabric : UInt8, _node : UInt64, _key : Bytes, _counter : UInt32, _threshold : UInt16) do
      sent += 1
      nil
    end
    cluster.stay_active_request(Icd::StayActiveRequest.new(5_000_u32))
    cluster.enter_idle_mode
    cluster.request_active_mode
    sent.should eq(0)
  end

  it "allows explicit operating mode changes only with DSLS" do
    features = Icd::Feature::CheckInProtocolSupport |
               Icd::Feature::UserActiveModeTrigger |
               Icd::Feature::LongIdleTimeSupport
    static_mode = Icd.new(feature_map: features, active_mode_threshold: 5_000_u16)
    expect_raises(ArgumentError) { static_mode.force_operating_mode(Icd::OperatingMode::Lit) }
    dynamic = Icd.new(feature_map: features | Icd::Feature::DynamicSitLitSupport,
      active_mode_threshold: 5_000_u16)
    dynamic.operating_mode.should eq(Icd::OperatingMode::Sit)
    dynamic.force_operating_mode(Icd::OperatingMode::Lit)
    dynamic.operating_mode.should eq(Icd::OperatingMode::Lit)
    dynamic.withdraw_forced_operating_mode
    dynamic.operating_mode.should eq(Icd::OperatingMode::Sit)
  end

  it "requires user instructions for trigger hints that need them" do
    expect_raises(ArgumentError) do
      Icd.new(feature_map: Icd::Feature::UserActiveModeTrigger,
        user_active_mode_trigger_hint: 1_u32 << 2)
    end
    Icd.new(feature_map: Icd::Feature::UserActiveModeTrigger,
      user_active_mode_trigger_hint: 1_u32 << 2,
      user_active_mode_trigger_instruction: "Press the silver button")
      .user_active_mode_trigger_instruction.should eq("Press the silver button")
  end
end
