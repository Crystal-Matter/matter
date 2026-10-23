require "../../examples/support/console"
require "../../examples/support/main"

# A test-only local RFID reader. Its trigger file stands in for a physical
# reader; deployed applications must replace it with a verifier that checks
# their actual reader transaction, freshness, and replay protection.
module MatterDoorLockVerifiedFixture
  alias Lock = Matter::Cluster::DoorLock

  class Reader < Lock::LocalCredentialVerifier
    @seen = Set(String).new

    def ready_for?(type : Lock::CredentialType) : Bool
      type.rfid?
    end

    def authenticate(type : Lock::CredentialType, transaction : Bytes) : Lock::LocalAuthenticatedCredential?
      return unless type.rfid?
      token = String.new(transaction)
      return unless token.starts_with?("verified:")
      return if @seen.includes?(token)

      @seen << token
      Lock::LocalAuthenticatedCredential.new(
        Lock::Credential.new(Lock::CredentialType::Rfid, 1_u16), "RFID1357".to_slice)
    end
  end

  class Device < Matter::Device
    include Examples::Console

    @hook_active = false

    identity vendor: "Spider-Gazelle", product: "Crystal Verified RFID Test Lock",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::DOOR_LOCK

    storage yaml: "matter_door_lock_verified_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::DOOR_LOCK do
      cluster Lock,
        feature_map: Lock::Feature::User | Lock::Feature::RfidCredential,
        local_credential_verifier: Reader.new,
        as: :door_lock
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Verified RFID Test Lock")]
    end

    protected def on_started : Nil
      super
      if path = ENV["MATTER_VERIFIED_RFID_HOOK_PATH"]?
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
          token = File.read(path).strip
          File.delete(path)
          status = door_lock.perform_local_credential_transaction(Lock::CredentialType::Rfid, token.to_slice)
          File.write("#{path}.ack", "#{token}:#{status.success?}")
        end
        sleep 100.milliseconds
      end
    end
  end
end

Examples.main("Matter Door Lock Verified RFID Fixture") { MatterDoorLockVerifiedFixture::Device.new }
