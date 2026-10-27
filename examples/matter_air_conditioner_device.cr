require "./support/console"
require "./support/main"

# Matter Air Conditioner Device Example
#
# Two-endpoint architecture for Matter spec compliance:
# - Endpoint 1: Thermostat (0x301) - temperature control
# - Endpoint 2: Fan (0x002B) - fan control with OnOff
#
# This architecture is spec-correct because:
# - Thermostat device type has FanControl as a CLIENT cluster (talks TO a fan)
# - Fan device type has FanControl as a SERVER cluster (IS the controller)
#
# Fan speed maps 0-100% to 5 discrete steps: Quiet, Low, Medium, High, Max.
# Ambient temperature is simulated every 10 seconds and fed to the thermostat.
#
# chip-tool commands for testing:
#   chip-tool thermostat read local-temperature 1 1
#   chip-tool fancontrol read fan-mode 1 2
#   chip-tool onoff on 1 2
module MatterAirConditioner
  class Device < Matter::Device
    include Examples::Console

    THERMOSTAT_ENDPOINT = 1
    FAN_ENDPOINT        = 2

    SAMPLE_INTERVAL = 10.seconds

    # Hundredths of a degree Celsius, as the clusters report them.
    MIN_TEMPERATURE  = 1500_i16
    MAX_TEMPERATURE  = 3500_i16
    TOLERANCE        =   50_u16
    COOLING_SETPOINT = 2400_i16 # 24 C
    HEATING_SETPOINT = 2000_i16 # 20 C

    # Fan percentages, by name and by the step the fan snaps to.
    FAN_SPEED_NAMES = {0_u8 => "Off", 1_u8 => "Quiet", 2_u8 => "Low", 3_u8 => "Medium", 4_u8 => "High", 5_u8 => "Max"}
    FAN_PERCENTS    = {"off" => 0_u8, "quiet" => 20_u8, "low" => 40_u8, "med" => 60_u8, "medium" => 60_u8, "high" => 80_u8, "max" => 100_u8}

    FAN_SPEED_MAX   =   5_u8
    FAN_STEP        =  20_u8
    FAN_PERCENT_MAX = 100_u8

    # The speed the fan takes when a mode turns it on while it is off.
    FAN_ONLY_PERCENT            = 60_u8
    HEATING_COOLING_FAN_PERCENT = 40_u8

    identity vendor: "Spider-Gazelle", product: "Crystal Air Conditioner",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT,
      appearance: :satin

    storage yaml: "matter_air_conditioner_storage.yml"

    endpoint THERMOSTAT_ENDPOINT, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Thermostat,
        feature_map: Matter::Cluster::Thermostat::Feature::Cooling | Matter::Cluster::Thermostat::Feature::Heating,
        occupied_cooling_setpoint: COOLING_SETPOINT,
        occupied_heating_setpoint: HEATING_SETPOINT,
        system_mode: :off,
        as: :thermostat
      cluster Matter::Cluster::TemperatureMeasurement,
        measured_value: rand(MIN_TEMPERATURE..MAX_TEMPERATURE),
        min_measured_value: MIN_TEMPERATURE,
        max_measured_value: MAX_TEMPERATURE,
        tolerance: TOLERANCE,
        as: :temperature
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example AirCon")]
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::ScenesManagement
    end

    endpoint FAN_ENDPOINT, device_type: Matter::DeviceType::FAN do
      cluster Matter::Cluster::FanControl,
        feature_map: Matter::Cluster::FanControl::Feature::Step | Matter::Cluster::FanControl::Feature::MultiSpeed,
        fan_mode: :off,
        fan_mode_sequence: :off_low_med_high,
        speed_max: FAN_SPEED_MAX,
        step_percent: FAN_STEP,
        as: :fan_control
      cluster Matter::Cluster::OnOff, on_off: false, as: :fan_on_off
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::Groups
    end

    # The thermostat drives the fan on endpoint 2: every callback is wired
    # once both endpoints exist, so this may reach across them.
    on(:thermostat, :system_mode_changed) do |old_mode, new_mode|
      puts ""
      puts "Mode changed: #{old_mode} -> #{new_mode}"
      case new_mode
      when Matter::Cluster::Thermostat::SystemMode::Off
        fan_on_off.on_off = false
      when Matter::Cluster::Thermostat::SystemMode::FanOnly
        start_fan(FAN_ONLY_PERCENT)
      else
        start_fan(HEATING_COOLING_FAN_PERCENT)
      end
      print_state_lines
      reprompt
    end

    on(:thermostat, :setpoint_changed) do |type, old_value, new_value|
      notify "#{type} setpoint changed: #{format_temperature(old_value)} -> #{format_temperature(new_value)}"
    end

    on(:temperature, :temperature_changed) do |_old_value, new_value|
      thermostat.update_local_temperature(new_value)
      notify "Ambient temperature: #{format_temperature(new_value)}" if new_value
    end

    on(:fan_control, :percent_changed) do |_old_percent, new_percent|
      notify "Fan: #{fan_speed_name} (#{new_percent}%)"
    end

    on(:fan_on_off, :state_changed) do |is_on|
      # When the fan is turned off via OnOff, also set its fan mode to Off.
      unless is_on || fan_control.fan_mode.off?
        fan_control.write_attribute(
          Matter::Cluster::FanControl::ATTR_FAN_MODE,
          TLV::Any.new(Matter::Cluster::FanControl::FanMode::Off.value)
        )
      end
      notify "Fan power: #{is_on ? "ON" : "OFF"}"
    end

    def console_notes : Array(String)
      [
        "Endpoint #{THERMOSTAT_ENDPOINT}: Thermostat (0x301) - Temperature Control",
        "Endpoint #{FAN_ENDPOINT}: Fan (0x002B) - Fan Control with OnOff",
      ]
    end

    def state_details : Nil
      print_state_lines
    end

    def status_details : Nil
      print_state_lines
      puts "  Running Mode: #{thermostat.thermostat_running_mode}"
    end

    def commands : Array(Tuple(String, String))
      [
        {"mode <off|cool|heat|fan|dry>", "Set the operating mode (endpoint #{THERMOSTAT_ENDPOINT})"},
        {"cool <temp>", "Set the cooling setpoint in C"},
        {"heat <temp>", "Set the heating setpoint in C"},
        {"power <on|off>", "Set the fan power (endpoint #{FAN_ENDPOINT})"},
        {"fan <off|quiet|low|med|high|max|0-100>", "Set the fan speed"},
      ]
    end

    def handle_command(name : String, argument : String?) : Bool
      case name
      when "mode"  then set_mode(argument)
      when "cool"  then set_setpoint(argument) { |value| thermostat.cooling_setpoint = value }
      when "heat"  then set_setpoint(argument) { |value| thermostat.heating_setpoint = value }
      when "power" then set_fan_power(argument)
      when "fan"   then set_fan(argument)
      else              return false
      end
      true
    end

    protected def before_start : Nil
      # Feed the simulated ambient temperature into the thermostat.
      if measured = temperature.measured_value
        thermostat.update_local_temperature(measured)
      end
      super
    end

    protected def on_started : Nil
      super
      every(SAMPLE_INTERVAL) { temperature.update_temperature(rand(MIN_TEMPERATURE..MAX_TEMPERATURE)) }
    end

    # Turns the fan on, taking it to *percent* when it was not running.
    private def start_fan(percent : UInt8) : Nil
      fan_on_off.on_off = true
      set_fan_percent(percent) if fan_control.fan_mode.off?
    end

    private def set_fan_percent(percent : UInt8) : Nil
      fan_control.write_attribute(Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, TLV::Any.new(percent))
    end

    private def set_mode(argument : String?) : Nil
      mode = case argument.try(&.downcase)
             when "off"  then Matter::Cluster::Thermostat::SystemMode::Off
             when "cool" then Matter::Cluster::Thermostat::SystemMode::Cool
             when "heat" then Matter::Cluster::Thermostat::SystemMode::Heat
             when "fan"  then Matter::Cluster::Thermostat::SystemMode::FanOnly
             when "dry"  then Matter::Cluster::Thermostat::SystemMode::Dry
             end

      unless mode
        puts "Usage: mode <off|cool|heat|fan|dry>"
        return
      end

      thermostat.mode = mode
    end

    private def set_setpoint(argument : String?, & : Int16 -> Nil) : Nil
      celsius = argument.try(&.to_f?)
      unless celsius
        puts "Usage: cool|heat <temperature in C>"
        return
      end

      yield Matter::Cluster::TemperatureMeasurement.from_celsius(celsius)
    end

    private def set_fan_power(argument : String?) : Nil
      case argument.try(&.downcase)
      when "on"  then fan_on_off.on_off = true
      when "off" then fan_on_off.on_off = false
      else            puts "Usage: power <on|off>"
      end
    end

    private def set_fan(argument : String?) : Nil
      name = argument.try(&.downcase)
      percent = name.try { |value| FAN_PERCENTS[value]? || value.to_u8? }

      unless percent && percent <= FAN_PERCENT_MAX
        puts "Usage: fan <#{FAN_PERCENTS.keys.join("|")}|0-#{FAN_PERCENT_MAX}>"
        return
      end

      fan_on_off.on_off = true if percent > 0
      set_fan_percent(percent)
    end

    private def print_state_lines : Nil
      puts "  Mode: #{thermostat.system_mode}"
      puts "  Ambient: #{format_temperature(temperature.measured_value)}"
      puts "  Cool Setpoint: #{format_temperature(thermostat.occupied_cooling_setpoint)}"
      puts "  Heat Setpoint: #{format_temperature(thermostat.occupied_heating_setpoint)}"
      puts "  Fan Power: #{fan_on_off.on_off? ? "ON" : "OFF"}"
      puts "  Fan Speed: #{fan_speed_name} (#{fan_control.percent_current}%)"
    end

    private def fan_speed_name : String
      speed = fan_control.speed_current
      FAN_SPEED_NAMES[speed]? || "Speed #{speed}"
    end

    private def format_temperature(centi_celsius : Int16?) : String
      return "unknown" unless centi_celsius
      "#{"%.1f" % Matter::Cluster::TemperatureMeasurement.to_celsius(centi_celsius)} C"
    end
  end
end

Examples.main("Matter Air Conditioner Device") { MatterAirConditioner::Device.new }
