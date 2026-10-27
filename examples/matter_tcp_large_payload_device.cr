require "./support/console"
require "./support/main"

# A dedicated interoperability fixture: 96 spec-conformant FixedLabel entries
# make one ReadResponse larger than the standard UDP Matter packet budget.
module MatterTcpLargePayload
  DEVICE_ENDPOINT_ID = 1_u16

  LABEL_COUNT = 96

  def self.update_labels : Array(Matter::Cluster::LabelStruct)
    Array.new(LABEL_COUNT) do |index|
      Matter::Cluster::LabelStruct.new(
        "upd-#{index.to_s.rjust(3, '0')}",
        "Update #{index.to_s.rjust(6, '0')}")
    end
  end

  def self.labels : Array(Matter::Cluster::LabelStruct)
    Array.new(LABEL_COUNT) do |index|
      Matter::Cluster::LabelStruct.new(
        "tcp-#{index.to_s.rjust(3, '0')}",
        "TCP label #{index.to_s.rjust(6, '0')}")
    end
  end

  class Device < Matter::Device
    include Examples::Console

    @hook_active = false

    identity vendor: "Spider-Gazelle", product: "Crystal TCP Large Payload",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ON_OFF_LIGHT,
      appearance: :satin

    storage yaml: "matter_tcp_large_payload_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::ON_OFF_LIGHT do
      cluster Matter::Cluster::OnOff, feature_map: :lighting
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::ScenesManagement
      cluster Matter::Cluster::FixedLabel, MatterTcpLargePayload.labels
      cluster Matter::Cluster::UserLabel
    end

    protected def on_started : Nil
      super
      if path = ENV["MATTER_SUBSCRIPTION_UPDATE_HOOK_PATH"]?
        @hook_active = true
        spawn { poll_update_hook(path) }
      end
    end

    protected def on_shutdown : Nil
      @hook_active = false
      super
    end

    private def poll_update_hook(path : String) : Nil
      while @hook_active
        if File.exists?(path)
          nonce = File.read(path).strip
          File.delete(path)
          node.get_cluster!(DEVICE_ENDPOINT_ID, Matter::Cluster::UserLabel).label_list = MatterTcpLargePayload.update_labels
          File.write("#{path}.ack", nonce)
        end
        sleep 100.milliseconds
      end
    end

    def console_notes : Array(String)
      ["TCP enabled", "#{MatterTcpLargePayload::LABEL_COUNT} fixed labels"]
    end
  end
end

Examples.main("Matter TCP Large Payload Device") do
  MatterTcpLargePayload::Device.new(tcp_enabled: true)
end
