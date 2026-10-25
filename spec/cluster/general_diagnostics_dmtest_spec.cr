require "../spec_helper"
require "../../src/matter/cluster/general_diagnostics"

private alias Diagnostics = Matter::Cluster::GeneralDiagnostics

private struct PayloadTestWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter payload : Bytes
end

describe Diagnostics do
  key = Bytes[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

  it "keeps DMTEST disabled unless a nonzero test key is supplied" do
    cluster = build(Diagnostics, 0)
    cluster.feature_map.value.should eq(0)
    cluster.test_event_triggers_enabled?.should be_false
    cluster.get_command_metadata(Diagnostics::CMD_PAYLOAD_TEST_REQUEST).should be_nil

    expect_raises(ArgumentError) { build(Diagnostics, 0, test_enable_key: Bytes.new(15, 1_u8)) }
    expect_raises(ArgumentError) { build(Diagnostics, 0, test_enable_key: Bytes.new(16, 0_u8)) }
  end

  it "advertises the Manage-only request and returns a bounded repeated-byte payload" do
    cluster = build(Diagnostics, 0, test_enable_key: key)
    cluster.feature_map.data_model_test?.should be_true
    cluster.test_event_triggers_enabled?.should be_true
    cluster.get_command_metadata(Diagnostics::CMD_PAYLOAD_TEST_REQUEST).as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Manage)

    {0_u16, 1_u16, 2048_u16}.each do |count|
      request = Diagnostics::PayloadTestRequest.new(key, 0xAB_u8, count)
      result = invoke(cluster, Diagnostics::CMD_PAYLOAD_TEST_REQUEST, request).as(Matter::Cluster::CommandResponse)
      result.command_id.should eq(Diagnostics::CMD_PAYLOAD_TEST_REQUEST_RESPONSE)
      wire = result.response.as(TLV::Any)
      wire.as_structure.keys.should eq([0_u8])
      PayloadTestWire.from_tlv(wire).payload.should eq(Bytes.new(count, 0xAB_u8))
    end
  end

  it "rejects wrong keys and oversized payloads without creating a response" do
    cluster = build(Diagnostics, 0, test_enable_key: key)
    bad_key = Bytes.new(16, 0xAA_u8)
    expect_status(invoke(cluster, Diagnostics::CMD_PAYLOAD_TEST_REQUEST,
      Diagnostics::PayloadTestRequest.new(bad_key, 1_u8, 4_u16)), Matter::InteractionModel::StatusCode::ConstraintError)
    expect_status(invoke(cluster, Diagnostics::CMD_PAYLOAD_TEST_REQUEST,
      Diagnostics::PayloadTestRequest.new(key, 1_u8, 2049_u16)), Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "copies the configured key so callers cannot mutate the enable gate" do
    mutable_key = key.dup
    cluster = build(Diagnostics, 0, test_enable_key: mutable_key)
    mutable_key[0] = 0xFF_u8
    response = invoke(cluster, Diagnostics::CMD_PAYLOAD_TEST_REQUEST,
      Diagnostics::PayloadTestRequest.new(key, 0_u8, 1_u16))
    response.should be_a(Matter::Cluster::CommandResponse)
  end

  it "uses the same key gate for TestEventTrigger" do
    cluster = build(Diagnostics, 0, test_enable_key: key)
    seen = [] of UInt64
    cluster.on_test_event_trigger = ->(trigger : UInt64) { seen << trigger; true }
    expect_status(invoke(cluster, Diagnostics::CMD_TEST_EVENT_TRIGGER,
      Diagnostics::TestEventTriggerRequest.new(Bytes.new(16, 0_u8), 7_u64)), Matter::InteractionModel::StatusCode::ConstraintError)
    expect_status(invoke(cluster, Diagnostics::CMD_TEST_EVENT_TRIGGER,
      Diagnostics::TestEventTriggerRequest.new(key, 7_u64)), Matter::InteractionModel::StatusCode::Success)
    seen.should eq([7_u64])
  end
end
