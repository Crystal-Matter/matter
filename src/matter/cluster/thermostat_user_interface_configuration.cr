require "./cluster"

module Matter
  module Cluster
    # Local display and keypad preferences for a thermostat user interface.
    # Matter 1.6 Thermostat User Interface Configuration, revision 2 (0x0204).
    class ThermostatUserInterfaceConfiguration < Base
      cluster 0x0204, revision: 2

      enum TemperatureDisplayMode : UInt8
        Celsius    = 0
        Fahrenheit = 1
      end

      enum KeypadLockout : UInt8
        NoLockout = 0
        Lockout1  = 1
        Lockout2  = 2
        Lockout3  = 3
        Lockout4  = 4
        Lockout5  = 5
      end

      enum ScheduleProgrammingVisibility : UInt8
        ScheduleProgrammingPermitted = 0
        ScheduleProgrammingDenied    = 1
      end

      attribute 0x0000, :temperature_display_mode, TemperatureDisplayMode,
        default: TemperatureDisplayMode::Celsius, writable: true,
        write_access: :operate
      attribute 0x0001, :keypad_lockout, KeypadLockout,
        default: KeypadLockout::NoLockout, writable: true,
        write_access: :manage
      attribute 0x0002, :schedule_programming_visibility, ScheduleProgrammingVisibility,
        default: ScheduleProgrammingVisibility::ScheduleProgrammingPermitted,
        writable: true, write_access: :manage, optional: true
    end
  end
end
