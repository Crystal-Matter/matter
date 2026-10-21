require "../../spec/spec_helper"
require "../../examples/support/joint_fabric_administrator_device"

private alias JfaDevice = MatterJointFabricAdministrator::Device
private alias CommissioningCluster = Matter::Cluster::GeneralCommissioning

class FinalizationProbeDevice < JfaDevice
  def finalize_for_spec(request : JfaDevice::CommandRequest) : Bytes?
    finalize_commissioning(request)
  end

  def jcm_parameters_for_spec(request : JfaDevice::CommandRequest) : {Bytes, UInt16}
    joint_handoff_parameters(request)
  end

  def check_complete_for_spec(response : Matter::InteractionModel::InvokeResponseMessage) : Nil
    assert_standard_commissioning_complete!(response)
  end

  def verify_anchor_session_for_spec(session : Matter::Session::SecureContext) : Nil
    verify_new_anchor_session!(session)
  end

  def simulate_current_subscription_for_spec(fabric_id : UInt64, root_public_key : Bytes) : Nil
    @participant_view_current = true
    @subscribed_fabric_id = fabric_id
    @subscribed_root_public_key = root_public_key
  end

  def replace_subscribed_fabric_for_spec(fabric_id : UInt64, root_public_key : Bytes) : Nil
    invalidate_new_anchor_subscription_unless(fabric_id, root_public_key)
  end

  def remove_fabric_for_spec(index : UInt8) : Nil
    fabric_removed(index)
  end

  def participant_view_current_for_spec : Bool
    @participant_view_current
  end

  def open_joint_window_for_spec(request : JfaDevice::Admin::OpenJointCommissioningWindowRequest,
                                 fabric : Matter::Fabric) : Matter::InteractionModel::Status
    open_joint_window(request, fabric)
  end
end

private def completion_response(error : Matter::Commissioning::ErrorCode) : Matter::InteractionModel::InvokeResponseMessage
  path = Matter::InteractionModel::CommandPath.new(endpoint: 0_u16, cluster: CommissioningCluster::CLUSTER_ID,
    command: CommissioningCluster::CMD_COMMISSIONING_COMPLETE_RESPONSE)
  fields = TLV::Any.from_slice(CommissioningCluster::CommissioningCompleteResponse.new(error).to_slice)
  data = Matter::InteractionModel::CommandDataIBTlv.new(path, fields)
  Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
    Matter::InteractionModel::InvokeResponseIB.new(command_data: data),
  ])
end

describe "SDK JFC standard ownership handoff command" do
  it "round trips its fabric selector and nonce through the device YAML record" do
    key = Bytes.new(65, 7_u8)
    request = JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
      fabric_id: 41216_u64, root_public_key: key, nonce: "request-123", jcm: false)
    restored = JfaDevice::CommandRequest.from_document(request.to_document)
    restored.operation.should eq("finalize-commissioning")
    restored.node_id.should eq(42_u64)
    restored.fabric_id.should eq(41216_u64)
    restored.root_public_key.should eq(key)
    restored.nonce.should eq("request-123")
    restored.jcm?.should be_false

    jcm_request = JfaDevice::CommandRequest.new("finalize-commissioning", 43_u64,
      fabric_id: 41216_u64, root_public_key: key, nonce: "request-456", jcm: true,
      trusted_icac_public_key_b: Bytes[4_u8] + Bytes.new(64, 7_u8),
      peer_admin_jfa_endpoint_id: 1_u16)
    jcm_restored = JfaDevice::CommandRequest.from_document(jcm_request.to_document)
    jcm_restored.jcm?.should be_true
    jcm_restored.trusted_icac_public_key_b.should eq(jcm_request.trusted_icac_public_key_b)
    jcm_restored.peer_admin_jfa_endpoint_id.should eq(1_u16)
  end

  it "round trips final handoff certificate with the successful nonce" do
    certificate = Bytes[0x15_u8, 0x30_u8, 0x01_u8]
    result = JfaDevice::CommandResult.new("ok", nonce: "request-456", certificate: certificate)
    restored = JfaDevice::CommandResult.from_document(result.to_document)
    restored.status.should eq("ok")
    restored.nonce.should eq("request-456")
    restored.certificate.should eq(certificate)

    failure = JfaDevice::CommandResult.new("error", "CommissioningComplete failed", nonce: "request-456")
    JfaDevice::CommandResult.from_document(failure.to_document).certificate.should be_nil
  end

  it "persists authenticated transfer requester separately from provisioned new Anchor identity" do
    root = Bytes.new(65, 3_u8)
    watch = JfaDevice::TransferWatchState.new(0xA103_u64, 0xA100_u64, root, 0xB102_u64)
    restored = JfaDevice::TransferWatchState.from_document(watch.to_document)
    restored.requester_node_id.should eq(0xA103_u64)
    restored.old_fabric_id.should eq(0xA100_u64)
    restored.old_root_public_key.should eq(root)
    restored.new_anchor_node_id.should eq(0xB102_u64)

    result = JfaDevice::CommandResult.new("ok", nonce: "inspect-1", subscription_committed: false)
    JfaDevice::CommandResult.from_document(result.to_document).subscription_committed.should be_false
  end

  it "rejects stale or unauthenticated new Anchor CASE identity" do
    device = FinalizationProbeDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    session = Matter::Session::SecureContext.new(1_u16, 2_u16,
      Matter::Session::SessionType::Unicast, Bytes.new(16), Bytes.new(16), case_session: true)
    expect_raises(Matter::AuthenticationError, /Anchor CAT/) do
      device.verify_anchor_session_for_spec(session)
    end
    session.peer_subject_ids = [Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(0xFFFE_u16, 1_u16)).id]
    expect_raises(Matter::AuthenticationError, /lacks ICAC/) do
      device.verify_anchor_session_for_spec(session)
    end
  end

  it "invalidates a committed view when the subscribed fabric changes or is removed" do
    device = FinalizationProbeDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    root = Bytes.new(65, 4_u8)
    device.simulate_current_subscription_for_spec(0xB100_u64, root)
    device.replace_subscribed_fabric_for_spec(0xB100_u64, root)
    device.participant_view_current_for_spec.should be_true
    device.replace_subscribed_fabric_for_spec(0xC100_u64, root)
    device.participant_view_current_for_spec.should be_false

    device.simulate_current_subscription_for_spec(0xB100_u64, root)
    device.remove_fabric_for_spec(1_u8)
    device.participant_view_current_for_spec.should be_false
  end

  it "denies Joint Commissioning from a former Anchor even with local consent" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB100_u64, 0xB101_u64, 0xFFF1_u16)
    identity = bootstrap.fabric
    fabric = Matter::Fabric.new(identity.fabric_id, 1_u8, identity.controller_node_id,
      identity.root_public_key, identity.controller_noc,
      Matter::Crypto.private_key(identity.controller_private_key),
      identity.ipk_value, intermediate_cert: identity.intermediate_cert,
      root_cert: identity.root_cert)
    request = JfaDevice::Admin::OpenJointCommissioningWindowRequest.new(
      60_u16, Bytes.empty, 1_u16, 1000_u32, Bytes.empty)
    device = FinalizationProbeDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    previous = ENV["MATTER_JFA_ALLOW_JCM"]?
    ENV["MATTER_JFA_ALLOW_JCM"] = "1"
    status = device.open_joint_window_for_spec(request, fabric)
    status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
  ensure
    if previous
      ENV["MATTER_JFA_ALLOW_JCM"] = previous
    else
      ENV.delete("MATTER_JFA_ALLOW_JCM")
    end
  end

  it "validates JCM handoff public key and endpoint before network activity" do
    device = FinalizationProbeDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    key = Bytes.new(65, 0_u8)
    key[0] = 4_u8
    valid = JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
      nonce: "request-123", jcm: true, trusted_icac_public_key_b: key,
      peer_admin_jfa_endpoint_id: 1_u16)
    device.jcm_parameters_for_spec(valid).should eq({key, 1_u16})

    expect_raises(Matter::ConfigurationError, /authenticated Administrator ICAC public key/) do
      device.jcm_parameters_for_spec(JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
        nonce: "request-123", jcm: true, peer_admin_jfa_endpoint_id: 1_u16))
    end
    expect_raises(Matter::AuthenticationError, /uncompressed P-256/) do
      device.jcm_parameters_for_spec(JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
        nonce: "request-123", jcm: true, trusted_icac_public_key_b: Bytes.new(64, 4_u8),
        peer_admin_jfa_endpoint_id: 1_u16))
    end
    bad_prefix = key.dup
    bad_prefix[0] = 3_u8
    expect_raises(Matter::AuthenticationError, /uncompressed P-256/) do
      device.jcm_parameters_for_spec(JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
        nonce: "request-123", jcm: true, trusted_icac_public_key_b: bad_prefix,
        peer_admin_jfa_endpoint_id: 1_u16))
    end
    expect_raises(Matter::ConfigurationError, /peer Administrator endpoint/) do
      device.jcm_parameters_for_spec(JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
        nonce: "request-123", jcm: true, trusted_icac_public_key_b: key))
    end
    expect_raises(Matter::ConfigurationError, /endpoint is invalid/) do
      device.jcm_parameters_for_spec(JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
        nonce: "request-123", jcm: true, trusted_icac_public_key_b: key,
        peer_admin_jfa_endpoint_id: UInt16::MAX))
    end
  end

  it "rejects unauthenticated standard requests before network activity" do
    device = FinalizationProbeDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    expect_raises(Matter::ConfigurationError, /nonce is required/) do
      device.finalize_for_spec(JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64))
    end
    expect_raises(Matter::ConfigurationError, /Anchor fabric is unavailable/) do
      device.finalize_for_spec(JfaDevice::CommandRequest.new("finalize-commissioning", 42_u64,
        nonce: "request-123"))
    end
  end

  it "requires a successful CommissioningComplete command response" do
    device = FinalizationProbeDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.check_complete_for_spec(completion_response(Matter::Commissioning::ErrorCode::OK))
    expect_raises(Matter::CommissioningError, /NoFailSafe/) do
      device.check_complete_for_spec(completion_response(Matter::Commissioning::ErrorCode::NoFailSafe))
    end
  end
end
