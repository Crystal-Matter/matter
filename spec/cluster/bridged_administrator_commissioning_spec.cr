require "../spec_helper"
require "../../src/matter/cluster/bridged_administrator_commissioning"

describe Matter::Cluster::BridgedAdministratorCommissioning do
  alias Admin = Matter::Cluster::BridgedAdministratorCommissioning
  alias RootAdmin = Matter::Cluster::AdministratorCommissioning
  alias Status = Matter::InteractionModel::Status

  it "forwards mandatory timed commands with the remote target and authenticated caller fabric" do
    calls = [] of String
    open = ->(target_fabric : UInt8, target_node : UInt64, caller_fabric : UInt8, request : RootAdmin::OpenCommissioningWindowRequest) do
      calls << "open:#{target_fabric}:#{target_node}:#{caller_fabric}:#{request.discriminator}"
      Status.success
    end
    revoke = ->(target_fabric : UInt8, target_node : UInt64, caller_fabric : UInt8) do
      calls << "revoke:#{target_fabric}:#{target_node}:#{caller_fabric}"
      Status.success
    end
    cluster = Admin.new(Matter::DataType::EndpointNumber.new(2_u16),
      target_fabric_index: 3_u8, target_node_id: 0x1234_u64,
      on_open: open, on_revoke: revoke)
    request = RootAdmin::OpenCommissioningWindowRequest.new(
      RootAdmin::MINIMUM_COMMISSIONING_TIMEOUT,
      Bytes.new(RootAdmin::PAKE_PASSCODE_VERIFIER_LENGTH),
      3840_u16, RootAdmin::PBKDF2_MIN_ITERATIONS,
      Bytes.new(RootAdmin::PAKE_SALT_MIN_LENGTH))

    cluster.get_command_metadata(Admin::CMD_OPEN_COMMISSIONING_WINDOW).not_nil!.timed?.should be_true
    cluster.get_command_metadata(Admin::CMD_REVOKE_COMMISSIONING).not_nil!.timed?.should be_true
    cluster.invoke_command(Admin::CMD_OPEN_COMMISSIONING_WINDOW, request.to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8).should eq(Status.success)
    cluster.invoke_command(Admin::CMD_REVOKE_COMMISSIONING,
      is_case_session: true, fabric_index: 2_u8).should eq(Status.success)
    calls.should eq(["open:3:4660:1:3840", "revoke:3:4660:2"])
    cluster.window_status.should eq(RootAdmin::CommissioningWindowStatus::WindowNotOpen)
    cluster.admin_fabric_index.should be_nil
    cluster.admin_vendor_id.should be_nil
    cluster.get_command_metadata(RootAdmin::CMD_OPEN_BASIC_COMMISSIONING_WINDOW).should be_nil
  end

  it "rejects requests without an authenticated CASE fabric before reaching the host" do
    calls = 0
    cluster = Admin.new(Matter::DataType::EndpointNumber.new(2_u16),
      target_fabric_index: 3_u8, target_node_id: 0x1234_u64,
      on_open: ->(_tf : UInt8, _tn : UInt64, _cf : UInt8, _r : RootAdmin::OpenCommissioningWindowRequest) { calls += 1; Status.success },
      on_revoke: ->(_tf : UInt8, _tn : UInt64, _cf : UInt8) { calls += 1; Status.success })
    cluster.invoke_command(Admin::CMD_REVOKE_COMMISSIONING, fabric_index: 1_u8).should eq(Status.unsupported_access)
    cluster.invoke_command(Admin::CMD_REVOKE_COMMISSIONING, is_case_session: true).should eq(Status.unsupported_access)
    calls.should eq(0)
  end

  it "publishes only host supplied remote window state" do
    cluster = Admin.new(Matter::DataType::EndpointNumber.new(2_u16),
      target_fabric_index: 3_u8, target_node_id: 0x1234_u64,
      on_open: ->(_tf : UInt8, _tn : UInt64, _cf : UInt8, _r : RootAdmin::OpenCommissioningWindowRequest) { Status.failure },
      on_revoke: ->(_tf : UInt8, _tn : UInt64, _cf : UInt8) { Status.failure })
    cluster.publish_remote_window_state(RootAdmin::CommissioningWindowStatus::EnhancedWindowOpen,
      1_u8, 0xFFF1_u16)
    cluster.window_status.should eq(RootAdmin::CommissioningWindowStatus::EnhancedWindowOpen)
    cluster.admin_fabric_index.should eq(1_u8)
    cluster.admin_vendor_id.should eq(0xFFF1_u16)
    cluster.publish_remote_window_state(RootAdmin::CommissioningWindowStatus::WindowNotOpen, nil, nil)
    cluster.admin_fabric_index.should be_nil
    cluster.admin_vendor_id.should be_nil
  end

  it "refuses reserved remote target identities" do
    open = ->(_tf : UInt8, _tn : UInt64, _cf : UInt8, _r : RootAdmin::OpenCommissioningWindowRequest) { Status.success }
    revoke = ->(_tf : UInt8, _tn : UInt64, _cf : UInt8) { Status.success }
    expect_raises(ArgumentError, /target fabric index/) do
      Admin.new(Matter::DataType::EndpointNumber.new(2_u16),
        target_fabric_index: 0_u8, target_node_id: Matter::DataType::NodeId::OPERATIONAL_MINIMUM,
        on_open: open, on_revoke: revoke)
    end
    expect_raises(ArgumentError, /target node ID/) do
      Admin.new(Matter::DataType::EndpointNumber.new(2_u16),
        target_fabric_index: Matter::Fabric::MIN_FABRIC_INDEX,
        target_node_id: Matter::DataType::NodeId::UNSPECIFIED,
        on_open: open, on_revoke: revoke)
    end
  end
end
