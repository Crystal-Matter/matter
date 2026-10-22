require "./support/console"
require "./support/main"

# Synthetic TV lineup for official chip-tool interoperability checks.
module MatterChannel
  alias Channel = Matter::Cluster::Channel

  class Device < Matter::Device
    include Examples::Console

    CHANNELS = [
      Channel::ChannelInfo.new(7_u16, 1_u16, "Seven", identifier: "news-seven"),
      Channel::ChannelInfo.new(9_u16, 0_u16, "Nine", identifier: "sports-nine"),
    ]

    identity vendor: "Spider-Gazelle", product: "Synthetic Channel TV",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_channel_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Channel,
        feature_map: Channel::Feature::ChannelList | Channel::Feature::LineupInfo |
                     Channel::Feature::ElectronicGuide | Channel::Feature::RecordProgram,
        channels: CHANNELS,
        lineup: Channel::LineupInfo.new("Synthetic Cable", Channel::LineupInfoType::MSO)
    end

    protected def before_start : Nil
      channel = node.get_cluster!(1_u16, Channel)
      channel.on_select { |_selected| true }
      channel.on_program_guide do |_request|
        Channel::ProgramGuideResponse.new(
          Channel::ChannelPaging.new,
          [Channel::Program.new("news-100", CHANNELS.first, 100_u32, 200_u32, "Evening News",
            recording_flag: Channel::RecordingFlag::Scheduled)])
      end
      channel.on_record do |_request, _cancel|
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Channel TV") { MatterChannel::Device.new }
