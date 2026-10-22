require "../spec_helper"
require "../../src/matter/cluster/general_diagnostics"

private alias GeneralDiagnostics = Matter::Cluster::GeneralDiagnostics

# The Matter 1.6 DeviceLoadStruct has five mandatory context fields. Decode
# independently so a missing field cannot pass through a shared encoder.
private struct DeviceLoadWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter current_subscriptions : UInt16

  @[TLV::Field(tag: 1)]
  getter current_subscriptions_for_fabric : UInt16

  @[TLV::Field(tag: 2)]
  getter total_subscriptions_established : UInt32

  @[TLV::Field(tag: 3)]
  getter total_interaction_model_messages_sent : UInt32

  @[TLV::Field(tag: 4)]
  getter total_interaction_model_messages_received : UInt32
end

describe GeneralDiagnostics do
  it "advertises revision 3 DeviceLoadStatus and all mandatory structure fields" do
    cluster = build(GeneralDiagnostics, 0)
    cluster.cluster_revision.should eq(3_u16)
    attribute_ids(cluster).should contain(GeneralDiagnostics::ATTR_DEVICE_LOAD_STATUS)

    cluster.on_device_load_status = ->(_fabric_index : UInt8?) do
      GeneralDiagnostics::DeviceLoadStruct.new(3_u16, 2_u16, 4_u32, 5_u32, 6_u32)
    end
    wire = read_tlv(cluster, GeneralDiagnostics::ATTR_DEVICE_LOAD_STATUS, 1_u8)
    wire.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8])
    status = DeviceLoadWire.from_tlv(wire)
    status.current_subscriptions.should eq(3_u16)
    status.current_subscriptions_for_fabric.should eq(2_u16)
    status.total_subscriptions_established.should eq(4_u32)
    status.total_interaction_model_messages_sent.should eq(5_u32)
    status.total_interaction_model_messages_received.should eq(6_u32)
  end
end
