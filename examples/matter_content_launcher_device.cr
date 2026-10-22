require "./support/console"
require "./support/main"

# Synthetic media application: host callbacks model search and URL launch.
# Production devices replace these callbacks with catalog and player logic.
module MatterContentLauncher
  alias Launcher = Matter::Cluster::ContentLauncher

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Content Launcher",
      vendor_id: 0xFFF1_u16,
      product_id: 0x050A_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_content_launcher_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Launcher,
        feature_map: Launcher::Feature::ContentSearch |
                     Launcher::Feature::UrlPlayback |
                     Launcher::Feature::AdvancedSeek |
                     Launcher::Feature::TextTracks |
                     Launcher::Feature::AudioTracks,
        accept_header: ["video/mp4", "application/vnd.apple.mpegurl"],
        supported_streaming_protocols: 3_u32
    end

    endpoint 2, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Launcher, feature_map: Launcher::Feature::ContentSearch
    end

    protected def before_start : Nil
      [1_u16, 2_u16].each do |endpoint|
        launcher = node.get_cluster!(endpoint, Launcher)
        launcher.on_launch_content do |request|
          puts "LaunchContent on endpoint #{endpoint}: #{request.search.parameter_list.size} parameters"
          Launcher::LauncherResponse.new(Launcher::Status::Success, "search accepted")
        end
        next unless endpoint == 1_u16
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
