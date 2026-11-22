require "../spec_helper"

private alias FabricAccountLogin = Matter::Cluster::AccountLogin
private alias FabricAccountStatus = Matter::InteractionModel::StatusCode

private class RecordingAccountHost < FabricAccountLogin::Host
  getter calls = [] of Symbol

  def setup_pin(identifier : String, fabric_index : UInt8) : String?
    @calls << :setup_pin
    "12345678"
  end

  def login(identifier : String, pin : String, node : UInt64?, fabric_index : UInt8) : Bool
    @calls << :login
    true
  end

  def logout(node : UInt64?, fabric_index : UInt8) : Bool
    @calls << :logout
    true
  end
end

describe "Account Login fabric-scoped command dispatch" do
  [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |invalid_fabric|
    it "rejects all three commands on reserved fabric #{invalid_fabric} before hooks and host calls" do
      host = RecordingAccountHost.new
      cluster = build(FabricAccountLogin, host: host)
      command_hooks = 0
      events = 0
      cluster.on_before_command = ->(_command : UInt32) { command_hooks += 1; nil }
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
        events += 1
        nil
      end
      before_state = cluster.save_state
      before_version = cluster.data_version

      results = [
        invoke(cluster, FabricAccountLogin::CMD_GET_SETUP_PIN,
          FabricAccountLogin::GetSetupPinRequest.new("A" * 16),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricAccountLogin::CMD_LOGIN,
          FabricAccountLogin::LoginRequest.new("A" * 16, "12345678"),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricAccountLogin::CMD_LOGOUT,
          FabricAccountLogin::LogoutRequest.new,
          is_case_session: true, fabric_index: invalid_fabric),
      ]

      results.each { |result| expect_status(result, FabricAccountStatus::UnsupportedAccess) }
      host.calls.should be_empty
      command_hooks.should eq(0)
      events.should eq(0)
      cluster.save_state.should eq(before_state)
      cluster.data_version.should eq(before_version)
    end
  end

  [Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX].each do |fabric|
    it "allows a valid CASE Logout on fabric #{fabric}" do
      host = RecordingAccountHost.new
      cluster = build(FabricAccountLogin, host: host)
      event_fabrics = [] of UInt8?
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, event_fabric : UInt8?) do
        event_fabrics << event_fabric
        nil
      end

      expect_status(invoke(cluster, FabricAccountLogin::CMD_LOGOUT,
        FabricAccountLogin::LogoutRequest.new, is_case_session: true, fabric_index: fabric),
        FabricAccountStatus::Success)

      host.calls.should eq([:logout])
      event_fabrics.should eq([fabric])
    end
  end

  it "rejects host-initiated LoggedOut events for reserved fabrics" do
    cluster = build(FabricAccountLogin, host: RecordingAccountHost.new)
    events = 0
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events += 1
      nil
    end

    [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |fabric|
      expect_raises(ArgumentError) { cluster.notify_logged_out(nil, fabric) }
    end
    events.should eq(0)
  end
end
