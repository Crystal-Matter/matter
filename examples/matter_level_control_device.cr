require "./support/console"
require "./support/main"

# Matter Level Control Device Example
#
# - Endpoint 1: Dimmable Light (OnOff + LevelControl)
# - Endpoint 2: Extended Color Light (OnOff + LevelControl + ColorControl)
# - Endpoint 3: Window Covering
module MatterLevelControl
  class Device < Matter::Device
    include Examples::Console

    # Only the dedicated DMTEST E2E service sets this. Production examples
    # retain the default disabled diagnostics test gate.
    protected def general_diagnostics_test_enable_key : Bytes?
      ENV["MATTER_DIAGNOSTICS_TEST_ENABLE_KEY"]?.try(&.hexbytes)
    end

    DIMMABLE_LIGHT_ENDPOINT  = 1
    COLOR_LIGHT_ENDPOINT     = 2
    WINDOW_COVERING_ENDPOINT = 3

    MIN_LEVEL            =   1_u8
    MAX_LEVEL            = 254_u8
    INITIAL_LEVEL        = 128_u8
    COVERING_TRAVEL_TIME = 3.seconds

    @covering_motion_generation = 0_u32

    # Percentages a level is reported as.
    FULL_PERCENT = 100

    SCENE_MODE_ECO   = 1_u8
    SCENE_MODE_BOOST = 2_u8
    SCENE_MODES      = [
      Matter::Cluster::ModeSelect::ModeOption.new("Eco", SCENE_MODE_ECO),
      Matter::Cluster::ModeSelect::ModeOption.new("Boost", SCENE_MODE_BOOST),
    ]

    identity vendor: "Spider-Gazelle", product: "Crystal Level Control",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::DIMMABLE_LIGHT,
      appearance: :satin

    storage yaml: "matter_level_control_storage.yml"

    endpoint DIMMABLE_LIGHT_ENDPOINT, device_type: Matter::DeviceType::DIMMABLE_LIGHT do
      cluster Matter::Cluster::OnOff, feature_map: :lighting, as: :on_off
      cluster Matter::Cluster::LevelControl,
        current_level: INITIAL_LEVEL,
        min_level: MIN_LEVEL,
        max_level: MAX_LEVEL,
        feature_map: Matter::Cluster::LevelControl::Feature::OnOff | Matter::Cluster::LevelControl::Feature::Lighting,
        as: :level_control
      # FixedLabel is optional, but can help controllers show a friendly name for this endpoint.
      cluster Matter::Cluster::FixedLabel, [
        Matter::Cluster::LabelStruct.new("name", "Example Level"),
        Matter::Cluster::LabelStruct.new("name", "Example Mute"),
      ]
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::ScenesManagement
      cluster Matter::Cluster::ModeSelect,
        description: "Lighting scene mode",
        supported_modes: SCENE_MODES,
        current_mode: SCENE_MODE_ECO
    end

    endpoint COLOR_LIGHT_ENDPOINT, device_type: Matter::DeviceType::EXTENDED_COLOR_LIGHT do
      cluster Matter::Cluster::OnOff, feature_map: :lighting
      cluster Matter::Cluster::LevelControl
      cluster Matter::Cluster::ColorControl,
        color_mode: Matter::Cluster::ColorControl::ColorMode::ColorTemperatureMireds,
        couple_color_temp_to_level_min_mireds: 200_u16
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::ScenesManagement
      cluster Matter::Cluster::Identify, identify_type: :visible_light
    end

    endpoint WINDOW_COVERING_ENDPOINT, device_type: Matter::DeviceType::WINDOW_COVERING do
      cluster Matter::Cluster::WindowCovering, as: :window_covering
      cluster Matter::Cluster::Identify
    end

    protected def before_start : Nil
      covering = window_covering
      covering.current_position_lift_percent100ths ||= 0_u16
      covering.on_move do |request|
        if target = request.lift_target
          @covering_motion_generation &+= 1_u32
          generation = @covering_motion_generation
          spawn do
            sleep COVERING_TRAVEL_TIME
            covering.current_position_lift_percent100ths = target if generation == @covering_motion_generation
          end
        end
        Matter::InteractionModel::Status.success
      end
      covering.on_stop do
        @covering_motion_generation &+= 1_u32
        Matter::InteractionModel::Status.success
      end
      super
    end

    on(:on_off, :state_changed) do |state|
      notify "Light state: #{state ? "ON" : "OFF"}",
        "Level: #{level_summary}",
        "Data version: #{on_off.data_version}"
    end

    on(:level_control, :level_changed) do |old_level, new_level|
      notify "Level changed: #{old_level} -> #{new_level} (#{level_percent(new_level)}%)",
        "Data version: #{level_control.data_version}"
    end

    def console_notes : Array(String)
      [
        "Endpoint #{DIMMABLE_LIGHT_ENDPOINT}: Dimmable Light",
        "Endpoint #{COLOR_LIGHT_ENDPOINT}: Extended Color Light",
        "Endpoint #{WINDOW_COVERING_ENDPOINT}: Window Covering",
      ]
    end

    def state_details : Nil
      puts "  Light: #{on_off.on_off? ? "ON" : "OFF"}"
      puts "  Level: #{level_summary}"
      puts "  Data Version: #{level_control.data_version}"
    end

    def status_details : Nil
      puts "  Light State: #{on_off.on_off? ? "ON" : "OFF"}"
      puts "  Level: #{level_summary}"
      puts "  Data Version: #{level_control.data_version}"
    end

    def commands : Array(Tuple(String, String))
      [
        {"toggle", "Toggle the light between on and off"},
        {"on", "Turn the light on"},
        {"off", "Turn the light off"},
        {"level <0-100>", "Set the brightness level %"},
      ]
    end

    def handle_command(name : String, argument : String?) : Bool
      case name
      when "toggle"              then on_off.toggle
      when "on"                  then on_off.on = true
      when "off"                 then on_off.on = false
      when "level", "brightness" then set_level(argument)
      else                            return false
      end
      true
    end

    private def set_level(argument : String?) : Nil
      value = argument.try(&.to_f?)
      unless value
        puts "Usage: level <0-#{FULL_PERCENT}>"
        return
      end

      # the cluster performs clamping and value checks
      level_control.level = value
    end

    private def level_summary : String
      level = level_control.current_level
      level ? "#{level} (#{level_percent(level)}%)" : "unknown"
    end

    private def level_percent(level : UInt8) : Int32
      (level.to_i * FULL_PERCENT) // MAX_LEVEL
    end
  end
end

Examples.main("Matter Level Control Device") { MatterLevelControl::Device.new }
