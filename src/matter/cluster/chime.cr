require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Chime revision 2. The host owns audio playback; successful
    # playback admission publishes the ChimeStartedPlaying event.
    class Chime < Base
      cluster 0x0556, revision: 2

      MIN_SOUNDS     =   1
      MAX_SOUNDS     = 255
      MIN_NAME_BYTES =   1
      MAX_NAME_BYTES =  48

      struct Sound
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter chime_id : UInt8

        @[TLV::Field(tag: 1)]
        getter name : String

        def initialize(@chime_id : UInt8, @name : String)
          unless (MIN_NAME_BYTES..MAX_NAME_BYTES).includes?(@name.bytesize)
            raise ArgumentError.new("chime sound name must be 1 to 48 bytes")
          end
        end
      end

      struct PlayRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter chime_id : UInt8?

        def initialize(@chime_id : UInt8? = nil)
        end
      end

      struct StartedPlayingEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter chime_id : UInt8

        def initialize(@chime_id : UInt8)
        end
      end

      attribute 0x0000, :installed_chime_sounds, Array(Sound),
        default: [] of Sound, validate: :validate_installed_sounds!
      attribute 0x0001, :selected_chime, UInt8, default: 0_u8,
        writable: true, write_access: :operate, persist: true, validate: :validate_selected_chime!
      attribute 0x0002, :enabled, Bool, default: true,
        writable: true, write_access: :operate, persist: true

      command 0x00, :play_chime_sound, request: PlayRequest, access: :operate
      event 0x00, :chime_started_playing, priority: :info, payload: StartedPlayingEvent

      @play_callback : Proc(UInt8, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     sounds : Array(Sound), @selected_chime : UInt8,
                     @enabled : Bool = true)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_sounds!(sounds)
        unless sounds.any?(&.chime_id.==(@selected_chime))
          raise ArgumentError.new("SelectedChime must name an installed sound")
        end
        @installed_chime_sounds = sounds.dup
      end

      def installed_chime_sounds : Array(Sound)
        @installed_chime_sounds.dup
      end

      def on_play(&block : UInt8 -> InteractionModel::Status) : Nil
        @play_callback = block
      end

      def play_chime_sound(request : PlayRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state unless @enabled
        id = request.chime_id || @selected_chime
        return InteractionModel::Status.not_found unless @installed_chime_sounds.any?(&.chime_id.==(id))
        callback = @play_callback || return InteractionModel::Status.invalid_in_state
        status = callback.call(id)
        emit_chime_started_playing(StartedPlayingEvent.new(id)) if status.success?
        status
      end

      private def validate_installed_sounds!(sounds : Array(Sound)) : Nil
        validate_sounds!(sounds)
        unless sounds.any?(&.chime_id.==(@selected_chime))
          raise ArgumentError.new("InstalledChimeSounds cannot omit SelectedChime")
        end
      end

      private def validate_sounds!(sounds : Array(Sound)) : Nil
        unless (MIN_SOUNDS..MAX_SOUNDS).includes?(sounds.size)
          raise ArgumentError.new("InstalledChimeSounds requires 1 to 255 entries")
        end
        unless sounds.all? { |sound| (MIN_NAME_BYTES..MAX_NAME_BYTES).includes?(sound.name.bytesize) }
          raise ArgumentError.new("chime sound name must be 1 to 48 bytes")
        end
        ids = sounds.map(&.chime_id)
        names = sounds.map(&.name)
        raise ArgumentError.new("duplicate chime sound ID") unless ids.uniq.size == ids.size
        raise ArgumentError.new("duplicate chime sound name") unless names.uniq.size == names.size
      end

      private def validate_selected_chime!(id : UInt8) : Nil
        unless @installed_chime_sounds.any?(&.chime_id.==(id))
          raise Matter::ClusterError.new("chime sound not found", InteractionModel::StatusCode::NotFound)
        end
      end

      private def after_restore_state : Nil
        unless @installed_chime_sounds.any?(&.chime_id.==(@selected_chime))
          @selected_chime = @installed_chime_sounds.first.chime_id
        end
      end
    end
  end
end
