require "./support/console"
require "./support/main"

# Synthetic Matter 1.6 Ambient Context Sensing fixture. A host supplies
# classified observations; the test hook is enabled only when explicitly set.
module MatterAmbientContext
  class Device < Matter::Device
    include Examples::Console

    alias Ambient = Matter::Cluster::AmbientContextSensing
    UNKNOWN_OBJECT            = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
    PERSON_OBJECT             = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
    UNKNOWN_SOUND             = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Unknown)
    BARKING_SOUND             = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)
    UNKNOWN_ACTIVITY          = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
    WALKING_ACTIVITY          = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
    MATTER_EPOCH_UNIX_SECONDS = 946_684_800_i64
    OBJECT_ONLY_ENDPOINT      =           6_u16

    @hook_active = false
    @prediction_now = (Time.utc.to_unix - MATTER_EPOCH_UNIX_SECONDS).to_u32
    @sound_prediction_now = (Time.utc.to_unix - MATTER_EPOCH_UNIX_SECONDS).to_u32

    identity vendor: "Spider-Gazelle", product: "Synthetic Ambient Context",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_ambient_context_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Ambient,
        supported_activity_tags: [
          Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown),
          Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking),
        ],
        hold_time: 30_u16,
        as: :ambient
    end

    endpoint 2, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Ambient,
        feature_map: Ambient::Feature::ObjectCounting | Ambient::Feature::ObjectIdentification,
        supported_object_tags: [UNKNOWN_OBJECT, PERSON_OBJECT],
        object_count_config: Ambient::ObjectCountConfig.new(PERSON_OBJECT, 2_u16),
        hold_time: 30_u16,
        as: :object_ambient
    end

    endpoint 3, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Ambient,
        feature_map: Ambient::Feature::SoundIdentification,
        supported_sound_tags: [UNKNOWN_SOUND, BARKING_SOUND],
        hold_time: 30_u16,
        as: :sound_ambient
    end

    endpoint 4, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Ambient,
        feature_map: Ambient::Feature::HumanActivity | Ambient::Feature::PredictedActivity,
        supported_activity_tags: [UNKNOWN_ACTIVITY, WALKING_ACTIVITY],
        hold_time_limits: Ambient::HoldTimeLimits.new(1_u16, 10_u16, 1_u16),
        prediction_clock: -> : UInt32? { @prediction_now },
        as: :predicted_ambient
    end

    endpoint 5, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Ambient,
        feature_map: Ambient::Feature::SoundIdentification | Ambient::Feature::PredictedActivity,
        supported_sound_tags: [UNKNOWN_SOUND, BARKING_SOUND],
        prediction_clock: -> : UInt32? { @sound_prediction_now },
        as: :predicted_sound_ambient
    end

    endpoint OBJECT_ONLY_ENDPOINT, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Ambient,
        feature_map: Ambient::Feature::ObjectIdentification,
        supported_object_tags: [UNKNOWN_OBJECT, PERSON_OBJECT],
        hold_time: 30_u16,
        as: :identified_object_ambient
    end

    protected def on_started : Nil
      super
      if path = ENV["MATTER_AMBIENT_CONTEXT_HOOK_PATH"]?
        @hook_active = true
        spawn { poll_hook(path) }
      end
    end

    protected def on_shutdown : Nil
      @hook_active = false
      super
    end

    private def poll_hook(path : String) : Nil
      while @hook_active
        if File.exists?(path)
          nonce = File.read(path).strip
          File.delete(path)
          if nonce.starts_with?("walking:")
            ambient.observe_human_activity(Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking))
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("person-count:")
            count = nonce.split(':')[1].to_u16
            object_ambient.observe_object_count(PERSON_OBJECT, count)
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("person-present:")
            identified_object_ambient.observe_object(PERSON_OBJECT, true)
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("person-absent:")
            identified_object_ambient.observe_object(PERSON_OBJECT, false)
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("barking:")
            sound_ambient.observe_sound(BARKING_SOUND)
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("predict-walking:")
            first_start = @prediction_now + 120_u32
            predicted_ambient.replace_predicted_activities([
              Ambient::PredictedActivityStruct.new(first_start, first_start + 60_u32,
                [WALKING_ACTIVITY], 80_u8),
              Ambient::PredictedActivityStruct.new(first_start + 120_u32, first_start + 180_u32,
                [UNKNOWN_ACTIVITY], 60_u8),
            ])
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("advance-prediction-clock:")
            @prediction_now += 120_u32
            predicted_ambient.refresh_predicted_activities
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("predict-barking:")
            start_at = @sound_prediction_now + 120_u32
            predicted_sound_ambient.replace_predicted_activities([
              Ambient::PredictedActivityStruct.new(start_at, start_at + 60_u32,
                [BARKING_SOUND], 80_u8),
              Ambient::PredictedActivityStruct.new(start_at + 120_u32, start_at + 180_u32,
                [UNKNOWN_SOUND], 60_u8),
            ])
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("advance-sound-prediction-clock:")
            @sound_prediction_now += 120_u32
            predicted_sound_ambient.refresh_predicted_activities
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("barking-pred:")
            predicted_sound_ambient.observe_sound(BARKING_SOUND)
            File.write("#{path}.ack", nonce)
          elsif nonce.starts_with?("walking-cap:")
            spawn do
              started_at = Time.instant
              predicted_ambient.observe_human_activity(WALKING_ACTIVITY)
              File.write("#{path}.started", nonce)
              while Time.instant - started_at < 9.4.seconds && @hook_active
                sleep 250.milliseconds
                predicted_ambient.observe_human_activity(WALKING_ACTIVITY)
              end
              remaining = started_at + 10.2.seconds - Time.instant
              sleep remaining if remaining > 0.seconds
              state = predicted_ambient.human_activity_detected? ? "active" : "expired"
              File.write("#{path}.ack", "#{nonce}:#{state}")
            end
          end
        end
        sleep 100.milliseconds
      end
    end
  end
end

Examples.main("Synthetic Ambient Context Sensor") { MatterAmbientContext::Device.new }
