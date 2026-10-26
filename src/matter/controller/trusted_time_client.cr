require "log"
require "../cluster/time_synchronization"
require "../fabric"
require "./client"
require "./im_client"
require "./operational_peer_resolver"
require "./pairing/case_pairing"
require "./state"

module Matter
  module Controller
    # Reads a configured Time Synchronization server over an authenticated
    # operational CASE session. The fabric's own NOC is used as the client
    # identity; CASE verifies the selected peer Node ID and fabric.
    class TrustedTimeClient
      Log             = ::Log.for("matter.controller.trusted_time_client")
      DEFAULT_TIMEOUT = 10.seconds

      def initialize(@resolver : OperationalPeerResolver = OperationalPeerResolver.new,
                     @timeout : Time::Span = DEFAULT_TIMEOUT)
      end

      def query(fabric : Fabric, node_id : UInt64, endpoint : UInt16) : Cluster::TimeSynchronization::TrustedTimeSample?
        root_cert = fabric.root_cert || raise Matter::ConfigurationError.new("Trusted time client fabric has no root certificate")
        identity = FabricInfo.new(fabric_id: fabric.fabric_id, controller_node_id: fabric.node_id,
          ipk_value: fabric.ipk, root_cert: root_cert,
          root_public_key: fabric.root_public_key,
          controller_noc: fabric.operational_cert,
          controller_private_key: fabric.operational_private_key,
          admin_vendor_id: fabric.vendor_id,
          intermediate_cert: fabric.intermediate_cert,
          ipk_epoch_keys: fabric.ipk_epoch_keys)
        state = State.new(fabric: identity)
        peer = @resolver.resolve(state, identity, node_id, @timeout)
        client = Client.new(unsecured_source_node_id: fabric.node_id)
        begin
          session = Pairing::CasePairing.new.pair(client, peer, identity,
            peer_node_id: node_id, timeout: @timeout)
          im = ImClient.new(client, @timeout)
          utc = read_number(im, session, peer, endpoint, Cluster::TimeSynchronization::ATTR_UTC_TIME)
          granularity = read_number(im, session, peer, endpoint, Cluster::TimeSynchronization::ATTR_GRANULARITY)
          return unless utc && granularity && granularity <= UInt8::MAX
          precision = Cluster::TimeSynchronization::Granularity.from_value?(granularity.to_u8)
          return unless precision && precision != Cluster::TimeSynchronization::Granularity::NoTime
          Cluster::TimeSynchronization::TrustedTimeSample.new(utc, precision)
        ensure
          client.close
        end
      rescue error : Matter::Error | Socket::Error
        Log.warn(exception: error) { "Trusted time peer 0x#{node_id.to_s(16)} could not be read" }
        nil
      end

      private def read_number(im : ImClient, session : Session::SecureContext,
                              peer : Socket::IPAddress, endpoint : UInt16,
                              attribute : UInt32) : UInt64?
        report = im.read_attribute(session, peer, endpoint,
          Cluster::TimeSynchronization::CLUSTER_ID, attribute)
        report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data).try(&.as_u64?)
      end
    end
  end
end
