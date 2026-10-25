require "../spec_helper"

private alias PushAvSession = Matter::Cluster::PushAvStreamTransport

private def session_options : PushAvSession::Tlv::TransportOptions
  trigger = PushAvSession::Tlv::TriggerOptions.new(PushAvSession::TriggerType::Command, max_pre_roll_len: 0_u16)
  cmaf = PushAvSession::Tlv::CmafContainerOptions.new(PushAvSession::CmafInterface::Interface1, 1000_u16, 500_u16)
  PushAvSession::Tlv::TransportOptions.new(PushAvSession::StreamUsage::Recording, 1_u16,
    "https://host.test/ingest", trigger, PushAvSession::IngestMethod::CmafIngest,
    PushAvSession::Tlv::ContainerOptions.new(PushAvSession::ContainerFormat::Cmaf, cmaf),
    video_streams: [PushAvSession::Tlv::VideoStream.new("main", 1_u16)])
end

private def session_cluster(options : PushAvSession::Tlv::TransportOptions = session_options) : PushAvSession
  cluster = PushAvSession.new
  cluster.request_is_case_session = true
  cluster.request_fabric_index = 1_u8
  cluster.fabric_installed = ->(fabric : UInt8) { fabric.in?(1_u8..2_u8) }
  cluster.tls_endpoint_exists = ->(_fabric : UInt8, _id : UInt16) { true }
  cluster.video_stream_exists = ->(_id : UInt16) { true }
  cluster.on_status_change = ->(_fabric : UInt8, _id : UInt16, _status : PushAvSession::TransportStatus) { true }
  cluster.allocate_push_transport(PushAvSession::Tlv::AllocateRequest.new(options))
    .should be_a(PushAvSession::Tlv::AllocateResponse)
  cluster.set_transport_status(PushAvSession::Tlv::SetStatusRequest.new(0_u16, PushAvSession::TransportStatus::Active))
    .status.should eq(Matter::InteractionModel::StatusCode::Success)
  cluster
end

describe "Push AV CMAF session lifecycle" do
  it "reports the actual Command trigger when a Motion transport is manually started" do
    base = session_options
    control = PushAvSession::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16)
    trigger = PushAvSession::Tlv::TriggerOptions.new(PushAvSession::TriggerType::Motion,
      motion_zones: TLV::FieldState(Array(PushAvSession::Tlv::ZoneOptions)).null,
      motion_sensitivity: TLV::FieldState(UInt8).null,
      motion_time_control: control, max_pre_roll_len: 0_u16)
    options = PushAvSession::Tlv::TransportOptions.new(base.stream_usage, base.tls_endpoint_id,
      base.url, trigger, base.ingest_method, base.container_options, video_streams: base.video_streams)
    cluster = session_cluster(options)
    begins = [] of PushAvSession::Tlv::BeginEvent
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      begins << PushAvSession::Tlv::BeginEvent.from_tlv(data) if id == PushAvSession::EVENT_PUSH_TRANSPORT_BEGIN
      nil
    end
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::TriggerType::Motion,
      PushAvSession::ActivationReason::Automation, 4_u64).should be_false
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::TriggerType::Command,
      nil, 4_u64).should be_false
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::TriggerType::Continuous,
      nil, 4_u64).should be_false
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::TriggerType::Command,
      PushAvSession::ActivationReason::Automation, 4_u64).should be_true
    begins.size.should eq(1)
    begins.first.trigger_type.should eq(PushAvSession::TriggerType::Command)
    begins.first.activation_reason.should eq(PushAvSession::ActivationReason::Automation)
  end

  it "emits only matching Begin and End pairs on the owning fabric" do
    cluster = session_cluster
    events = [] of Tuple(UInt32, UInt8?, UInt64)
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
      session = if id == PushAvSession::EVENT_PUSH_TRANSPORT_BEGIN
                  PushAvSession::Tlv::BeginEvent.from_tlv(data).cmaf_session_number
                else
                  PushAvSession::Tlv::EndEvent.from_tlv(data).cmaf_session_number
                end
      events << {id, fabric, session}
      nil
    end
    cluster.report_transport_end(1_u8, 0_u16, 11_u64).should be_false
    cluster.report_transport_begin(2_u8, 0_u16, PushAvSession::ActivationReason::UserInitiated, 11_u64).should be_false
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::UserInitiated, 11_u64).should be_true
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::UserInitiated, 11_u64).should be_false
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::UserInitiated, 12_u64).should be_false
    cluster.report_transport_end(2_u8, 0_u16, 11_u64).should be_false
    cluster.report_transport_end(1_u8, 0_u16, 12_u64).should be_false
    cluster.report_transport_end(1_u8, 0_u16, 11_u64).should be_true
    cluster.report_transport_end(1_u8, 0_u16, 11_u64).should be_false
    events.should eq([
      {PushAvSession::EVENT_PUSH_TRANSPORT_BEGIN, 1_u8, 11_u64},
      {PushAvSession::EVENT_PUSH_TRANSPORT_END, 1_u8, 11_u64},
    ])
  end

  it "closes the reported session after the host accepts Inactive or deallocation" do
    cluster = session_cluster
    events = [] of Tuple(UInt32, UInt64)
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      session = if id == PushAvSession::EVENT_PUSH_TRANSPORT_BEGIN
                  PushAvSession::Tlv::BeginEvent.from_tlv(data).cmaf_session_number
                else
                  PushAvSession::Tlv::EndEvent.from_tlv(data).cmaf_session_number
                end
      events << {id, session}
      nil
    end
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::UserInitiated, 7_u64).should be_true
    cluster.set_transport_status(PushAvSession::Tlv::SetStatusRequest.new(0_u16, PushAvSession::TransportStatus::Inactive))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    events.should eq([
      {PushAvSession::EVENT_PUSH_TRANSPORT_BEGIN, 7_u64},
      {PushAvSession::EVENT_PUSH_TRANSPORT_END, 7_u64},
    ])
    cluster.report_transport_end(1_u8, 0_u16, 7_u64).should be_false
    cluster.set_transport_status(PushAvSession::Tlv::SetStatusRequest.new(0_u16, PushAvSession::TransportStatus::Active))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::UserInitiated, 8_u64).should be_true
    cluster.deallocate_push_transport(PushAvSession::Tlv::DeallocateRequest.new(0_u16)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    events.last.should eq({PushAvSession::EVENT_PUSH_TRANSPORT_END, 8_u64})
    cluster.report_transport_end(1_u8, 0_u16, 8_u64).should be_false
  end

  it "rejects another manual trigger while the host reports an active upload and clears state on restart" do
    cluster = session_cluster
    cluster.on_manual_trigger = ->(_fabric : UInt8, _id : UInt16, _reason : PushAvSession::ActivationReason, _time : PushAvSession::Tlv::MotionTimeControl?, _metadata : Bytes?) { true }
    control = PushAvSession::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16)
    request = PushAvSession::Tlv::ManualTriggerRequest.new(0_u16, PushAvSession::ActivationReason::Automation, control)
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::Automation, 3_u64).should be_true
    cluster.manually_trigger_transport(request).status.should eq(Matter::InteractionModel::StatusCode::Busy)
    restored = session_cluster
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.report_transport_end(1_u8, 0_u16, 3_u64).should be_false
    restored.find_transport(PushAvSession::Tlv::FindRequest.new(0_u16))
      .as(PushAvSession::Tlv::FindResponse).transport_configurations.first.transport_status
      .should eq(PushAvSession::TransportStatus::Inactive)
  end

  it "stops the host and forgets an active session when its fabric is removed" do
    cluster = session_cluster
    stops = [] of Tuple(UInt8, UInt16, PushAvSession::TransportStatus)
    cluster.on_status_change = ->(fabric : UInt8, id : UInt16, status : PushAvSession::TransportStatus) do
      stops << {fabric, id, status}
      true
    end
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::Automation, 6_u64).should be_true
    cluster.remove_fabric(1_u8)
    stops.should eq([{1_u8, 0_u16, PushAvSession::TransportStatus::Inactive}])
    cluster.report_transport_end(1_u8, 0_u16, 6_u64).should be_false
    cluster.find_transport(PushAvSession::Tlv::FindRequest.new(0_u16))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::NotFound)
  end

  it "does not duplicate End when the host reports it from the stop callback" do
    cluster = session_cluster
    event_ids = [] of UInt32
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      event_ids << id
      nil
    end
    cluster.on_status_change = ->(fabric : UInt8, id : UInt16, status : PushAvSession::TransportStatus) do
      cluster.report_transport_end(fabric, id, 9_u64) if status.inactive?
      true
    end
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::Automation, 9_u64).should be_true
    cluster.set_transport_status(PushAvSession::Tlv::SetStatusRequest.new(0_u16, PushAvSession::TransportStatus::Inactive))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    event_ids.should eq([PushAvSession::EVENT_PUSH_TRANSPORT_BEGIN, PushAvSession::EVENT_PUSH_TRANSPORT_END])
  end

  it "closes the reported session with its CMAF number when the TTL expires" do
    now = Time.utc
    timers = [] of Proc(Nil)
    cluster = PushAvSession.new(clock: -> { now }, expiry_timer: ->(_delay : Time::Span, callback : Proc(Nil)) do
      timers << callback
      nil
    end)
    cluster.request_is_case_session = true
    cluster.request_fabric_index = 1_u8
    cluster.tls_endpoint_exists = ->(_fabric : UInt8, _id : UInt16) { true }
    cluster.video_stream_exists = ->(_id : UInt16) { true }
    cluster.time_valid = -> { true }
    cluster.on_status_change = ->(_fabric : UInt8, _id : UInt16, _status : PushAvSession::TransportStatus) { true }
    base = session_options
    options = PushAvSession::Tlv::TransportOptions.new(base.stream_usage, base.tls_endpoint_id,
      base.url, base.trigger_options, base.ingest_method, base.container_options,
      expiry_time: 1_u32, video_streams: base.video_streams)
    cluster.allocate_push_transport(PushAvSession::Tlv::AllocateRequest.new(options))
      .should be_a(PushAvSession::Tlv::AllocateResponse)
    cluster.set_transport_status(PushAvSession::Tlv::SetStatusRequest.new(0_u16, PushAvSession::TransportStatus::Active))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    end_sessions = [] of UInt64
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      end_sessions << PushAvSession::Tlv::EndEvent.from_tlv(data).cmaf_session_number if id == PushAvSession::EVENT_PUSH_TRANSPORT_END
      nil
    end
    cluster.report_transport_begin(1_u8, 0_u16, PushAvSession::ActivationReason::UserInitiated, 42_u64).should be_true
    now += 2.seconds
    timers.last.call
    end_sessions.should eq([42_u64])
    cluster.current_connections(1_u8).as(Array(PushAvSession::Tlv::TransportConfiguration)).should be_empty
  end
end
