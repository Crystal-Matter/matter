require "./support/console"
require "./support/main"

# Synthetic Audio Output fixture. A media product would wire selection to its
# audio path and advertise the other clusters required by its device type.
module MatterAudioOutput
  alias Audio = Matter::Cluster::AudioOutput

  OUTPUTS = [
    Audio::OutputInfo.new(0_u8, Audio::OutputType::Internal, "Speakers"),
    Audio::OutputInfo.new(2_u8, Audio::OutputType::Hdmi, "Soundbar"),
  ]

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Audio Output",
      vendor_id: 0xFFF1_u16, product_id: 0x050B_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_audio_output_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Audio, output_list: OUTPUTS, current_output: 0_u8,
        feature_map: Audio::Feature::NameUpdates
    end

    endpoint 2, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Audio, output_list: OUTPUTS, current_output: 0_u8
    end

    protected def before_start : Nil
      node.get_cluster!(1_u16, Audio).on_select_output do |output|
        puts "Synthetic audio route: #{output.index}"
        true
      end
      node.get_cluster!(2_u16, Audio).on_select_output { |_output| true }
      super
    end
  end
end

Examples.main("Synthetic Audio Output") { MatterAudioOutput::Device.new }
