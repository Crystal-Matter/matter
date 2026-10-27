require "./support/console"
require "./support/main"
require "../src/matter/controller"

# Synthetic root-node Time Synchronization server for official chip-tool E2E.
# It has no time-zone database; commissioners supply standard and DST offsets.
module MatterTimeZone
  EXAMPLE_PRODUCT_ID = 0x1236_u16

  class Device < Matter::Device
    include Examples::Console

    @ntp_server : Matter::Cluster::TimeSynchronization::SntpServer?

    identity vendor: "Spider-Gazelle", product: "Synthetic Time Zone",
      vendor_id: Matter::Fabric::DEFAULT_VENDOR_ID,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_time_zone_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TimeSynchronization,
        feature_map: Matter::Cluster::TimeSynchronization::Feature::TimeZone |
                     Matter::Cluster::TimeSynchronization::Feature::NtpClient |
                     Matter::Cluster::TimeSynchronization::Feature::NtpServer |
                     Matter::Cluster::TimeSynchronization::Feature::TrustedTimeClient
    end

    def before_start : Nil
      if time_sync = node.get_cluster(Matter::Cluster::TimeSynchronization)
        client = Matter::Controller::TrustedTimeClient.new
        time_sync.on_trusted_time_query = ->(fabric_index : UInt8, node_id : UInt64, endpoint : UInt16) : Matter::Cluster::TimeSynchronization::TrustedTimeSample? do
          fabric = fabric_table.get_fabric(fabric_index)
          fabric ? client.query(fabric, node_id, endpoint) : nil
        end
      end
    end

    protected def on_started : Nil
      time_sync = node.get_cluster!(Matter::Cluster::TimeSynchronization)
      server = Matter::Cluster::TimeSynchronization::SntpServer.new(time_sync)
      server.start
      @ntp_server = server
      super
    end

    protected def on_shutdown : Nil
      @ntp_server.try(&.stop)
      super
    end

    def console_notes : Array(String)
      ["Synthetic Matter 1.6 TimeZone, NTPClient, NTPServer, and Trusted Time Client for E2E only"]
    end
  end
end

Examples.main("Synthetic Time Zone") { MatterTimeZone::Device.new }
