require "../spec_helper"

private alias OtaRequestorLifecycle = Matter::Cluster::OtaRequestor
private alias OtaRequestorStatus = Matter::InteractionModel::StatusCode

describe "OTA Requestor lifecycle" do
  it "journals StateTransition, VersionApplied, and DownloadError with typed payloads" do
    cluster = OtaRequestorLifecycle.new
    emitted = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      emitted << {event, data}
      nil
    end

    cluster.transition_to(OtaRequestorLifecycle::UpdateState::Querying,
      OtaRequestorLifecycle::ChangeReason::Success, target_version: 11_u32)
    cluster.update_state.should eq(OtaRequestorLifecycle::UpdateState::Querying)
    emitted[0][0].should eq(OtaRequestorLifecycle::EVENT_STATE_TRANSITION)
    transition = OtaRequestorLifecycle::StateTransitionEvent.from_tlv(emitted[0][1])
    transition.previous_state.should eq(OtaRequestorLifecycle::UpdateState::Idle)
    transition.new_state.should eq(OtaRequestorLifecycle::UpdateState::Querying)
    transition.target_software_version.should eq(11_u32)

    cluster.emit_version_applied(11_u32, 0x8001_u16)
    emitted[1][0].should eq(OtaRequestorLifecycle::EVENT_VERSION_APPLIED)
    applied = OtaRequestorLifecycle::VersionAppliedEvent.from_tlv(emitted[1][1])
    applied.software_version.should eq(11_u32)
    applied.product_id.should eq(0x8001_u16)

    cluster.emit_download_error(11_u32, 2048_u64, 50_u8)
    emitted[2][0].should eq(OtaRequestorLifecycle::EVENT_DOWNLOAD_ERROR)
    error = OtaRequestorLifecycle::DownloadErrorEvent.from_tlv(emitted[2][1])
    error.bytes_downloaded.should eq(2048_u64)
    error.progress_percent.should eq(50_u8)

    cluster.transition_to(OtaRequestorLifecycle::UpdateState::Idle,
      OtaRequestorLifecycle::ChangeReason::Failure)
    nil_target = OtaRequestorLifecycle::StateTransitionEvent.from_tlv(emitted.last[1])
    nil_target.target_software_version.should be_nil
  end

  it "accepts an authenticated AnnounceOTAProvider on its fabric" do
    cluster = OtaRequestorLifecycle.new
    cluster.get_command_metadata(OtaRequestorLifecycle::CMD_ANNOUNCE_OTA_PROVIDER)
      .as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    announced = [] of Tuple(UInt8, UInt64, OtaRequestorLifecycle::AnnounceProviderRequest)
    cluster.on_announce_provider = ->(fabric : UInt8, peer : UInt64, request : OtaRequestorLifecycle::AnnounceProviderRequest) do
      announced << {fabric, peer, request}
      nil
    end
    request = OtaRequestorLifecycle::AnnounceProviderRequest.new(
      0x4567_u64, 0xFFF1_u16,
      OtaRequestorLifecycle::AnnouncementReason::UpdateAvailable, 0_u16)

    cluster.invoke_command(OtaRequestorLifecycle::CMD_ANNOUNCE_OTA_PROVIDER,
      request.to_tlv(nil)).as(Matter::InteractionModel::Status).status
      .should eq(OtaRequestorStatus::UnsupportedAccess)

    cluster.request_peer_node_id = 0x2222_u64
    cluster.invoke_command(OtaRequestorLifecycle::CMD_ANNOUNCE_OTA_PROVIDER,
      request.to_tlv(nil), is_case_session: true, fabric_index: 2_u8)
      .as(Matter::InteractionModel::Status).status.should eq(OtaRequestorStatus::Success)
    announced.size.should eq(1)
    announced.first[0].should eq(2_u8)
    announced.first[1].should eq(0x2222_u64)
    announced.first[2].provider_node_id.should eq(0x4567_u64)
  end
end
