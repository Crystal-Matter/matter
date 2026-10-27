require "./support/console"
require "./support/main"

module MatterContentApp
  alias ApplicationBasic = Matter::Cluster::ApplicationBasic
  alias Messages = Matter::Cluster::Messages
  alias AccountLogin = Matter::Cluster::AccountLogin

  MESSAGE_PROFILE  = ENV["MATTER_MESSAGES_PROFILE"]? == "1"
  MESSAGE_FEATURES = Messages::Feature::ReceivedConfirmation |
                     Messages::Feature::ConfirmationResponse |
                     Messages::Feature::ConfirmationReply
  AUTO_CONFIRM_RESPONSE_ID = 2_u32

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

  # The opt-in E2E profile demonstrates how an application presents and
  # confirms messages. A real UI can make these calls after user interaction.
  class MessageHost < Messages::Host
    AUTO_CONFIRM_TEXT = "Confirm in demo UI"
    Log               = ::Log.for("matter.example.content_app.messages")

    def message_queued(message : Messages::Message, origin_node_id : UInt64?, cluster : Messages) : Nil
      if start = message.start_time
        available_at = Time.unix(start.to_i64 + Messages::MATTER_EPOCH_UNIX_SECONDS)
        if available_at > Time.utc
          spawn do
            remaining = available_at - Time.utc
            sleep remaining if remaining > 0.seconds
            present_message(message, cluster)
          end
          return
        end
      end
      present_message(message, cluster)
    end

    private def present_message(message : Messages::Message, cluster : Messages) : Nil
      cluster.present(message.message_id, message.fabric_index)
      return unless message.text == AUTO_CONFIRM_TEXT
      cluster.complete(message.message_id, message.fabric_index, AUTO_CONFIRM_RESPONSE_ID, "Seen")
    rescue ex : ArgumentError
      Log.debug(exception: ex) { "Message #{message.message_id.hexstring} was cancelled, expired, or not ready" }
    end

    def message_cancelled(message_id : Bytes, fabric_index : UInt8) : Nil
    end
  end

  class Device < Matter::Device
    include Examples::Console

    CATALOG_VENDOR_ID = 0xFFF1_u16
    APPLICATION_ID    = "crystal.radio"

    identity vendor: "Spider-Gazelle", product: "Crystal Radio Content App",
      vendor_id: CATALOG_VENDOR_ID,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
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

      cluster Messages,
        feature_map: MESSAGE_PROFILE ? MESSAGE_FEATURES : Messages::Feature::None,
        host: MESSAGE_PROFILE ? MessageHost.new : nil,
        as: :messages
    end

    protected def before_start : Nil
      application_basic.update_status(ApplicationBasic::ApplicationStatus::ActiveVisibleFocus)
      messages.replay_messages_to_host! if MESSAGE_PROFILE
      super
    end

    def console_notes : Array(String)
      ["Device Type: Content App", "Application ID: #{APPLICATION_ID}"]
    end
  end
end

Examples.main("Crystal Radio Content App") { MatterContentApp::Device.new }
