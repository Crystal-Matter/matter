require "../spec_helper"

private alias AccountLogin = Matter::Cluster::AccountLogin
private alias AccountStatus = Matter::InteractionModel::StatusCode

private class TestAccountHost < AccountLogin::Host
  getter logins = [] of Tuple(String, String, UInt64?, UInt8)
  getter logouts = [] of Tuple(UInt64?, UInt8)

  def setup_pin(identifier : String, fabric_index : UInt8) : String?
    "12345678" if identifier == "A" * 16 && fabric_index == 1_u8
  end

  def login(identifier : String, pin : String, node : UInt64?, fabric_index : UInt8) : Bool
    @logins << {identifier, pin, node, fabric_index}
    identifier == "A" * 16 && pin == "12345678" && fabric_index == 1_u8
  end

  def logout(node : UInt64?, fabric_index : UInt8) : Bool
    @logouts << {node, fabric_index}
    true
  end
end

private def setup_pin_result(cluster : AccountLogin, identifier : String, fabric_index : UInt8 = 1_u8)
  invoke(cluster, AccountLogin::CMD_GET_SETUP_PIN,
    AccountLogin::GetSetupPinRequest.new(identifier), is_case_session: true, fabric_index: fabric_index)
end

describe AccountLogin do
  it "declares revision-two commands, timed access, and typed payloads" do
    cluster = build(AccountLogin, host: TestAccountHost.new)
    cluster.cluster_id.id.should eq(0x050E_u32)
    cluster.cluster_revision.should eq(2_u16)
    accepted_command_ids(cluster).should eq([
      AccountLogin::CMD_GET_SETUP_PIN, AccountLogin::CMD_LOGIN, AccountLogin::CMD_LOGOUT,
    ])
    generated_command_ids(cluster).should eq([AccountLogin::CMD_GET_SETUP_PIN_RESPONSE])
    [AccountLogin::CMD_GET_SETUP_PIN, AccountLogin::CMD_LOGIN].each do |id|
      metadata = cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata)
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
      metadata.timed?.should be_true
    end
    logout = cluster.get_command_metadata(AccountLogin::CMD_LOGOUT).as(Matter::Cluster::CommandMetadata)
    logout.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    logout.timed?.should be_true
    AccountLogin::LoginRequest.new("A" * 16, "12345678", 123_u64).to_tlv(nil).as_structure.keys
      .should eq([0_u8, 1_u8, 2_u8])
    AccountLogin::LogoutRequest.new(nil).to_tlv(nil).as_structure.should be_empty
  end

  it "uses the host account provider and keeps events scoped to the caller fabric" do
    host = TestAccountHost.new
    cluster = build(AccountLogin, host: host)
    event_fabrics = [] of UInt8?
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, fabric : UInt8?) do
      event_fabrics << fabric
      nil
    end
    response = setup_pin_result(cluster, "A" * 16).as(Matter::Cluster::CommandResponse)
    AccountLogin::GetSetupPinResponse.from_tlv(response.response.as(TLV::Any)).setup_pin.should eq("12345678")
    mismatch = setup_pin_result(cluster, "B" * 16).as(Matter::Cluster::CommandResponse)
    AccountLogin::GetSetupPinResponse.from_tlv(mismatch.response.as(TLV::Any)).setup_pin.should eq("")
    expect_status(invoke(cluster, AccountLogin::CMD_LOGIN,
      AccountLogin::LoginRequest.new("A" * 16, "12345678", 123_u64),
      is_case_session: true, fabric_index: 1_u8), AccountStatus::Success)
    expect_status(invoke(cluster, AccountLogin::CMD_LOGIN,
      AccountLogin::LoginRequest.new("A" * 16, "87654321", nil),
      is_case_session: true, fabric_index: 1_u8), AccountStatus::Failure)
    expect_status(invoke(cluster, AccountLogin::CMD_LOGOUT,
      AccountLogin::LogoutRequest.new(123_u64),
      is_case_session: true, fabric_index: 1_u8), AccountStatus::Success)
    host.logins.last.should eq({"A" * 16, "87654321", nil, 1_u8})
    host.logouts.should eq([{123_u64, 1_u8}])
    event_fabrics.should eq([1_u8])
  end

  it "requires CASE, validates credentials, and rate-limits unique requests" do
    now = Time.unix_ms(1_700_000_000_000_i64)
    clock = -> { now }
    cluster = build(AccountLogin, host: TestAccountHost.new, clock: clock)
    expect_status(invoke(cluster, AccountLogin::CMD_GET_SETUP_PIN,
      AccountLogin::GetSetupPinRequest.new("A" * 16)), AccountStatus::UnsupportedAccess)
    expect_status(setup_pin_result(cluster, "short"), AccountStatus::InvalidCommand)
    expect_status(invoke(cluster, AccountLogin::CMD_LOGIN,
      AccountLogin::LoginRequest.new("A" * 16, "1234567", nil),
      is_case_session: true, fabric_index: 1_u8), AccountStatus::InvalidCommand)
    10.times do |index|
      setup_pin_result(cluster, "A" * 15 + index.to_s).should be_a(Matter::Cluster::CommandResponse)
    end
    expect_status(setup_pin_result(cluster, "A" * 15 + "10"), AccountStatus::Failure)
    setup_pin_result(cluster, "A" * 15 + "0").should be_a(Matter::Cluster::CommandResponse)
    restored = build(AccountLogin, host: TestAccountHost.new, clock: clock)
    restored.restore_state(cluster.save_state || fail("Account Login limiter state missing"))
    expect_status(setup_pin_result(restored, "A" * 15 + "10"), AccountStatus::Failure)
    now += 601.seconds
    setup_pin_result(restored, "A" * 15 + "10").should be_a(Matter::Cluster::CommandResponse)
  end
end
