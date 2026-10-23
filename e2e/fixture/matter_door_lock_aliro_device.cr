require "../../examples/support/console"
require "../../examples/support/main"

# Test-only host reader for chip-tool coverage of the Matter management surface.
# It has no radio, so it refuses every local Aliro transaction. Production
# applications must supply a delegate that verifies real Aliro transactions.
module MatterDoorLockAliroFixture
  alias Lock = Matter::Cluster::DoorLock

  class Reader < Lock::AliroReaderDelegate
    def ready? : Bool
      true
    end

    def supported_protocol_versions : Array(Bytes)
      [Bytes[0x01, 0x00]]
    end

    def group_sub_identifier : Bytes
      Bytes.new(16, 0xA5_u8)
    end

    def configure(config : Lock::AliroReaderConfig) : Bool
      true
    end

    def clear_with_user_permission : Bool
      # This fixture simulates permission granted by its local test operator.
      true
    end

    def authenticate(transaction : Bytes, required_step_up_data_element : String) : Lock::AliroAuthenticatedAccess?
      nil
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Aliro Test Lock",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::DOOR_LOCK

    storage yaml: "matter_door_lock_aliro_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::DOOR_LOCK do
      cluster Lock,
        feature_map: Lock::Feature::User | Lock::Feature::AliroProvisioning,
        aliro_reader_delegate: Reader.new,
        number_of_aliro_credential_issuer_keys_supported: 2_u16,
        number_of_aliro_endpoint_keys_supported: 2_u16,
        as: :door_lock
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Aliro Test Lock")]
    end
  end
end

Examples.main("Matter Door Lock Aliro Fixture") { MatterDoorLockAliroFixture::Device.new }
