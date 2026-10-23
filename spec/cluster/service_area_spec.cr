require "../spec_helper"
require "../../src/matter/cluster/service_area"

private alias ServiceArea = Matter::Cluster::ServiceArea
private alias IMCode = Matter::InteractionModel::StatusCode

private def area(id : UInt32, name : String, map : UInt32? = nil) : ServiceArea::Area
  ServiceArea::Area.new(id, map, ServiceArea::AreaInfo.new(ServiceArea::LocationInfo.new(name)))
end

private def service_area(areas = [area(1_u32, "Kitchen"), area(2_u32, "Hall")],
                         selected = [] of UInt32,
                         feature_map = ServiceArea::Feature::None) : ServiceArea
  build(ServiceArea, areas: areas, selected_areas: selected, feature_map: feature_map)
end

describe ServiceArea do
  it "advertises revision two and the mandatory typed SelectAreas response" do
    cluster = service_area
    cluster.cluster_id.id.should eq(0x0150_u32)
    read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(2_u16)
    attribute_ids(cluster).should contain(ServiceArea::ATTR_SUPPORTED_AREAS)
    attribute_ids(cluster).should contain(ServiceArea::ATTR_SELECTED_AREAS)
    attribute_ids(cluster).should_not contain(ServiceArea::ATTR_SUPPORTED_MAPS)
    attribute_ids(cluster).should_not contain(ServiceArea::ATTR_PROGRESS)
    accepted_command_ids(cluster).should eq([ServiceArea::CMD_SELECT_AREAS])
    generated_command_ids(cluster).should eq([ServiceArea::CMD_SELECT_AREAS_RESPONSE])
    read_tlv(cluster, ServiceArea::ATTR_SUPPORTED_AREAS).as_list.size.should eq(2)
    ServiceArea::SelectAreasResponse.new(ServiceArea::SelectAreasStatus::Success).to_tlv(nil)
      .as_structure.keys.should eq([0_u8, 1_u8])
  end

  it "selects valid areas in request order, collapsing duplicate IDs" do
    cluster = service_area
    response = invoke_response(cluster, ServiceArea::CMD_SELECT_AREAS,
      ServiceArea::SelectAreasRequest.new([2_u32, 1_u32, 2_u32]), ServiceArea::SelectAreasResponse)
    response.status.should eq(ServiceArea::SelectAreasStatus::Success)
    cluster.selected_areas.should eq([2_u32, 1_u32])
    response = invoke_response(cluster, ServiceArea::CMD_SELECT_AREAS,
      ServiceArea::SelectAreasRequest.new([] of UInt32), ServiceArea::SelectAreasResponse)
    response.status.should eq(ServiceArea::SelectAreasStatus::Success)
    cluster.selected_areas.should be_empty
  end

  it "reports unsupported areas and host-rejected sets without changing selection" do
    cluster = service_area(selected: [1_u32])
    unsupported = invoke_response(cluster, ServiceArea::CMD_SELECT_AREAS,
      ServiceArea::SelectAreasRequest.new([1_u32, 9_u32]), ServiceArea::SelectAreasResponse)
    unsupported.status.should eq(ServiceArea::SelectAreasStatus::UnsupportedArea)
    cluster.on_select { |_ids| ServiceArea::SelectAreasResponse.new(ServiceArea::SelectAreasStatus::InvalidSet, "Unreachable route") }
    rejected = invoke_response(cluster, ServiceArea::CMD_SELECT_AREAS,
      ServiceArea::SelectAreasRequest.new([2_u32]), ServiceArea::SelectAreasResponse)
    rejected.status.should eq(ServiceArea::SelectAreasStatus::InvalidSet)
    rejected.status_text.should eq("Unreachable route")
    cluster.selected_areas.should eq([1_u32])
  end

  it "blocks changes while operating unless SelectWhileRunning is enabled" do
    cluster = service_area
    cluster.on_operating { true }
    denied = invoke_response(cluster, ServiceArea::CMD_SELECT_AREAS,
      ServiceArea::SelectAreasRequest.new([1_u32]), ServiceArea::SelectAreasResponse)
    denied.status.should eq(ServiceArea::SelectAreasStatus::InvalidInMode)
    denied.status_text.should_not be_empty
    cluster.selected_areas.should be_empty

    enabled = service_area(feature_map: ServiceArea::Feature::SelectWhileRunning)
    enabled.on_operating { true }
    accepted = invoke_response(enabled, ServiceArea::CMD_SELECT_AREAS,
      ServiceArea::SelectAreasRequest.new([1_u32]), ServiceArea::SelectAreasResponse)
    accepted.status.should eq(ServiceArea::SelectAreasStatus::Success)
  end

  it "validates area and map catalogues, including meaningful semantic data" do
    expect_raises(ArgumentError) { ServiceArea::AreaInfo.new(nil, nil) }
    expect_raises(ArgumentError) { ServiceArea::AreaInfo.new(ServiceArea::LocationInfo.new("")) }
    expect_raises(ArgumentError, /duplicate/) { service_area([area(1_u32, "A"), area(1_u32, "B")]) }
    expect_raises(ArgumentError, /duplicate/) { service_area([area(1_u32, "A"), area(2_u32, "A")]) }
    expect_raises(ArgumentError) { ServiceArea::MapInfo.new(1_u32, "x" * 65) }
    expect_raises(ArgumentError) do
      build(ServiceArea, areas: [area(1_u32, "A", 7_u32)],
        maps: [ServiceArea::MapInfo.new(8_u32, "Floor")],
        feature_map: ServiceArea::Feature::Maps)
    end
  end

  it "reconciles selection when a host catalogue changes and when state restores" do
    previous = service_area(selected: [1_u32, 2_u32])
    saved = previous.save_state.as(Matter::Storage::Document)
    current = service_area([area(2_u32, "New Hall"), area(3_u32, "Bedroom")])
    current.restore_state(saved)
    current.selected_areas.should eq([2_u32])
    current.update_areas([area(3_u32, "Bedroom")])
    current.selected_areas.should be_empty
    current.supported_areas.map(&.area_id).should eq([3_u32])
  end

  it "exposes maps only with MAPS and removes areas tied to removed maps" do
    cluster = build(ServiceArea,
      areas: [area(1_u32, "Kitchen", 7_u32), area(2_u32, "Hall", 8_u32)],
      maps: [ServiceArea::MapInfo.new(7_u32, "Ground"), ServiceArea::MapInfo.new(8_u32, "Upper")],
      selected_areas: [1_u32, 2_u32], feature_map: ServiceArea::Feature::Maps)
    read_tlv(cluster, ServiceArea::ATTR_SUPPORTED_MAPS).as_list.size.should eq(2)
    snapshots = [] of Array(UInt32)
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _id : UInt32) {
      snapshots << cluster.selected_areas
      nil
    }
    cluster.update_maps([ServiceArea::MapInfo.new(7_u32, "Ground")])
    cluster.selected_areas.should eq([1_u32])
    snapshots.should_not be_empty
    snapshots.each(&.should(eq([1_u32])))
    cluster.supported_areas.map(&.area_id).should eq([1_u32])
    cluster.supported_maps.map(&.map_id).should eq([7_u32])
    expect_raises(ArgumentError) { cluster.update_catalogue([area(1_u32, "Kitchen", 8_u32)]) }
    cluster.supported_areas.map(&.area_id).should eq([1_u32])
  end

  it "publishes optional CurrentArea and Progress with valid references" do
    cluster = build(ServiceArea, areas: [area(1_u32, "Kitchen"), area(2_u32, "Hall")],
      selected_areas: [1_u32], reports_current_area: true, current_area: 1_u32,
      report_estimated_end_time: true, feature_map: ServiceArea::Feature::ProgressReporting)
    attribute_ids(cluster).should contain(ServiceArea::ATTR_CURRENT_AREA)
    attribute_ids(cluster).should contain(ServiceArea::ATTR_ESTIMATED_END_TIME)
    attribute_ids(cluster).should contain(ServiceArea::ATTR_PROGRESS)
    cluster.progress = [ServiceArea::ProgressInfo.new(1_u32, ServiceArea::OperationalStatus::Operating)]
    expect_raises(ArgumentError) do
      cluster.progress = [ServiceArea::ProgressInfo.new(7_u32, ServiceArea::OperationalStatus::Pending)]
    end
    expect_raises(ArgumentError) { cluster.current_area = 7_u32 }
    expect_raises(ArgumentError) { ServiceArea::ProgressInfo.new(1_u32, ServiceArea::OperationalStatus::Pending, 10_u32) }
    reports = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, id : UInt32) { reports << id; nil }
    cluster.report_estimated_end_time(100_u32)
    cluster.report_estimated_end_time(120_u32)
    cluster.report_estimated_end_time(90_u32)
    reports.should eq([ServiceArea::ATTR_ESTIMATED_END_TIME, ServiceArea::ATTR_ESTIMATED_END_TIME])
    cluster.update_areas([area(2_u32, "Hall")])
    cluster.current_area.should be_nil
    cluster.progress.should be_empty
    cluster.estimated_end_time.should be_nil
    reports.count(ServiceArea::ATTR_ESTIMATED_END_TIME).should eq(3)
  end

  it "only advertises SkipArea when opted in and delegates a physical skip" do
    cluster = build(ServiceArea, areas: [area(1_u32, "Kitchen")],
      selected_areas: [1_u32], reports_current_area: true, current_area: 1_u32, skip_enabled: true,
      feature_map: ServiceArea::Feature::ProgressReporting)
    accepted_command_ids(cluster).should contain(ServiceArea::CMD_SKIP_AREA)
    cluster.progress = [ServiceArea::ProgressInfo.new(1_u32, ServiceArea::OperationalStatus::Operating)]
    blocked = invoke_response(cluster, ServiceArea::CMD_SKIP_AREA,
      ServiceArea::SkipAreaRequest.new(1_u32), ServiceArea::SkipAreaResponse)
    blocked.status.should eq(ServiceArea::SkipAreaStatus::InvalidInMode)
    skipped = [] of UInt32
    cluster.on_skip do |id|
      skipped << id
      ServiceArea::SkipAreaResponse.new(ServiceArea::SkipAreaStatus::Success)
    end
    accepted = invoke_response(cluster, ServiceArea::CMD_SKIP_AREA,
      ServiceArea::SkipAreaRequest.new(1_u32), ServiceArea::SkipAreaResponse)
    accepted.status.should eq(ServiceArea::SkipAreaStatus::Success)
    skipped.should eq([1_u32])
    cluster.progress.first.status.should eq(ServiceArea::OperationalStatus::Skipped)
    absent = service_area
    accepted_command_ids(absent).should_not contain(ServiceArea::CMD_SKIP_AREA)
    expect_status(invoke(absent, ServiceArea::CMD_SKIP_AREA, ServiceArea::SkipAreaRequest.new(1_u32)), IMCode::UnsupportedCommand)
  end

  it "initializes constrained progress and marks unfinished areas skipped after an unexpected stop" do
    cluster = build(ServiceArea, areas: [area(1_u32, "Kitchen"), area(2_u32, "Hall")],
      selected_areas: [2_u32, 1_u32], feature_map: ServiceArea::Feature::ProgressReporting)
    cluster.begin_operation
    cluster.progress.map(&.area_id).should eq([2_u32, 1_u32])
    cluster.progress.map(&.status).should eq([
      ServiceArea::OperationalStatus::Pending, ServiceArea::OperationalStatus::Pending,
    ])
    cluster.progress = [ServiceArea::ProgressInfo.new(2_u32, ServiceArea::OperationalStatus::Completed, 30_u32),
                        ServiceArea::ProgressInfo.new(1_u32, ServiceArea::OperationalStatus::Operating)]
    cluster.end_operation_unexpectedly
    cluster.progress.map(&.status).should eq([
      ServiceArea::OperationalStatus::Completed, ServiceArea::OperationalStatus::Skipped,
    ])
  end
end
