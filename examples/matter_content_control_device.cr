require "./support/console"
require "./support/main"

# Synthetic Basic Video Player. A production player calls playback_allowed?
# before starting and while continuing media playback.
module MatterContentControl
  alias Control = Matter::Cluster::ContentControl
  alias Playback = Matter::Cluster::MediaPlayback

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Content Control Player",
      vendor_id: 0xFFF1_u16,
      product_id: 0x050F_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_content_control_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::BASIC_VIDEO_PLAYER do
      cluster Matter::Cluster::OnOff
      cluster Playback, as: :playback
      cluster Matter::Cluster::KeypadInput
      cluster Control,
        feature_map: Control::Feature::BlockUnrated | Control::Feature::OnDemandContentRating,
        on_demand_ratings: [
          Control::RatingName.new("G"),
          Control::RatingName.new("PG"),
          Control::RatingName.new("R"),
        ],
        on_demand_rating_threshold: "R",
        as: :content_control
    end

    protected def before_start : Nil
      playback.on_command do |command, _operation|
        if command.play? && !content_control.playback_allowed?(rating: nil)
          Playback::PlaybackStatus::NotAllowed
        else
          Playback::PlaybackStatus::Success
        end
      end
      content_control.on_policy_changed do
        if playback.current_state.playing? && !content_control.playback_allowed?(rating: nil)
          playback.report_state(Playback::PlaybackState::NotPlaying)
        end
      end
      super
    end
  end
end

Examples.main("Synthetic Content Control Player") { MatterContentControl::Device.new }
