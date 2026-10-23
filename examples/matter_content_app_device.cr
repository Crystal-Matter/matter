require "./support/console"
require "./support/main"

module MatterContentApp
  alias ApplicationBasic = Matter::Cluster::ApplicationBasic
  alias Messages = Matter::Cluster::Messages
  alias AccountLogin = Matter::Cluster::AccountLogin

  class AccountHost < AccountLogin::Host
    TEMP_ACCOUNT_IDENTIFIER = "crystal-radio-user"
    SETUP_PIN               = "12345678"
    IDENTIFIER_LIFETIME     = 10.minutes

    @issued_at : Time? = nil

    def setup_pin(identifier : String, fabric_index : UInt8) : String?
      return unless identifier == TEMP_ACCOUNT_IDENTIFIER
      issued_at = @issued_at
      return if issued_at && Time.utc - issued_at >= IDENTIFIER_LIFETIME
      @issued_at ||= Time.utc
      SETUP_PIN
    end

    def login(identifier : String, pin : String, node : UInt64?, fabric_index : UInt8) : Bool
      issued_at = @issued_at
      return false unless issued_at
      identifier == TEMP_ACCOUNT_IDENTIFIER && pin == SETUP_PIN &&
        Time.utc - issued_at < IDENTIFIER_LIFETIME
    end

    def logout(node : UInt64?, fabric_index : UInt8) : Bool
      true
    end
  end

  class Device < Matter::Device
    include Examples::Console

    CATALOG_VENDOR_ID = 0xFFF1_u16
    APPLICATION_ID    = "crystal.radio"

    identity vendor: "Spider-Gazelle", product: "Crystal Radio Content App",
      vendor_id: CATALOG_VENDOR_ID,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_content_app_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::CONTENT_APP do
      cluster AccountLogin, host: AccountHost.new, as: :account_login
      cluster ApplicationBasic,
        application_name: "Crystal Radio",
        application: ApplicationBasic::Application.new(CATALOG_VENDOR_ID, APPLICATION_ID),
        application_version: "1.0.0",
        allowed_vendor_list: [CATALOG_VENDOR_ID],
        vendor_name: "Spider-Gazelle",
        vendor_id: CATALOG_VENDOR_ID,
        as: :application_basic

      cluster Messages, as: :messages
    end

    protected def before_start : Nil
      application_basic.update_status(ApplicationBasic::ApplicationStatus::ActiveVisibleFocus)
      super
    end

    def console_notes : Array(String)
      ["Device Type: Content App", "Application ID: #{APPLICATION_ID}"]
    end
  end
end

Examples.main("Crystal Radio Content App") { MatterContentApp::Device.new }
