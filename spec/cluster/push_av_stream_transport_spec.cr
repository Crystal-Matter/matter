require "../spec_helper"

private alias PushAv = Matter::Cluster::PushAvStreamTransport

private def push_av_options : PushAv::Tlv::TransportOptions
  cmaf = PushAv::Tlv::CmafContainerOptions.new(PushAv::CmafInterface::Interface1, 1000_u16, 500_u16)
  trigger = PushAv::Tlv::TriggerOptions.new(PushAv::TriggerType::Command, max_pre_roll_len: 0_u16)
  PushAv::Tlv::TransportOptions.new(PushAv::StreamUsage::Recording, 1_u16, "https://host.test/ingest",
    trigger, PushAv::IngestMethod::CmafIngest, PushAv::Tlv::ContainerOptions.new(PushAv::ContainerFormat::Cmaf, cmaf),
    video_streams: [PushAv::Tlv::VideoStream.new("main", 1_u16)])
end

private def push_av_fixture : PushAv
  cluster = PushAv.new
  cluster.request_is_case_session = true
  cluster.request_fabric_index = 1_u8
  cluster.fabric_installed = ->(fabric : UInt8) { fabric.in?(1_u8..2_u8) }
  cluster.tls_endpoint_exists = ->(fabric : UInt8, id : UInt16) { fabric.in?(1_u8..2_u8) && id == 1_u16 }
  cluster.video_stream_exists = ->(id : UInt16) { id == 1_u16 }
  cluster
end

describe PushAv do
  it "declares the mandatory revision-2 attributes, commands, and events" do
    cluster = PushAv.new
    cluster.cluster_revision.should eq(2_u16)
    cluster.attributes.map(&.id.id).should eq([0_u32, 1_u32])
    cluster.commands.map(&.id.id).should eq([0_u32, 2_u32, 3_u32, 4_u32, 5_u32, 6_u32])
    cluster.events.map(&.id.id).should eq([0_u32, 1_u32])
  end

  it "allocates, finds, updates, and removes only on the requesting CASE fabric" do
    cluster = push_av_fixture
    response = cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(push_av_options))
      .as(PushAv::Tlv::AllocateResponse)
    response.transport_configuration.connection_id.should eq(0_u16)
    response.transport_configuration.transport_options.as(PushAv::Tlv::TransportOptions)
      .video_stream_id.should eq(1_u16)
    cluster.current_connections(1_u8).as(Array(PushAv::Tlv::TransportConfiguration)).size.should eq(1)
    cluster.request_fabric_index = 2_u8
    cluster.find_transport(PushAv::Tlv::FindRequest.new(0_u16))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::NotFound)
    cluster.deallocate_push_transport(PushAv::Tlv::DeallocateRequest.new(0_u16)).status
      .should eq(Matter::InteractionModel::StatusCode::NotFound)
    cluster.request_fabric_index = 1_u8
    cluster.set_transport_status(PushAv::Tlv::SetStatusRequest.new(0_u16, PushAv::TransportStatus::Inactive)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.deallocate_push_transport(PushAv::Tlv::DeallocateRequest.new(0_u16)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.current_connections(1_u8).as(Array(PushAv::Tlv::TransportConfiguration)).should be_empty
  end

  it "persists fabric-owned configuration and erases it when a fabric leaves" do
    cluster = push_av_fixture
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(push_av_options)).should be_a(PushAv::Tlv::AllocateResponse)
    document = cluster.save_state.as(Matter::Storage::Document)
    restored = push_av_fixture
    restored.restore_state(document)
    restored.find_transport(PushAv::Tlv::FindRequest.new(nil))
      .as(PushAv::Tlv::FindResponse).transport_configurations.size.should eq(1)
    restored.remove_fabric(1_u8)
    restored.current_connections(1_u8).as(Array(PushAv::Tlv::TransportConfiguration)).should be_empty
  end

  it "requires CASE, rejects missing dependencies, and leaves transport activation to the host" do
    cluster = push_av_fixture
    cluster.request_is_case_session = false
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(push_av_options))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.request_is_case_session = true
    cluster.tls_endpoint_exists = ->(_fabric : UInt8, _id : UInt16) { false }
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(push_av_options))
      .as(Matter::InteractionModel::Status).cluster_status.should eq(PushAv::StatusCode::InvalidTlsEndpoint.value)
    cluster.tls_endpoint_exists = ->(_fabric : UInt8, _id : UInt16) { true }
    response = cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(push_av_options))
      .as(PushAv::Tlv::AllocateResponse)
    response.transport_configuration.transport_status.should eq(PushAv::TransportStatus::Inactive)
  end

  it "uses revision-2 TLV field tags, including fabric index and session numbers" do
    options = push_av_options
    options.to_tlv(nil).as_structure.keys.should eq([0_u8, 3_u8, 4_u8, 5_u8, 6_u8, 7_u8, 9_u8])
    PushAv::Tlv::TransportOptions.from_tlv(options.to_tlv(nil)).video_streams.as(Array(PushAv::Tlv::VideoStream)).first.name.should eq("main")
    PushAv::Tlv::FindRequest.new(nil).to_tlv(nil).as_structure.keys.should eq([0_u8])
    configuration = PushAv::Tlv::TransportConfiguration.new(3_u16, PushAv::TransportStatus::Inactive, options, 1_u8)
    configuration.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 254_u8])
    PushAv::Tlv::TransportConfiguration.from_tlv(configuration.to_tlv(nil)).fabric_index.should eq(1_u8)
    event = PushAv::Tlv::BeginEvent.new(3_u16, PushAv::TriggerType::Command,
      PushAv::ActivationReason::DoorbellPressed, PushAv::ContainerFormat::Cmaf, 23_u64)
    event.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8])
    PushAv::Tlv::BeginEvent.from_tlv(event.to_tlv(nil)).cmaf_session_number.should eq(23_u64)
  end

  it "rejects duplicate streams and does not persist rejected changes" do
    cluster = push_av_fixture
    options = push_av_options
    duplicate = PushAv::Tlv::TransportOptions.new(options.stream_usage, options.tls_endpoint_id, options.url,
      options.trigger_options, options.ingest_method, options.container_options,
      video_streams: [PushAv::Tlv::VideoStream.new("one", 1_u16), PushAv::Tlv::VideoStream.new("two", 1_u16)])
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(duplicate))
      .as(Matter::InteractionModel::Status).cluster_status.should eq(PushAv::StatusCode::DuplicateStreamValues.value)
    cluster.current_connections(1_u8).as(Array(PushAv::Tlv::TransportConfiguration)).should be_empty
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(options)).should be_a(PushAv::Tlv::AllocateResponse)
    cluster.modify_push_transport(PushAv::Tlv::ModifyRequest.new(0_u16, duplicate))
      .cluster_status.should eq(PushAv::StatusCode::DuplicateStreamValues.value)
    cluster.find_transport(PushAv::Tlv::FindRequest.new(0_u16)).as(PushAv::Tlv::FindResponse)
      .transport_configurations.first.transport_options.as(PushAv::Tlv::TransportOptions)
      .video_streams.as(Array(PushAv::Tlv::VideoStream)).size.should eq(1)
  end

  it "requires host acceptance for activation and emits scoped events only when reported" do
    cluster = push_av_fixture
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(push_av_options)).should be_a(PushAv::Tlv::AllocateResponse)
    cluster.set_transport_status(PushAv::Tlv::SetStatusRequest.new(0_u16, PushAv::TransportStatus::Active))
      .status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    cluster.report_transport_begin(1_u8, 0_u16, PushAv::ActivationReason::UserInitiated, 1_u64).should be_false
    cluster.on_status_change = ->(_fabric : UInt8, _id : UInt16, _status : PushAv::TransportStatus) { true }
    cluster.set_transport_status(PushAv::Tlv::SetStatusRequest.new(0_u16, PushAv::TransportStatus::Active))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    control = PushAv::Tlv::MotionTimeControl.new(1_u16, 1_u16, 5_u32, 1_u16)
    cluster.manually_trigger_transport(PushAv::Tlv::ManualTriggerRequest.new(0_u16, PushAv::ActivationReason::DoorbellPressed, control))
      .status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    cluster.on_manual_trigger = ->(_fabric : UInt8, _id : UInt16, _reason : PushAv::ActivationReason, _time : PushAv::Tlv::MotionTimeControl?, _metadata : Bytes?) { true }
    cluster.manually_trigger_transport(PushAv::Tlv::ManualTriggerRequest.new(0_u16, PushAv::ActivationReason::DoorbellPressed, control))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.report_transport_begin(2_u8, 0_u16, PushAv::ActivationReason::DoorbellPressed, 5_u64).should be_false
    cluster.report_transport_begin(1_u8, 0_u16, PushAv::ActivationReason::DoorbellPressed, 5_u64).should be_true
    cluster.report_transport_end(1_u8, 0_u16, 5_u64).should be_true
    restored = push_av_fixture
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.find_transport(PushAv::Tlv::FindRequest.new(0_u16)).as(PushAv::Tlv::FindResponse)
      .transport_configurations.first.transport_status.should eq(PushAv::TransportStatus::Inactive)
  end

  it "tracks TLS endpoint references for allocation and deallocation" do
    cluster = push_av_fixture
    references = [] of Tuple(UInt8, UInt16, Int8)
    cluster.on_reference_change = ->(fabric : UInt8, endpoint : UInt16, delta : Int8) do
      references << {fabric, endpoint, delta}
      true
    end
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(push_av_options)).should be_a(PushAv::Tlv::AllocateResponse)
    references.should eq([{1_u8, 1_u16, 1_i8}])
    cluster.deallocate_push_transport(PushAv::Tlv::DeallocateRequest.new(0_u16)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    references.should eq([{1_u8, 1_u16, 1_i8}, {1_u8, 1_u16, -1_i8}])
  end

  it "rejects invalid URL, unsupported CMAF mode, and unsynchronized expiry time" do
    cluster = push_av_fixture
    options = push_av_options
    invalid_url = PushAv::Tlv::TransportOptions.new(options.stream_usage, options.tls_endpoint_id,
      "http://host.test/ingest", options.trigger_options, options.ingest_method, options.container_options,
      video_streams: options.video_streams)
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(invalid_url))
      .as(Matter::InteractionModel::Status).cluster_status.should eq(PushAv::StatusCode::InvalidUrl.value)
    interface2 = PushAv::Tlv::ContainerOptions.new(PushAv::ContainerFormat::Cmaf,
      PushAv::Tlv::CmafContainerOptions.new(PushAv::CmafInterface::Interface2Dash, 1000_u16, 500_u16))
    unsupported = PushAv::Tlv::TransportOptions.new(options.stream_usage, options.tls_endpoint_id,
      options.url, options.trigger_options, options.ingest_method, interface2,
      video_streams: options.video_streams)
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(unsupported))
      .as(Matter::InteractionModel::Status).cluster_status.should eq(PushAv::StatusCode::InvalidOptions.value)
    expiring = PushAv::Tlv::TransportOptions.new(options.stream_usage, options.tls_endpoint_id,
      options.url, options.trigger_options, options.ingest_method, options.container_options,
      expiry_time: 100_u32, video_streams: options.video_streams)
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(expiring))
      .as(Matter::InteractionModel::Status).cluster_status.should eq(PushAv::StatusCode::InvalidTime.value)
  end

  it "treats ExpiryTime as a durable relative TTL and releases the TLS reference" do
    now = Time.utc
    timers = [] of Proc(Nil)
    cluster = PushAv.new(clock: -> { now }, expiry_timer: ->(_delay : Time::Span, callback : Proc(Nil)) do
      timers << callback
      nil
    end)
    cluster.request_is_case_session = true
    cluster.request_fabric_index = 1_u8
    cluster.tls_endpoint_exists = ->(_fabric : UInt8, _id : UInt16) { true }
    cluster.video_stream_exists = ->(_id : UInt16) { true }
    cluster.time_valid = -> { true }
    references = [] of Int8
    cluster.on_reference_change = ->(_fabric : UInt8, _id : UInt16, delta : Int8) do
      references << delta
      true
    end
    base = push_av_options
    expiring = PushAv::Tlv::TransportOptions.new(base.stream_usage, base.tls_endpoint_id,
      base.url, base.trigger_options, base.ingest_method, base.container_options,
      expiry_time: 10_u32, video_streams: base.video_streams)
    cluster.allocate_push_transport(PushAv::Tlv::AllocateRequest.new(expiring)).should be_a(PushAv::Tlv::AllocateResponse)
    timers.size.should eq(1)
    cluster.current_connections(1_u8).as(Array(PushAv::Tlv::TransportConfiguration)).size.should eq(1)
    persisted = cluster.save_state.as(Matter::Storage::Document)
    now += 11.seconds
    timers.last.call
    cluster.current_connections(1_u8).as(Array(PushAv::Tlv::TransportConfiguration)).should be_empty
    references.should eq([1_i8, -1_i8])
    restored = PushAv.new(clock: -> { now })
    restored.request_is_case_session = true
    restored.request_fabric_index = 1_u8
    restored.restore_state(persisted)
    restored.current_connections(1_u8).as(Array(PushAv::Tlv::TransportConfiguration)).should be_empty
  end
end
