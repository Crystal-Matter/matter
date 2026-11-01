require "../spec_helper"
require "../../src/matter/cluster/general_diagnostics"

private alias GeneralDiagnostics = Matter::Cluster::GeneralDiagnostics

# Independent Matter 1.6 response shape: both fields are present, with a
# nullable POSIX time when the device has no trusted wall clock.
private struct TimeSnapshotWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter system_time_ms : UInt64

  @[TLV::Field(tag: 1, optional: false)]
  getter posix_time_ms : UInt64?
end

describe GeneralDiagnostics do
  it "retains mandatory TimeSnapshot and BootReason at revision 3" do
    cluster = build(GeneralDiagnostics, 0)
    cluster.cluster_revision.should eq(3_u16)
    cluster.boot_reason.should eq(GeneralDiagnostics::BootReason::Unspecified)
    cluster.get_command_metadata(GeneralDiagnostics::CMD_TIME_SNAPSHOT).as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    cluster.get_event_metadata(GeneralDiagnostics::EVENT_BOOT_REASON).as(Matter::Cluster::EventMetadata).priority.critical?
      .should be_true
  end

  it "answers TimeSnapshot on the wire with monotonic milliseconds and nullable POSIX time" do
    cluster = build(GeneralDiagnostics, 0)
    sleep 2.milliseconds
    first = invoke(cluster, GeneralDiagnostics::CMD_TIME_SNAPSHOT).as(Matter::Cluster::CommandResponse)
    first.command_id.should eq(GeneralDiagnostics::CMD_TIME_SNAPSHOT_RESPONSE)
    first_wire = first.response.as(TLV::Any)
    first_wire.as_structure.keys.should eq([0_u8, 1_u8])
    first_wire.as_structure[1_u8].value.should be_nil
    first_snapshot = TimeSnapshotWire.from_tlv(first_wire)
    first_snapshot.system_time_ms.should be >= 2_u64
    first_snapshot.posix_time_ms.should be_nil

    sleep 2.milliseconds
    second = invoke(cluster, GeneralDiagnostics::CMD_TIME_SNAPSHOT).as(Matter::Cluster::CommandResponse)
    second_snapshot = TimeSnapshotWire.from_tlv(second.response.as(TLV::Any))
    second_snapshot.system_time_ms.should be >= first_snapshot.system_time_ms
  end

  it "keeps UpTime consistent with TimeSnapshot when the wall clock moves forward" do
    cluster = build(GeneralDiagnostics, 0)
    Timecop.travel(Time.utc + 1.hour) do
      up_time = cluster.up_time
      response = invoke(cluster, GeneralDiagnostics::CMD_TIME_SNAPSHOT).as(Matter::Cluster::CommandResponse)
      snapshot = TimeSnapshotWire.from_tlv(response.response.as(TLV::Any))
      up_time.should be <= snapshot.system_time_ms // 1000_u64
    end
  end

  it "does not regress UpTime when the wall clock moves backward" do
    cluster = build(GeneralDiagnostics, 0)
    before = cluster.up_time
    Timecop.travel(Time.utc - 1.hour) do
      cluster.up_time.should be >= before
    end
  end

  it "includes POSIX milliseconds only when a synchronized source supplies them" do
    cluster = build(GeneralDiagnostics, 0)
    cluster.on_posix_time_ms = -> : UInt64? { 1_800_000_000_000_u64 }

    response = invoke(cluster, GeneralDiagnostics::CMD_TIME_SNAPSHOT).as(Matter::Cluster::CommandResponse)
    snapshot = TimeSnapshotWire.from_tlv(response.response.as(TLV::Any))
    snapshot.posix_time_ms.should eq(1_800_000_000_000_u64)
  end

  it "journals the critical BootReason event with context-tag-zero payload" do
    node = Matter::Node.new
    root = Matter::Endpoint.new(endpoint(0))
    cluster = build(GeneralDiagnostics, 0, boot_reason: GeneralDiagnostics::BootReason::SoftwareReset)
    root.add_cluster(cluster)
    node.add_endpoint(root)

    cluster.emit_boot_reason_event

    records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: GeneralDiagnostics::CLUSTER_ID,
      event: GeneralDiagnostics::EVENT_BOOT_REASON,
    )])
    records.size.should eq(1)
    records.first.priority.critical?.should be_true
    records.first.data.as_structure.keys.should eq([0_u8])
    records.first.data.as_structure[0_u8].value.should eq(GeneralDiagnostics::BootReason::SoftwareReset.value)
    GeneralDiagnostics::Events::BootReasonEvent.from_tlv(records.first.data).boot_reason
      .should eq(GeneralDiagnostics::BootReason::SoftwareReset)
  end
end
