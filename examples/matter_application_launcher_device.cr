require "./support/console"
require "./support/main"

# Synthetic video player. The host callbacks model application availability,
# foreground focus, and lifecycle; production players connect real app state.
module MatterApplicationLauncher
  PLATFORM_ENDPOINT_ID  = 1_u16
  LOCAL_APP_ENDPOINT_ID = 2_u16

  EXAMPLE_PRODUCT_ID = 0x050C_u16

  alias Launcher = Matter::Cluster::ApplicationLauncher
  alias ApplicationBasic = Matter::Cluster::ApplicationBasic

  CATALOG_VENDOR_ID = 0xFFF1_u16
  APP_ID            = "crystal.radio"

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Application Launcher",
      vendor_id: Matter::Fabric::DEFAULT_VENDOR_ID,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_application_launcher_storage.yml"

    endpoint PLATFORM_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Launcher, feature_map: Launcher::Feature::ApplicationPlatform,
        catalog_list: [CATALOG_VENDOR_ID]
    end

    endpoint LOCAL_APP_ENDPOINT_ID, device_type: Matter::DeviceType::CONTENT_APP do
      cluster Launcher
      cluster ApplicationBasic,
        application_name: "Crystal Radio",
        application: ApplicationBasic::Application.new(CATALOG_VENDOR_ID, APP_ID),
        application_version: "1.0.0",
        allowed_vendor_list: [CATALOG_VENDOR_ID],
        vendor_name: "Spider-Gazelle",
        vendor_id: CATALOG_VENDOR_ID,
        as: :application_basic
    end

    protected def before_start : Nil
      platform = node.get_cluster!(PLATFORM_ENDPOINT_ID, Launcher)
      local = node.get_cluster!(LOCAL_APP_ENDPOINT_ID, Launcher)
      app_basic = node.get_cluster!(LOCAL_APP_ENDPOINT_ID, ApplicationBasic)
      app_basic.update_status(ApplicationBasic::ApplicationStatus::Stopped)
      platform.on_launch_app do |request|
        app = request.application
        if app && app.application_id == APP_ID
          foreground = Launcher::ApplicationEP.new(app, 2_u16)
          platform.current_app = foreground
          local.current_app = foreground
          app_basic.update_status(ApplicationBasic::ApplicationStatus::ActiveVisibleFocus)
          Launcher::LauncherResponse.new(Launcher::Status::Success, Bytes[0x01])
        elsif app && app.application_id == "pending"
          Launcher::LauncherResponse.new(Launcher::Status::PendingUserApproval)
        else
          Launcher::LauncherResponse.new(Launcher::Status::AppNotAvailable)
        end
      end
      platform.on_stop_app do |request|
        if request.application.try(&.application_id) == APP_ID
          platform.current_app = nil
          local.current_app = nil
          app_basic.update_status(ApplicationBasic::ApplicationStatus::Stopped)
          Launcher::LauncherResponse.new(Launcher::Status::Success)
        else
          Launcher::LauncherResponse.new(Launcher::Status::AppNotAvailable)
        end
      end
      platform.on_hide_app do |request|
        if request.application.try(&.application_id) == APP_ID
          platform.current_app = nil
          local.current_app = nil
          app_basic.update_status(ApplicationBasic::ApplicationStatus::ActiveHidden)
          Launcher::LauncherResponse.new(Launcher::Status::Success)
        else
          Launcher::LauncherResponse.new(Launcher::Status::AppNotAvailable)
        end
      end

      local.on_launch_app do |_request|
        foreground = Launcher::ApplicationEP.new(Launcher::Application.new(CATALOG_VENDOR_ID, APP_ID), 2_u16)
        platform.current_app = foreground
        local.current_app = foreground
        app_basic.update_status(ApplicationBasic::ApplicationStatus::ActiveVisibleFocus)
        Launcher::LauncherResponse.new(Launcher::Status::Success)
      end
      local.on_stop_app do |_request|
        platform.current_app = nil
        local.current_app = nil
        app_basic.update_status(ApplicationBasic::ApplicationStatus::Stopped)
        Launcher::LauncherResponse.new(Launcher::Status::Success)
      end
      local.on_hide_app do |_request|
        platform.current_app = nil
        local.current_app = nil
        app_basic.update_status(ApplicationBasic::ApplicationStatus::ActiveHidden)
        Launcher::LauncherResponse.new(Launcher::Status::Success)
      end
      super
    end
  end
end

Examples.main("Synthetic Application Launcher") { MatterApplicationLauncher::Device.new }
