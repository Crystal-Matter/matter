require "./support/console"
require "./support/main"

# Synthetic video player with host-owned playback decisions and track lists.
# Aggregator is used as a wire fixture because this example does not claim all
# required clusters of the Basic Video Player device type.
module MatterMediaPlayback
  DEVICE_ENDPOINT_ID = 1_u16

  class Device < Matter::Device
    include Examples::Console

    alias Playback = Matter::Cluster::MediaPlayback

    MEDIA_DURATION_MS           =     120_000_u64
    INITIAL_SCAN_RATE           =           2_f32
    MAX_SCAN_RATE               =           8_f32
    MATTER_EPOCH_UNIX_SECONDS   = 946_684_800_i64
    MICROSECONDS_PER_SECOND     =   1_000_000_i64
    NANOSECONDS_PER_MICROSECOND =       1_000_i64

    identity vendor: "Spider-Gazelle", product: "Synthetic Media Player",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_media_playback_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Playback, feature_map: Playback::Feature::AdvancedSeek |
                                     Playback::Feature::VariableSpeed | Playback::Feature::AudioTracks |
                                     Playback::Feature::TextTracks | Playback::Feature::AudioAdvance,
        optional_commands: [Playback::Command::StartOver, Playback::Command::SkipForward,
                            Playback::Command::SkipBackward]
    end

    protected def before_start : Nil
      player = node.endpoint!(DEVICE_ENDPOINT_ID).get_cluster!(Playback)
      player.update_seek_range(0_u64, MEDIA_DURATION_MS, MEDIA_DURATION_MS)
      audio = Playback::Track.new("eng", Playback::TrackAttributes.new("en", [Playback::Characteristic::MainProgram], "English"))
      captions = Playback::Track.new("captions", Playback::TrackAttributes.new("en", [Playback::Characteristic::Caption], "English captions"))
      player.update_audio_tracks([audio], audio)
      player.update_text_tracks([captions])
      player.on_command do |command, operation|
        case command
        when .seek?
          player.report_state(player.current_state,
            position: sample(operation.position))
          Playback::PlaybackStatus::Success
        when .start_over?
          player.report_state(Playback::PlaybackState::Playing,
            position: sample(0_u64))
          Playback::PlaybackStatus::Success
        when .rewind?, .fast_forward?
          previous = player.playback_speed
          rate = if command.rewind?
                   previous < 0_f32 ? previous * INITIAL_SCAN_RATE : -INITIAL_SCAN_RATE
                 else
                   previous > 1_f32 ? previous * INITIAL_SCAN_RATE : INITIAL_SCAN_RATE
                 end
          if rate.abs > MAX_SCAN_RATE
            Playback::PlaybackStatus::SpeedOutOfRange
          else
            player.report_state(Playback::PlaybackState::Playing, speed: rate,
              audio_advance_unmuted: operation.audio_advance_unmuted?)
            Playback::PlaybackStatus::Success
          end
        when .skip_forward?, .skip_backward?
          current = player.sampled_position.try(&.position) || 0_u64
          delta = operation.delta_position_milliseconds || 0_u64
          position = if command.skip_forward?
                       remaining = current < MEDIA_DURATION_MS ? MEDIA_DURATION_MS - current : 0_u64
                       current + {delta, remaining}.min
                     else
                       current > delta ? current - delta : 0_u64
                     end
          player.report_state(player.current_state,
            position: sample(position))
          Playback::PlaybackStatus::Success
        else
          Playback::PlaybackStatus::Success
        end
      end
      super
    end

    private def sample(position : UInt64?) : Playback::PlaybackPosition
      now = Time.utc
      microseconds = (now.to_unix - MATTER_EPOCH_UNIX_SECONDS) * MICROSECONDS_PER_SECOND +
                     now.nanosecond // NANOSECONDS_PER_MICROSECOND
      Playback::PlaybackPosition.new(microseconds.to_u64, position)
    end
  end
end

Examples.main("Synthetic Media Player") { MatterMediaPlayback::Device.new }
