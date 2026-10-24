require "../spec_helper"

private alias PushAvNullable = Matter::Cluster::PushAvStreamTransport

private def nullable_push_av_options(video : TLV::FieldState(UInt16) = TLV::FieldState(UInt16).absent,
                                     trigger : PushAvNullable::Tlv::TriggerOptions? = nil,
                                     audio : TLV::FieldState(UInt16) = TLV::FieldState(UInt16).absent) : PushAvNullable::Tlv::TransportOptions
  cmaf = PushAvNullable::Tlv::CmafContainerOptions.new(PushAvNullable::CmafInterface::Interface1, 1000_u16, 500_u16)
  selected_trigger = trigger || PushAvNullable::Tlv::TriggerOptions.new(PushAvNullable::TriggerType::Command,
    max_pre_roll_len: 0_u16)
  PushAvNullable::Tlv::TransportOptions.new(PushAvNullable::StreamUsage::Recording, 1_u16,
    "https://host.test/ingest", selected_trigger, PushAvNullable::IngestMethod::CmafIngest,
    PushAvNullable::Tlv::ContainerOptions.new(PushAvNullable::ContainerFormat::Cmaf, cmaf),
    video_stream_id: video, audio_stream_id: audio)
end

private def nullable_push_av_cluster : PushAvNullable
  cluster = PushAvNullable.new
  cluster.request_is_case_session = true
  cluster.request_fabric_index = 1_u8
  cluster.tls_endpoint_exists = ->(_fabric : UInt8, _id : UInt16) { true }
  cluster.video_stream_exists = ->(id : UInt16) { id == 9_u16 }
  cluster.audio_stream_exists = ->(id : UInt16) { id == 7_u16 }
  cluster
end

describe "Push AV nullable production fields" do
  it "round trips absent, Null, and concrete revision-1 video IDs in TransportOptions" do
    [TLV::FieldState(UInt16).absent, TLV::FieldState(UInt16).null,
     TLV::FieldState(UInt16).value(9_u16)].each do |video|
      options = nullable_push_av_options(video)
      wire = options.to_tlv(nil).as_structure
      wire.has_key?(1_u8).should eq(!video.absent?)
      wire[1_u8].header.element_type.null?.should be_true if video.null?
      decoded = PushAvNullable::Tlv::TransportOptions.from_slice(options.to_slice)
      decoded.video_stream_id_state.kind.should eq(video.kind)
      decoded.video_stream_id.should eq(9_u16) if video.value?
    end

    malformed = nullable_push_av_options.to_tlv(nil).as_structure
    malformed[1_u8] = TLV::Any.new("wrong type", 1_u8)
    expect_raises(TLV::DeserializationError) do
      PushAvNullable::Tlv::TransportOptions.from_tlv(TLV::Any.new(malformed))
    end
    malformed_trigger = PushAvNullable::Tlv::TriggerOptions.new(PushAvNullable::TriggerType::Motion,
      motion_zones: TLV::FieldState(Array(PushAvNullable::Tlv::ZoneOptions)).null,
      motion_sensitivity: TLV::FieldState(UInt8).null).to_tlv(nil).as_structure
    malformed_trigger[2_u8] = TLV::Any.new("wrong type", 2_u8)
    expect_raises(TLV::DeserializationError) do
      PushAvNullable::Tlv::TriggerOptions.from_tlv(TLV::Any.new(malformed_trigger))
    end
  end

  it "round trips mandatory nullable Motion fields and preserves them in storage" do
    trigger = PushAvNullable::Tlv::TriggerOptions.new(PushAvNullable::TriggerType::Motion,
      motion_zones: TLV::FieldState(Array(PushAvNullable::Tlv::ZoneOptions)).null,
      motion_sensitivity: TLV::FieldState(UInt8).null,
      motion_time_control: PushAvNullable::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16),
      max_pre_roll_len: 0_u16)
    options = nullable_push_av_options(TLV::FieldState(UInt16).value(9_u16), trigger)
    wire = trigger.to_tlv(nil).as_structure
    wire[1_u8].header.element_type.null?.should be_true
    wire[2_u8].header.element_type.null?.should be_true
    decoded = PushAvNullable::Tlv::TriggerOptions.from_slice(trigger.to_slice)
    decoded.motion_zones_state.null?.should be_true
    decoded.motion_sensitivity_state.null?.should be_true
    restored = PushAvNullable::Tlv::TransportOptions.from_document(options.to_document)
    restored.trigger_options.motion_zones_state.null?.should be_true
    restored.trigger_options.motion_sensitivity_state.null?.should be_true
    restored.video_stream_id_state.value!.should eq(9_u16)
  end

  it "rejects absent mandatory Motion fields but accepts explicit Null" do
    cluster = nullable_push_av_cluster
    time = PushAvNullable::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16)
    missing = PushAvNullable::Tlv::TriggerOptions.new(PushAvNullable::TriggerType::Motion,
      motion_time_control: time, max_pre_roll_len: 0_u16)
    cluster.allocate_push_transport(PushAvNullable::Tlv::AllocateRequest.new(
      nullable_push_av_options(TLV::FieldState(UInt16).value(9_u16), missing)))
      .as(Matter::InteractionModel::Status).cluster_status.should eq(PushAvNullable::StatusCode::InvalidOptions.value)
    explicit_null = PushAvNullable::Tlv::TriggerOptions.new(PushAvNullable::TriggerType::Motion,
      motion_zones: TLV::FieldState(Array(PushAvNullable::Tlv::ZoneOptions)).null,
      motion_sensitivity: TLV::FieldState(UInt8).null,
      motion_time_control: time, max_pre_roll_len: 0_u16)
    cluster.allocate_push_transport(PushAvNullable::Tlv::AllocateRequest.new(
      nullable_push_av_options(TLV::FieldState(UInt16).value(9_u16), explicit_null)))
      .should be_a(PushAvNullable::Tlv::AllocateResponse)
  end

  it "asks the host to select a stream for explicit Null and returns the chosen ID" do
    cluster = nullable_push_av_cluster
    cluster.allocate_push_transport(PushAvNullable::Tlv::AllocateRequest.new(
      nullable_push_av_options(TLV::FieldState(UInt16).null)))
      .as(Matter::InteractionModel::Status).cluster_status.should eq(PushAvNullable::StatusCode::InvalidStream.value)
    cluster.current_connections(1_u8).as(Array(PushAvNullable::Tlv::TransportConfiguration)).should be_empty
    cluster.select_video_stream = ->(_fabric : UInt8, _usage : PushAvNullable::StreamUsage) { 9_u16 }
    cluster.select_audio_stream = ->(_fabric : UInt8, _usage : PushAvNullable::StreamUsage) { 7_u16 }
    response = cluster.allocate_push_transport(PushAvNullable::Tlv::AllocateRequest.new(
      nullable_push_av_options(TLV::FieldState(UInt16).null,
        audio: TLV::FieldState(UInt16).null))).as(PushAvNullable::Tlv::AllocateResponse)
    options = response.transport_configuration.transport_options.as(PushAvNullable::Tlv::TransportOptions)
    options.video_stream_id.should eq(9_u16)
    options.video_streams.as(Array(PushAvNullable::Tlv::VideoStream)).first.name.should eq("video")
    options.audio_stream_id.should eq(7_u16)
    options.audio_streams.as(Array(PushAvNullable::Tlv::AudioStream)).first.name.should eq("audio")
    cluster.find_transport(PushAvNullable::Tlv::FindRequest.new(response.transport_configuration.connection_id))
      .as(PushAvNullable::Tlv::FindResponse).transport_configurations.first.transport_options
      .as(PushAvNullable::Tlv::TransportOptions).video_stream_id_state.value!.should eq(9_u16)
  end

  it "restores allocated nullable Motion fields from durable cluster state" do
    cluster = nullable_push_av_cluster
    trigger = PushAvNullable::Tlv::TriggerOptions.new(PushAvNullable::TriggerType::Motion,
      motion_zones: TLV::FieldState(Array(PushAvNullable::Tlv::ZoneOptions)).null,
      motion_sensitivity: TLV::FieldState(UInt8).null,
      motion_time_control: PushAvNullable::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16),
      max_pre_roll_len: 0_u16)
    cluster.allocate_push_transport(PushAvNullable::Tlv::AllocateRequest.new(
      nullable_push_av_options(TLV::FieldState(UInt16).value(9_u16), trigger)))
      .should be_a(PushAvNullable::Tlv::AllocateResponse)
    restored = nullable_push_av_cluster
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    options = restored.find_transport(PushAvNullable::Tlv::FindRequest.new(nil))
      .as(PushAvNullable::Tlv::FindResponse).transport_configurations.first.transport_options
      .as(PushAvNullable::Tlv::TransportOptions)
    options.trigger_options.motion_zones_state.null?.should be_true
    options.trigger_options.motion_sensitivity_state.null?.should be_true
    options.video_stream_id_state.value!.should eq(9_u16)
  end
end
