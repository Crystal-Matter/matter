require "./support/console"
require "./support/main"

# A dedicated interoperability fixture: 96 spec-conformant FixedLabel entries
# make one ReadResponse larger than the standard UDP Matter packet budget.
module MatterTcpLargePayload
  LABEL_COUNT = 96

  def self.labels : Array(Matter::Cluster::LabelStruct)
    Array.new(LABEL_COUNT) do |index|
      Matter::Cluster::LabelStruct.new(
        "tcp-#{index.to_s.rjust(3, '0')}",
        "TCP label #{index.to_s.rjust(6, '0')}")
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal TCP Large Payload",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ON_OFF_LIGHT,
      appearance: :satin

    storage yaml: "matter_tcp_large_payload_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT do
      cluster Matter::Cluster::OnOff, feature_map: :lighting
      cluster Matter::Cluster::Identify, identify_type: :visible_light
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::ScenesManagement
      cluster Matter::Cluster::FixedLabel, MatterTcpLargePayload.labels
    end

    def console_notes : Array(String)
      ["TCP enabled", "#{MatterTcpLargePayload::LABEL_COUNT} fixed labels"]
    end
  end
end

Examples.main("Matter TCP Large Payload Device") do
  MatterTcpLargePayload::Device.new(tcp_enabled: true)
end
