require "../support/operational_credentials_helpers"

private alias SessionOpCreds = Matter::Cluster::OperationalCredentials

# Defined from the pinned Matter 1.6 XML independently of the command codec.
private struct CanonicalUpdateFabricLabelWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  property label : String

  def initialize(@label : String)
  end
end

private struct LegacyFabricLabelWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  property label : String

  @[TLV::Field(tag: 254)]
  property fabric_index : UInt8

  def initialize(@label : String, @fabric_index : UInt8)
  end
end

private def session_fabric_cluster : SessionOpCreds
  table = OpCredsTestHelpers.create_fabric_table
  table.add_fabric(OpCredsTestHelpers.create_test_fabric(0x111_u64, 1_u8, "First"))
  table.add_fabric(OpCredsTestHelpers.create_test_fabric(0x222_u64, 2_u8, "Second"))
  SessionOpCreds.new(table, endpoint(0), nil)
end

private def label_status(result : Matter::InteractionModel::Status | Matter::Cluster::CommandResponse)
  result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)[0_u8].value.as(Int)
end

describe "Matter 1.6 Operational Credentials fabric-scoped command wire" do
  it "decodes a canonical UpdateNOC with omitted ICAC and no FabricIndex" do
    wire = CanonicalUpdateNocWire.new(Bytes[0x01_u8]).to_slice
    request = SessionOpCreds::Tlv::UpdateNocRequest.from_slice(wire)
    request.noc_value.should eq(Bytes[0x01_u8])
    request.icac_value.should be_nil
  end

  it "encodes UpdateNOC without an untrusted FabricIndex field" do
    encoded = SessionOpCreds::Tlv::UpdateNocRequest.new(Bytes[0x01_u8]).to_tlv(nil)
    encoded[0_u8].value.should eq(Bytes[0x01_u8])
    encoded[1_u8]?.should be_nil
    encoded[254_u8]?.should be_nil

    with_icac = SessionOpCreds::Tlv::UpdateNocRequest.new(Bytes[0x01_u8], Bytes[0x02_u8]).to_tlv(nil)
    with_icac[1_u8].value.should eq(Bytes[0x02_u8])
    with_icac[254_u8]?.should be_nil
  end

  it "encodes UpdateFabricLabel with only its Label field" do
    encoded = SessionOpCreds::Tlv::UpdateFabricLabelRequest.new("Updated").to_tlv(nil)
    encoded[0_u8].value.should eq("Updated")
    encoded[254_u8]?.should be_nil
  end

  it "uses the authenticated CASE fabric for UpdateFabricLabel despite a legacy supplied index" do
    cluster = session_fabric_cluster
    canonical = invoke(cluster, SessionOpCreds::CMD_UPDATE_FABRIC_LABEL,
      CanonicalUpdateFabricLabelWire.new("Canonical").to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8)
    label_status(canonical).should eq(0)
    cluster.fabric_table.get_fabric(1_u8).try(&.label).should eq("Canonical")

    response = invoke(cluster, SessionOpCreds::CMD_UPDATE_FABRIC_LABEL,
      LegacyFabricLabelWire.new("Updated", 2_u8).to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8)
    label_status(response).should eq(0)
    cluster.fabric_table.get_fabric(1_u8).try(&.label).should eq("Updated")
    cluster.fabric_table.get_fabric(2_u8).try(&.label).should eq("Second")
  end

  it "rejects a fabricless PASE UpdateFabricLabel even with a forged fabric index" do
    cluster = session_fabric_cluster
    result = invoke(cluster, SessionOpCreds::CMD_UPDATE_FABRIC_LABEL,
      LegacyFabricLabelWire.new("Hijacked", 2_u8).to_tlv(nil),
      is_case_session: false, fabric_index: nil)
    result.should be_a(Matter::InteractionModel::Status)
    result.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.fabric_table.get_fabric(1_u8).try(&.label).should eq("First")
    cluster.fabric_table.get_fabric(2_u8).try(&.label).should eq("Second")
  end

  it "rejects a fabricless PASE UpdateNOC before consulting a supplied legacy index" do
    cluster = session_fabric_cluster
    result = invoke(cluster, SessionOpCreds::CMD_UPDATE_NOC,
      LegacyUpdateNocWire.new(Bytes[0x01_u8], 2_u8).to_tlv(nil),
      is_case_session: false, fabric_index: nil)
    result.should be_a(Matter::InteractionModel::Status)
    result.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
  end
end
