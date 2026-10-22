require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Keypad Input server (0x0509). Advertised features provide
    # their key sets; the host may add other CEC keys and decides whether a
    # press is valid in the current state.
    class KeypadInput < Base
      cluster 0x0509, revision: 1

      feature :navigation_key_codes, bit: 0
      feature :location_keys, bit: 1
      feature :number_keys, bit: 2

      enum CecKeyCode : UInt8
        Select                    = 0x00
        Up                        = 0x01
        Down                      = 0x02
        Left                      = 0x03
        Right                     = 0x04
        RightUp                   = 0x05
        RightDown                 = 0x06
        LeftUp                    = 0x07
        LeftDown                  = 0x08
        RootMenu                  = 0x09
        SetupMenu                 = 0x0A
        ContentsMenu              = 0x0B
        FavoriteMenu              = 0x0C
        Exit                      = 0x0D
        MediaTopMenu              = 0x10
        MediaContextSensitiveMenu = 0x11
        NumberEntryMode           = 0x1D
        Number11                  = 0x1E
        Number12                  = 0x1F
        Number0OrNumber10         = 0x20
        Numbers1                  = 0x21
        Numbers2                  = 0x22
        Numbers3                  = 0x23
        Numbers4                  = 0x24
        Numbers5                  = 0x25
        Numbers6                  = 0x26
        Numbers7                  = 0x27
        Numbers8                  = 0x28
        Numbers9                  = 0x29
        Dot                       = 0x2A
        Enter                     = 0x2B
        Clear                     = 0x2C
        NextFavorite              = 0x2F
        ChannelUp                 = 0x30
        ChannelDown               = 0x31
        PreviousChannel           = 0x32
        SoundSelect               = 0x33
        InputSelect               = 0x34
        DisplayInformation        = 0x35
        Help                      = 0x36
        PageUp                    = 0x37
        PageDown                  = 0x38
        Power                     = 0x40
        VolumeUp                  = 0x41
        VolumeDown                = 0x42
        Mute                      = 0x43
        Play                      = 0x44
        Stop                      = 0x45
        Pause                     = 0x46
        Record                    = 0x47
        Rewind                    = 0x48
        FastForward               = 0x49
        Eject                     = 0x4A
        Forward                   = 0x4B
        Backward                  = 0x4C
        StopRecord                = 0x4D
        PauseRecord               = 0x4E
        Reserved                  = 0x4F
        Angle                     = 0x50
        SubPicture                = 0x51
        VideoOnDemand             = 0x52
        ElectronicProgramGuide    = 0x53
        TimerProgramming          = 0x54
        InitialConfiguration      = 0x55
        SelectBroadcastType       = 0x56
        SelectSoundPresentation   = 0x57
        PlayFunction              = 0x60
        PausePlayFunction         = 0x61
        RecordFunction            = 0x62
        PauseRecordFunction       = 0x63
        StopFunction              = 0x64
        MuteFunction              = 0x65
        RestoreVolumeFunction     = 0x66
        TuneFunction              = 0x67
        SelectMediaFunction       = 0x68
        SelectAvInputFunction     = 0x69
        SelectAudioInputFunction  = 0x6A
        PowerToggleFunction       = 0x6B
        PowerOffFunction          = 0x6C
        PowerOnFunction           = 0x6D
        F1Blue                    = 0x71
        F2Red                     = 0x72
        F3Green                   = 0x73
        F4Yellow                  = 0x74
        F5                        = 0x75
        Data                      = 0x76
      end

      enum Status : UInt8
        Success                  = 0
        UnsupportedKey           = 1
        InvalidKeyInCurrentState = 2
      end

      NAVIGATION_KEYS = {
        CecKeyCode::Select, CecKeyCode::Up, CecKeyCode::Down,
        CecKeyCode::Left, CecKeyCode::Right, CecKeyCode::RootMenu,
        CecKeyCode::Exit,
      }
      LOCATION_KEYS = {CecKeyCode::RootMenu, CecKeyCode::SetupMenu}

      struct SendKeyRequest
        include TLV::Serializable

        # Keep the wire field numeric: an unknown CEC value must reach the
        # handler so it can receive UnsupportedKey in SendKeyResponse.
        @[TLV::Field(tag: 0)]
        getter key_code : UInt8

        def initialize(@key_code : UInt8)
        end
      end

      struct SendKeyResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : Status

        def initialize(@status : Status)
        end
      end

      command 0x00, :send_key, request: SendKeyRequest,
        response: SendKeyResponse, response_id: 0x01, access: :operate

      @on_send_key : Proc(CecKeyCode, Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     supported_keys : Array(CecKeyCode) = [] of CecKeyCode)
        raise ArgumentError.new("supported_keys contains duplicates") unless supported_keys.uniq.size == supported_keys.size
        raise ArgumentError.new("Reserved CEC code cannot be supported") if supported_keys.includes?(CecKeyCode::Reserved)
        if supported_keys.includes?(CecKeyCode::SetupMenu) && !@feature_map.location_keys?
          raise ArgumentError.new("Settings key requires LocationKeys")
        end
        if supported_keys.includes?(CecKeyCode::RootMenu) &&
           !@feature_map.location_keys? && !@feature_map.navigation_key_codes?
          raise ArgumentError.new("Home/Menu key requires LocationKeys or NavigationKeyCodes")
        end
        if supported_keys.any? { |key| (CecKeyCode::Number0OrNumber10.value..CecKeyCode::Numbers9.value).includes?(key.value) } &&
           !@feature_map.number_keys?
          raise ArgumentError.new("numeric keys require NumberKeys")
        end
        @supported_keys = supported_keys.to_set
        NAVIGATION_KEYS.each { |key| @supported_keys.add(key) } if @feature_map.navigation_key_codes?
        LOCATION_KEYS.each { |key| @supported_keys.add(key) } if @feature_map.location_keys?
        if @feature_map.number_keys?
          CecKeyCode.values.each do |key|
            @supported_keys.add(key) if (CecKeyCode::Number0OrNumber10.value..CecKeyCode::Numbers9.value).includes?(key.value)
          end
        end
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def on_send_key(&block : CecKeyCode -> Status) : Nil
        @on_send_key = block
      end

      def send_key(request : SendKeyRequest) : SendKeyResponse
        key = CecKeyCode.from_value?(request.key_code)
        return SendKeyResponse.new(Status::UnsupportedKey) unless key && @supported_keys.includes?(key)
        status = @on_send_key.try(&.call(key)) || Status::InvalidKeyInCurrentState
        SendKeyResponse.new(status)
      end
    end
  end
end
