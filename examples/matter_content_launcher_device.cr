require "./support/console"
require "./support/main"

# Synthetic media application: host callbacks model search and URL launch.
# Production devices replace these callbacks with catalog and player logic.
module MatterContentLauncher
  SEARCH_AND_URL_ENDPOINT_ID = 1_u16
  SEARCH_ONLY_ENDPOINT_ID    = 2_u16

  EXAMPLE_PRODUCT_ID = 0x050A_u16

  alias Launcher = Matter::Cluster::ContentLauncher

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Content Launcher",
      vendor_id: Matter::Fabric::DEFAULT_VENDOR_ID,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_content_launcher_storage.yml"

    endpoint SEARCH_AND_URL_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Launcher,
        feature_map: Launcher::Feature::ContentSearch |
                     Launcher::Feature::UrlPlayback |
                     Launcher::Feature::AdvancedSeek |
                     Launcher::Feature::TextTracks |
                     Launcher::Feature::AudioTracks,
        accept_header: ["video/mp4", "application/vnd.apple.mpegurl"],
        supported_streaming_protocols: Launcher::SUPPORTED_PROTOCOLS_MASK
    end

    endpoint SEARCH_ONLY_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Launcher, feature_map: Launcher::Feature::ContentSearch
    end

    protected def before_start : Nil
      [SEARCH_AND_URL_ENDPOINT_ID, SEARCH_ONLY_ENDPOINT_ID].each do |endpoint|
        launcher = node.get_cluster!(endpoint, Launcher)
        launcher.on_launch_content do |request|
          puts "LaunchContent on endpoint #{endpoint}: #{request.search.parameter_list.size} parameters"
          Launcher::LauncherResponse.new(Launcher::Status::Success, "search accepted")
        end
        next unless endpoint == SEARCH_AND_URL_ENDPOINT_ID
        launcher.on_launch_url do |request|
          puts "LaunchURL on endpoint #{endpoint}: #{request.content_url}"
          status = request.content_url.includes?("unavailable") ? Launcher::Status::UrlNotAvailable : Launcher::Status::Success
          Launcher::LauncherResponse.new(status)
        end
      end
      super
    end
  end
end

Examples.main("Synthetic Content Launcher") { MatterContentLauncher::Device.new }
