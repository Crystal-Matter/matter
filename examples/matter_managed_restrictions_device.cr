require "./support/console"
require "./support/main"

# Synthetic host consent fixture. Production hosts must make their own durable,
# token-correlated decision before changing an Access Restriction List.
module MatterManagedRestrictions
  alias AccessControl = Matter::Cluster::AccessControl
  alias WiFiManagement = Matter::Cluster::WiFiNetworkManagement

  TEST_SSID       = "Managed Wi-Fi"
  TEST_PASSPHRASE = "correct horse"
  TEST_SURROGATE  = 42_u64

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Managed Restriction Test",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x8131_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_managed_restrictions_storage.yml"
    managed_restrictions requested: :review_requested, updated: :review_updated

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster WiFiManagement
    end

    protected def before_start : Nil
      node.endpoint!(1_u16).get_cluster!(WiFiManagement)
        .update_credentials(TEST_SSID.to_slice, TEST_PASSPHRASE.to_slice, TEST_SURROGATE)
      super
    end

    private def review_requested(request : AccessControl::RestrictionReviewRequest) : Nil
      if path = ENV["MATTER_MNGD_REVIEW_PATH"]?
        File.write(path, request.token.to_s)
      end
      accepted = if request.entries.empty?
                   access_control.deny_restriction_review(request.fabric_index, request.token,
                     instruction: "Synthetic host denial")
                 else
                   access_control.approve_restriction_review(request.fabric_index, request.token,
                     request.entries, instruction: "Synthetic host approval")
                 end
      unless accepted
        raise Matter::ConfigurationError.new("Could not complete synthetic restriction review")
      end
      nil
    end

    private def review_updated(_fabric : UInt8, update : AccessControl::FabricRestrictionReviewUpdate) : Nil
      if path = ENV["MATTER_MNGD_UPDATE_PATH"]?
        File.write(path, update.token.to_s)
      end
    end
  end
end

Examples.main("Managed Restriction Test") { MatterManagedRestrictions::Device.new }
