require "../spec_helper"

private alias ApplicationLauncher = Matter::Cluster::ApplicationLauncher
private alias IMCode = Matter::InteractionModel::StatusCode

private def application_launcher(features : ApplicationLauncher::Feature = ApplicationLauncher::Feature::ApplicationPlatform,
                                 catalogs : Array(UInt16) = [0xFFF1_u16], current_app_supported : Bool = true) : ApplicationLauncher
  build(ApplicationLauncher, feature_map: features, catalog_list: catalogs,
    current_app_supported: current_app_supported)
end

describe ApplicationLauncher do
  it "advertises revision two, mandatory commands, and AP-gated catalogue" do
    platform = application_launcher
    platform.cluster_id.id.should eq(0x050C_u32)
    platform.cluster_revision.should eq(2_u16)
    platform.attributes.map(&.id.id).should eq([ApplicationLauncher::ATTR_CATALOG_LIST, ApplicationLauncher::ATTR_CURRENT_APP])
    platform.commands.map(&.id.id).should eq([
      ApplicationLauncher::CMD_LAUNCH_APP,
      ApplicationLauncher::CMD_STOP_APP,
      ApplicationLauncher::CMD_HIDE_APP,
    ])
    read_tlv(platform, ApplicationLauncher::ATTR_CURRENT_APP).value.should be_nil
    read_tlv(platform, ApplicationLauncher::ATTR_CATALOG_LIST).as_list.map(&.value.as(UInt16)).should eq([0xFFF1_u16])

    endpoint_app = application_launcher(ApplicationLauncher::Feature::None, [] of UInt16)
    endpoint_app.attributes.map(&.id.id).should eq([ApplicationLauncher::ATTR_CURRENT_APP])
    endpoint_app.commands.map(&.id.id).should eq(platform.commands.map(&.id.id))
    read_status(endpoint_app, ApplicationLauncher::ATTR_CATALOG_LIST).status.should eq(IMCode::UnsupportedAttribute)
    application_launcher(current_app_supported: false).attributes.map(&.id.id).should eq([ApplicationLauncher::ATTR_CATALOG_LIST])
  end

  it "encodes typed application, optional endpoint, opaque data, and all revision-two statuses" do
    app = ApplicationLauncher::Application.new(0xFFF1_u16, "PruneVideo")
    app.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    ApplicationLauncher::Application.from_tlv(app.to_tlv(nil)).application_id.should eq("PruneVideo")
    ApplicationLauncher::ApplicationEP.new(app).to_tlv(nil).as_structure.keys.should eq([0_u8])
    ApplicationLauncher::ApplicationEP.new(app, 2_u16).to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])

    launch = ApplicationLauncher::LaunchAppRequest.new(app, Bytes[0x00, 0xFF])
    launch.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    ApplicationLauncher::LaunchAppRequest.from_tlv(launch.to_tlv(nil)).data.should eq(Bytes[0x00, 0xFF])
    ApplicationLauncher::LaunchAppRequest.new.to_tlv(nil).as_structure.should be_empty
    ApplicationLauncher::StopAppRequest.new(app).to_tlv(nil).as_structure.keys.should eq([0_u8])
    ApplicationLauncher::HideAppRequest.new.to_tlv(nil).as_structure.should be_empty

    [ApplicationLauncher::Status::Success, ApplicationLauncher::Status::AppNotAvailable,
     ApplicationLauncher::Status::SystemBusy, ApplicationLauncher::Status::PendingUserApproval,
     ApplicationLauncher::Status::Downloading, ApplicationLauncher::Status::Installing].each_with_index do |status, index|
      status.value.should eq(index)
      response = ApplicationLauncher::LauncherResponse.new(status, Bytes[0x00, 0xFF])
      ApplicationLauncher::LauncherResponse.from_tlv(response.to_tlv(nil)).data.should eq(Bytes[0x00, 0xFF])
    end
  end

  it "requires an application only with AP and leaves host launch decisions to callbacks" do
    platform = application_launcher
    app = ApplicationLauncher::Application.new(0xFFF1_u16, "PruneVideo")
    other_catalog = ApplicationLauncher::Application.new(0xFFF2_u16, "PruneVideo")
    launch = ApplicationLauncher::LaunchAppRequest.new(app, Bytes[0x00])
    platform.launch_app(ApplicationLauncher::LaunchAppRequest.new).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    platform.launch_app(ApplicationLauncher::LaunchAppRequest.new(other_catalog)).as(ApplicationLauncher::LauncherResponse).status.should eq(ApplicationLauncher::Status::AppNotAvailable)
    platform.launch_app(launch).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidInState)
    calls = 0
    platform.on_launch_app do |request|
      calls += 1
      if requested_app = request.application
        platform.current_app = ApplicationLauncher::ApplicationEP.new(requested_app, 2_u16)
      end
      ApplicationLauncher::LauncherResponse.new(ApplicationLauncher::Status::Success, Bytes[0x55])
    end
    response = invoke(platform, ApplicationLauncher::CMD_LAUNCH_APP, launch).as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(ApplicationLauncher::CMD_LAUNCH_APP_RESPONSE)
    ApplicationLauncher::LauncherResponse.from_tlv(response.response.as(TLV::Any)).status.should eq(ApplicationLauncher::Status::Success)
    platform.current_app.try(&.endpoint).should eq(2_u16)
    calls.should eq(1)

    endpoint_app = application_launcher(ApplicationLauncher::Feature::None, [] of UInt16)
    endpoint_app.launch_app(launch).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    endpoint_app.launch_app(ApplicationLauncher::LaunchAppRequest.new).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidInState)
    endpoint_app.on_launch_app do |request|
      request.application.should be_nil
      ApplicationLauncher::LauncherResponse.new(ApplicationLauncher::Status::Success)
    end
    endpoint_app.launch_app(ApplicationLauncher::LaunchAppRequest.new).as(ApplicationLauncher::LauncherResponse).status.should eq(ApplicationLauncher::Status::Success)
  end

  it "dispatches stop and hide with typed host responses and AP field validation" do
    platform = application_launcher
    app = ApplicationLauncher::Application.new(0xFFF1_u16, "PruneVideo")
    platform.stop_app(ApplicationLauncher::StopAppRequest.new).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    platform.hide_app(ApplicationLauncher::HideAppRequest.new).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    platform.on_stop_app do |request|
      request.application.should eq(app)
      ApplicationLauncher::LauncherResponse.new(ApplicationLauncher::Status::Success)
    end
    platform.on_hide_app do |request|
      request.application.should eq(app)
      ApplicationLauncher::LauncherResponse.new(ApplicationLauncher::Status::SystemBusy)
    end
    stop = invoke(platform, ApplicationLauncher::CMD_STOP_APP, ApplicationLauncher::StopAppRequest.new(app)).as(Matter::Cluster::CommandResponse)
    stop.command_id.should eq(ApplicationLauncher::CMD_STOP_APP_RESPONSE)
    hide = invoke(platform, ApplicationLauncher::CMD_HIDE_APP, ApplicationLauncher::HideAppRequest.new(app)).as(Matter::Cluster::CommandResponse)
    ApplicationLauncher::LauncherResponse.from_tlv(hide.response.as(TLV::Any)).status.should eq(ApplicationLauncher::Status::SystemBusy)
  end

  it "copies the nonvolatile catalogue across callers, readers, setters, and restore" do
    catalogs = [0xFFF1_u16]
    platform = application_launcher(catalogs: catalogs)
    version = platform.data_version
    catalogs.clear
    platform.catalog_list.clear
    platform.catalog_list.should eq([0xFFF1_u16])
    platform.data_version.should eq(version)
    expect_raises(ArgumentError) { platform.catalog_list = [0xFFF1_u16, 0xFFF1_u16] }
    endpoint_app = application_launcher(ApplicationLauncher::Feature::None, [] of UInt16)
    expect_raises(ArgumentError) { endpoint_app.catalog_list = [0xFFF1_u16] }

    replacement = [0xFFF2_u16]
    platform.catalog_list = replacement
    replacement.clear
    platform.catalog_list.should eq([0xFFF2_u16])
    saved = platform.save_state.as(Matter::Storage::Document)
    restored = application_launcher(catalogs: [0xFFF1_u16])
    restored.restore_state(saved)
    restored.catalog_list.should eq([0xFFF2_u16])
    restored.current_app.should be_nil
  end
end
