require "../spec_helper"

private alias PushAvRuntime = Matter::Cluster::PushAvStreamTransport

private def runtime_options(trigger : PushAvRuntime::Tlv::TriggerOptions) : PushAvRuntime::Tlv::TransportOptions
  cmaf = PushAvRuntime::Tlv::CmafContainerOptions.new(PushAvRuntime::CmafInterface::Interface1, 1000_u16, 500_u16)
  PushAvRuntime::Tlv::TransportOptions.new(PushAvRuntime::StreamUsage::Recording, 1_u16,
    "https://host.test/ingest", trigger, PushAvRuntime::IngestMethod::CmafIngest,
    PushAvRuntime::Tlv::ContainerOptions.new(PushAvRuntime::ContainerFormat::Cmaf, cmaf),
    video_streams: [PushAvRuntime::Tlv::VideoStream.new("main", 1_u16)])
end

private def active_runtime(trigger : PushAvRuntime::Tlv::TriggerOptions) : PushAvRuntime
  cluster = PushAvRuntime.new
  cluster.request_is_case_session = true
  cluster.request_fabric_index = 1_u8
  cluster.tls_endpoint_exists = ->(_fabric : UInt8, _id : UInt16) { true }
  cluster.video_stream_exists = ->(_id : UInt16) { true }
  cluster.on_status_change = ->(_fabric : UInt8, _id : UInt16, _status : PushAvRuntime::TransportStatus) { true }
  cluster.allocate_push_transport(PushAvRuntime::Tlv::AllocateRequest.new(runtime_options(trigger)))
    .should be_a(PushAvRuntime::Tlv::AllocateResponse)
  cluster.set_transport_status(PushAvRuntime::Tlv::SetStatusRequest.new(0_u16, PushAvRuntime::TransportStatus::Active))
    .status.should eq(Matter::InteractionModel::StatusCode::Success)
  cluster
end

describe "Push AV manual transport runtime" do
  it "requires command TimeControl and passes a valid override to the host" do
    trigger = PushAvRuntime::Tlv::TriggerOptions.new(PushAvRuntime::TriggerType::Command, max_pre_roll_len: 0_u16)
    cluster = active_runtime(trigger)
    received = [] of PushAvRuntime::Tlv::MotionTimeControl?
    cluster.on_manual_trigger = ->(_fabric : UInt8, _id : UInt16, _reason : PushAvRuntime::ActivationReason, time : PushAvRuntime::Tlv::MotionTimeControl?, _metadata : Bytes?) do
      received << time
      true
    end
    cluster.manually_trigger_transport(PushAvRuntime::Tlv::ManualTriggerRequest.new(0_u16,
      PushAvRuntime::ActivationReason::UserInitiated)).status
      .should eq(Matter::InteractionModel::StatusCode::DynamicConstraintError)
    received.should be_empty
    control = PushAvRuntime::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16)
    cluster.manually_trigger_transport(PushAvRuntime::Tlv::ManualTriggerRequest.new(0_u16,
      PushAvRuntime::ActivationReason::UserInitiated, control)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    received.should eq([control])
  end

  it "uses configured MotionTimeControl when a motion transport is manually triggered without one" do
    control = PushAvRuntime::Tlv::MotionTimeControl.new(2_u16, 1_u16, 5_u32, 1_u16)
    trigger = PushAvRuntime::Tlv::TriggerOptions.new(PushAvRuntime::TriggerType::Motion,
      motion_zones: TLV::FieldState(Array(PushAvRuntime::Tlv::ZoneOptions)).null,
      motion_sensitivity: TLV::FieldState(UInt8).null,
      motion_time_control: control, max_pre_roll_len: 0_u16)
    cluster = active_runtime(trigger)
    received = [] of PushAvRuntime::Tlv::MotionTimeControl?
    cluster.on_manual_trigger = ->(_fabric : UInt8, _id : UInt16, _reason : PushAvRuntime::ActivationReason, time : PushAvRuntime::Tlv::MotionTimeControl?, _metadata : Bytes?) do
      received << time
      true
    end
    cluster.manually_trigger_transport(PushAvRuntime::Tlv::ManualTriggerRequest.new(0_u16,
      PushAvRuntime::ActivationReason::Automation)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    received.should eq([control])
  end

  it "blocks manual capture when privacy denies the stream usage or the host reports busy" do
    trigger = PushAvRuntime::Tlv::TriggerOptions.new(PushAvRuntime::TriggerType::Command, max_pre_roll_len: 0_u16)
    cluster = active_runtime(trigger)
    control = PushAvRuntime::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16)
    calls = 0
    cluster.on_manual_trigger = ->(_fabric : UInt8, _id : UInt16, _reason : PushAvRuntime::ActivationReason, _time : PushAvRuntime::Tlv::MotionTimeControl?, _metadata : Bytes?) do
      calls += 1
      true
    end
    request = PushAvRuntime::Tlv::ManualTriggerRequest.new(0_u16,
      PushAvRuntime::ActivationReason::UserInitiated, control)
    cluster.privacy_allows = ->(usage : PushAvRuntime::StreamUsage) { usage != PushAvRuntime::StreamUsage::Recording }
    cluster.manually_trigger_transport(request).status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    cluster.privacy_allows = ->(_usage : PushAvRuntime::StreamUsage) { true }
    cluster.transport_busy = ->(_fabric : UInt8, _id : UInt16) { true }
    cluster.manually_trigger_transport(request).status.should eq(Matter::InteractionModel::StatusCode::Busy)
    calls.should eq(0)
    cluster.transport_busy = ->(_fabric : UInt8, _id : UInt16) { false }
    cluster.manually_trigger_transport(request).status.should eq(Matter::InteractionModel::StatusCode::Success)
    calls.should eq(1)
  end
end
