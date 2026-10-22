require "../spec_helper"

private alias Commissioner = Matter::Cluster::CommissionerControl

private def commissioner_context(cluster : Commissioner, fabric : UInt8 = 1_u8, node : UInt64 = 42_u64) : Nil
  cluster.request_is_case_session = true
  cluster.request_fabric_index = fabric
  cluster.request_peer_node_id = node
end

private def commissioner_window : Commissioner::ReverseOpenCommissioningWindowResponse
  Commissioner::ReverseOpenCommissioningWindowResponse.new(
    180_u16, Bytes.new(97, 0_u8), 3840_u16, 1000_u32, Bytes.new(16, 0_u8))
end

describe Commissioner do
  it "declares the Matter 1.6 Manage-only wire schema and advertises no category without a host" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.cluster_revision.should eq(1_u16)
    cluster.supported_device_categories.should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([Commissioner::ATTR_SUPPORTED_DEVICE_CATEGORIES])
    cluster.attributes.first.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    cluster.commands.map(&.id.id).should eq([0_u32, 1_u32])
    cluster.commands.each(&.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage))
    cluster.commands.last.response_id.should eq(2_u32)
    cluster.events.map(&.id.id).should eq([Commissioner::EVENT_COMMISSIONING_REQUEST_RESULT])
    cluster.events.first.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)

    request = Commissioner::RequestCommissioningApprovalRequest.new(7_u64, 0xFFF1_u16, 0x1234_u16, "Bridge")
    Commissioner::RequestCommissioningApprovalRequest.from_tlv(request.to_tlv(nil)).label.should eq("Bridge")
    response = commissioner_window
    Commissioner::ReverseOpenCommissioningWindowResponse.from_tlv(response.to_tlv(nil)).salt.size.should eq(16)
  end

  it "requires a CASE identity and fails closed without a host" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, payload : TLV::Any, _fabric : UInt8?) { events << payload; nil }
    request = Commissioner::RequestCommissioningApprovalRequest.new(9_u64, 0xFFF1_u16, 1_u16)
    cluster.request_commissioning_approval(request).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    commissioner_context(cluster)
    cluster.request_commissioning_approval(request).status.should eq(Matter::InteractionModel::StatusCode::Success)
    result = Commissioner::CommissioningRequestResultEvent.from_tlv(events.last)
    result.status_code.should eq(Matter::InteractionModel::StatusCode::Failure)
    result.fabric_index.should eq(1_u8)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(9_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
  end

  it "binds approval to fabric, client node and request ID and consumes a reverse window once" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requested = [] of Commissioner::ApprovalRequest
    events = [] of Tuple(TLV::Any, UInt8?)
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, payload : TLV::Any, fabric : UInt8?) { events << {payload, fabric}; nil }
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requested << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        Commissioner::PreparedWindow.new(commissioner_window, -> { nil }).as(Commissioner::PreparedWindow?)
      end
    )
    cluster.supported_device_categories.should eq(Commissioner::FABRIC_SYNCHRONIZATION)
    commissioner_context(cluster)
    command = Commissioner::RequestCommissioningApprovalRequest.new(11_u64, 0xFFF1_u16, 2_u16)
    cluster.request_commissioning_approval(command).status.should eq(Matter::InteractionModel::StatusCode::Success)
    requested.size.should eq(1)
    cluster.request_commissioning_approval(command).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(11_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)

    cluster.resolve_approval(requested.first, Matter::InteractionModel::StatusCode::Success).should be_true
    cluster.resolve_approval(requested.first, Matter::InteractionModel::StatusCode::Success).should be_false
    events.size.should eq(1)
    events.first[1].should eq(1_u8)
    event = Commissioner::CommissioningRequestResultEvent.from_tlv(events.first[0])
    event.request_id.should eq(11_u64)
    event.client_node_id.should eq(42_u64)
    event.status_code.should eq(Matter::InteractionModel::StatusCode::Success)
    commissioner_context(cluster, 2_u8)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(11_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    commissioner_context(cluster, 1_u8, 43_u64)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(11_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    commissioner_context(cluster)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(12_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(11_u64))
      .as(Commissioner::ReverseOpenCommissioningWindowResponse).discriminator.should eq(3840_u16)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(11_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.expire_approval(requested.first).should be_true
    cluster.expire_approval(requested.first).should be_false
  end

  it "validates request and reverse window bounds and erases a removed fabric" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requested = [] of Commissioner::ApprovalRequest
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requested << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        response = Commissioner::ReverseOpenCommissioningWindowResponse.new(
          180_u16, Bytes.new(96, 0_u8), 3840_u16, 1000_u32, Bytes.new(16, 0_u8))
        Commissioner::PreparedWindow.new(response, -> { nil }).as(Commissioner::PreparedWindow?)
      end
    )
    commissioner_context(cluster)
    overlong = Commissioner::RequestCommissioningApprovalRequest.new(1_u64, 1_u16, 1_u16, "x" * 65)
    cluster.request_commissioning_approval(overlong).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(2_u64, 1_u16, 1_u16))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.resolve_approval(requested.first, Matter::InteractionModel::StatusCode::Success).should be_true
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(2_u64, 29_u16))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(2_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.remove_fabric(1_u8)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(2_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
  end

  it "bounds outstanding approvals and rejects stale decisions after ID reuse" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requested = [] of Commissioner::ApprovalRequest
    results = [] of Commissioner::CommissioningRequestResultEvent
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, payload : TLV::Any, _fabric : UInt8?) do
      results << Commissioner::CommissioningRequestResultEvent.from_tlv(payload)
      nil
    end
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requested << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        Commissioner::PreparedWindow.new(commissioner_window, -> { nil }).as(Commissioner::PreparedWindow?)
      end
    )
    commissioner_context(cluster)
    (1_u64..(Commissioner::MAX_TRACKED_APPROVALS + 1).to_u64).each do |id|
      cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(id, 1_u16, 1_u16))
        .status.should eq(Matter::InteractionModel::StatusCode::Success)
    end
    results.size.should eq(1)
    results.first.request_id.should eq(1_u64)
    results.first.status_code.should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.resolve_approval(requested.first, Matter::InteractionModel::StatusCode::Success).should be_false

    stale = requested[1]
    cluster.expire_approval(stale).should be_true
    cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(2_u64, 1_u16, 1_u16))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    fresh = requested.last
    fresh.generation.should_not eq(stale.generation)
    cluster.resolve_approval(stale, Matter::InteractionModel::StatusCode::Success).should be_false
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(2_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.resolve_approval(fresh, Matter::InteractionModel::StatusCode::Success).should be_true
  end

  it "withholds reverse-window credentials when its fabric is removed during host work" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requested = [] of Commissioner::ApprovalRequest
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requested << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        cluster.remove_fabric(1_u8)
        Commissioner::PreparedWindow.new(commissioner_window, -> { nil }).as(Commissioner::PreparedWindow?)
      end
    )
    commissioner_context(cluster)
    cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(1_u64, 1_u16, 1_u16))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.resolve_approval(requested.first, Matter::InteractionModel::StatusCode::Success).should be_true
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(1_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
  end

  it "prepares reverse-window credentials without starting commissioning before response delivery" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requests = [] of Commissioner::ApprovalRequest
    started = 0
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requests << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        Commissioner::PreparedWindow.new(commissioner_window, -> { started += 1; nil }).as(Commissioner::PreparedWindow?)
      end
    )
    commissioner_context(cluster)
    cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(51_u64, 1_u16, 1_u16))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.resolve_approval(requests.first, Matter::InteractionModel::StatusCode::Success).should be_true
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(51_u64))
      .as(Commissioner::ReverseOpenCommissioningWindowResponse).discriminator.should eq(3840_u16)
    started.should eq(0)
    cluster.take_pending_commissions.size.should eq(1)
    started.should eq(0)
  end

  it "releases a preparation claim after callback failure or invalid parameters, then consumes a valid response" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requests = [] of Commissioner::ApprovalRequest
    attempts = 0
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requests << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        attempts += 1
        case attempts
        when 1
          raise Matter::CommissioningError.new("temporary preparation failure")
        when 2
          invalid = Commissioner::ReverseOpenCommissioningWindowResponse.new(
            180_u16, Bytes.new(96, 0_u8), 3840_u16, 1000_u32, Bytes.new(16, 0_u8))
          Commissioner::PreparedWindow.new(invalid, -> { nil }).as(Commissioner::PreparedWindow?)
        else
          Commissioner::PreparedWindow.new(commissioner_window, -> { nil }).as(Commissioner::PreparedWindow?)
        end
      end)
    commissioner_context(cluster)
    cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(61_u64, 1_u16, 1_u16))
    cluster.resolve_approval(requests.first, Matter::InteractionModel::StatusCode::Success)
    expect_raises(Matter::CommissioningError) do
      cluster.commission_node(Commissioner::CommissionNodeRequest.new(61_u64))
    end
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(61_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(61_u64))
      .as(Commissioner::ReverseOpenCommissioningWindowResponse)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(61_u64))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    attempts.should eq(3)
  end

  it "does not start a drained task after its fabric has been removed" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requests = [] of Commissioner::ApprovalRequest
    started = 0
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requests << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        Commissioner::PreparedWindow.new(commissioner_window, -> { started += 1; nil })
          .as(Commissioner::PreparedWindow?)
      end)
    commissioner_context(cluster)
    cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(71_u64, 1_u16, 1_u16))
    cluster.resolve_approval(requests.first, Matter::InteractionModel::StatusCode::Success)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(71_u64))
      .as(Commissioner::ReverseOpenCommissioningWindowResponse)
    task = cluster.take_pending_commissions.first
    cluster.remove_fabric(1_u8)
    task.call
    started.should eq(0)
  end

  it "drops PIN-bearing pending work when its approval expires" do
    cluster = Commissioner.new(Matter::DataType::EndpointNumber.new(0_u16))
    requests = [] of Commissioner::ApprovalRequest
    cluster.configure_host(
      ->(approval : Commissioner::ApprovalRequest) { requests << approval; nil },
      ->(_approval : Commissioner::ApprovalRequest, _command : Commissioner::CommissionNodeRequest) do
        Commissioner::PreparedWindow.new(commissioner_window, -> { nil }).as(Commissioner::PreparedWindow?)
      end)
    commissioner_context(cluster)
    cluster.request_commissioning_approval(Commissioner::RequestCommissioningApprovalRequest.new(81_u64, 1_u16, 1_u16))
    cluster.resolve_approval(requests.first, Matter::InteractionModel::StatusCode::Success)
    cluster.commission_node(Commissioner::CommissionNodeRequest.new(81_u64))
      .as(Commissioner::ReverseOpenCommissioningWindowResponse)
    cluster.expire_approval(requests.first).should be_true
    cluster.take_pending_commissions.should be_empty
  end
end
