require "./support/console"
require "./support/main"

# Synthetic signaling endpoint. A media host must own real sessions and SDP;
# this fixture deliberately declines signaling after the Matter checks pass.
module MatterWebrtcRequestor
  alias Requestor = Matter::Cluster::WebRtcTransportRequestor
  alias Status = Matter::InteractionModel::Status

  class DecliningPeer < Requestor::Peer
    def offer(session : Requestor::Session, request : Requestor::OfferRequest) : Status
      Status.invalid_in_state
    end

    def answer(session : Requestor::Session, request : Requestor::AnswerRequest) : Status
      Status.invalid_in_state
    end

    def ice_candidates(session : Requestor::Session, request : Requestor::IceCandidatesRequest) : Status
      Status.invalid_in_state
    end

    def end_session(session : Requestor::Session, request : Requestor::EndRequest) : Status
      Status.invalid_in_state
    end
  end

  class Device < Matter::Device
    include Examples::Console

    TEST_SESSION_ID = 7_u16

    identity vendor: "Spider-Gazelle", product: "Synthetic WebRTC Requestor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0554_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_webrtc_requestor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Requestor, DecliningPeer.new
    end

    protected def commissioned(fabric : Matter::Fabric) : Nil
      # The commissioning administrator is the chip-tool controller. Register
      # a host-owned test session bound to its CASE identity, without media.
      admin_entry = access_control.acl(fabric.fabric_index).find do |entry|
        entry.privilege == Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer &&
          entry.auth_mode == Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE
      end
      admin = admin_entry.try(&.subjects).try(&.first?)
      if admin
        node.get_cluster!(1_u16, Requestor).upsert_session(Requestor::Session.new(
          id: TEST_SESSION_ID, peer_node_id: admin, peer_endpoint_id: 1_u16,
          stream_usage: Requestor::StreamUsage::LiveView,
          metadata_enabled: false, fabric_index: fabric.fabric_index,
          video_streams: [1_u16]))
      end
      super
    end
  end
end

Examples.main("Synthetic WebRTC Requestor") { MatterWebrtcRequestor::Device.new }
