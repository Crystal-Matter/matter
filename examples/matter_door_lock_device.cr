require "./support/console"
require "./support/main"

# Matter Door Lock Device Example
#
# - Presents as a Door Lock (endpoint 1)
# - Exposes Identify + DoorLock clusters
# - Supports lock/unlock/unbolt + door open/close simulation
module MatterDoorLock
  # This example has no physical lock. A real device must complete each
  # movement before reporting success to DoorLock.
  class SimulatedUnboltingActuator < Matter::Cluster::DoorLock::UnboltingActuator
    def unbolt : Bool
      true
    end

    def pull_latch : Bool
      true
    end

    def release_latch : Bool
      true
    end
  end

  class Device < Matter::Device
    include Examples::Console

    # How often the simulated door swings.
    DOOR_INTERVAL = 10.seconds

    AUTO_RELOCK_TIME = 15_u32
    DEFAULT_PIN_CODE = "2468"

    identity vendor: "Spider-Gazelle", product: "Crystal Door Lock",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::DOOR_LOCK

    storage yaml: "matter_door_lock_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::DOOR_LOCK do
      cluster Matter::Cluster::DoorLock,
        feature_map: Matter::Cluster::DoorLock::Feature::DoorPositionSensor |
                     Matter::Cluster::DoorLock::Feature::PinCredential |
                     Matter::Cluster::DoorLock::Feature::CredentialOverTheAirAccess |
                     Matter::Cluster::DoorLock::Feature::User |
                     Matter::Cluster::DoorLock::Feature::Unbolting |
                     Matter::Cluster::DoorLock::Feature::WeekDayAccessSchedules |
                     Matter::Cluster::DoorLock::Feature::YearDayAccessSchedules |
                     Matter::Cluster::DoorLock::Feature::HolidaySchedules,
        auto_relock_time: AUTO_RELOCK_TIME,
        unbolting_actuator: SimulatedUnboltingActuator.new,
        require_pin_for_remote_operation: true,
        default_pin_code: DEFAULT_PIN_CODE,
        as: :door_lock
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example DoorLock")]
    end

    on(:door_lock, :lock_state_changed) do |_old_state, new_state|
      notify "Lock state changed: #{new_state || "null"} (data version: #{door_lock.data_version})"
    end

    on(:door_lock, :door_state_changed) do |_old_state, new_state|
      notify "Door state changed: #{new_state || "null"}"
    end

    def console_notes : Array(String)
      ["Device Type: Door Lock"]
    end

    def state_details : Nil
      puts "  Default remote PIN: #{door_lock.default_pin_code}"
      puts "  Auto relock: #{door_lock.auto_relock_time}s"
      puts "  Lock state: #{door_lock.lock_state || "null"}"
      puts "  Door state: #{door_lock.door_state || "null"}"
    end

    def status_details : Nil
      puts "  lockState: #{door_lock.lock_state || "null"}"
      puts "  doorState: #{door_lock.door_state || "null"}"
      puts "  doorOpenEvents: #{door_lock.door_open_events}"
      puts "  doorClosedEvents: #{door_lock.door_closed_events}"
      puts "  autoRelockTime: #{door_lock.auto_relock_time}s"
      puts "  dataVersion: #{door_lock.data_version}"
    end

    def commands : Array(Tuple(String, String))
      [
        {"lock [pin]", "Lock the door"},
        {"unlock [pin]", "Unlock the door"},
        {"unbolt [pin]", "Unbolt the door"},
        {"open", "Mark the door open"},
        {"close", "Mark the door closed"},
      ]
    end

    def handle_command(name : String, argument : String?) : Bool
      case name
      when "lock"   then report(door_lock.lock(pin: argument))
      when "unlock" then report(door_lock.unlock(pin: argument))
      when "unbolt" then report(door_lock.unbolt(pin: argument))
      when "open"   then door_lock.update_door_state(Matter::Cluster::DoorLock::DoorState::DoorOpen)
      when "close"  then door_lock.update_door_state(Matter::Cluster::DoorLock::DoorState::DoorClosed)
      else               return false
      end
      true
    end

    protected def on_started : Nil
      super

      opened = false
      every(DOOR_INTERVAL) do
        opened = !opened
        door_lock.update_door_state(
          opened ? Matter::Cluster::DoorLock::DoorState::DoorOpen : Matter::Cluster::DoorLock::DoorState::DoorClosed
        )
      end
    end

    private def report(status : Matter::InteractionModel::Status) : Nil
      puts status.success? ? "Command succeeded" : "Command failed: #{status}"
    end
  end
end

Examples.main("Matter Door Lock Device") { MatterDoorLock::Device.new }
