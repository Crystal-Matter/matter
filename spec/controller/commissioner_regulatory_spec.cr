require "../spec_helper"
require "../../src/matter/controller"

private alias GC = Matter::Cluster::GeneralCommissioning
private alias NC = Matter::Cluster::NetworkCommissioning
private alias IM = Matter::InteractionModel

private class RegulatoryImClient < Matter::Controller::ImClient
  getter calls = [] of Tuple(UInt32, UInt32, Bytes)
  property maps = [] of Tuple(UInt16, UInt32)
  property breadcrumb = 11_u64
  property arm_error = Matter::Commissioning::ErrorCode::OK
  property regulatory_error = Matter::Commissioning::ErrorCode::OK
  property arm_response_delay = 0.seconds
  getter arm_invoked_at_unix : Int64?

  def initialize
    super(Matter::Controller::Client.new)
  end

  def close : Nil
    @client.close
  end

  def read(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
           attribute_paths : Array(IM::AttributePath) = [] of IM::AttributePath,
           event_paths : Array(IM::EventPath) = [] of IM::EventPath,
           event_filters : Array(IM::EventFilterIB)? = nil,
           fabric_filtered : Bool = true,
           data_version_filters : Array(IM::DataVersionFilterIB)? = nil) : IM::ReportDataMessage
    attribute_paths.size.should eq(1)
    path = attribute_paths.first
    path.endpoint.should be_nil
    path.cluster.should eq(NC::CLUSTER_ID)
    path.attribute.should eq(Matter::Cluster::Base::GLOBAL_FEATURE_MAP)
    reports = @maps.map do |endpoint, map|
      concrete = IM::AttributePath.new(endpoint: endpoint, cluster: NC::CLUSTER_ID,
        attribute: Matter::Cluster::Base::GLOBAL_FEATURE_MAP)
      IM::AttributeReportIB.new(attribute_data: IM::AttributeDataIB.new(concrete, TLV::Any.new(map)))
    end
    IM::ReportDataMessage.new(attribute_reports: reports)
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty) : IM::InvokeResponseMessage
    @calls << {cluster_id, command_id, fields}
    if command_id == GC::CMD_ARM_FAIL_SAFE
      @arm_invoked_at_unix = Time.utc.to_unix
      sleep @arm_response_delay
    end
    response_id = command_id == GC::CMD_ARM_FAIL_SAFE ? GC::CMD_ARM_FAIL_SAFE_RESPONSE : GC::CMD_SET_REGULATORY_CONFIG_RESPONSE
    response = if command_id == GC::CMD_ARM_FAIL_SAFE
                 GC::ArmFailSafeResponse.new(@arm_error).to_slice
               else
                 GC::SetRegulatoryConfigResponse.new(@regulatory_error).to_slice
               end
    path = IM::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id, command: response_id)
    data = IM::CommandDataIBTlv.new(path, TLV::Any.from_slice(response))
    IM::InvokeResponseMessage.new(invoke_responses: [IM::InvokeResponseIB.new(command_data: data)])
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true,
                     data_version : UInt32? = nil) : IM::ReportDataMessage
    path = IM::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = IM::AttributeDataIB.new(path, TLV::Any.new(@breadcrumb))
    IM::ReportDataMessage.new(attribute_reports: [IM::AttributeReportIB.new(attribute_data: data)])
  end
end

private class RegulatoryCommissioner < Matter::Controller::Commissioning::Commissioner
  def configure(im : Matter::Controller::ImClient, session : Matter::Session::SecureContext,
                peer : Socket::IPAddress) : Nil
    configure_regulatory_information(im, session, peer)
  end

  def refresh(im : Matter::Controller::ImClient, session : Matter::Session::SecureContext,
              peer : Socket::IPAddress, window : FailSafeWindow) : FailSafeWindow
    rearm_fail_safe_if_needed(im, session, peer, window)
  end

  def checkpoint(fabric : Matter::Controller::FabricInfo, node_id : UInt64, peer : Socket::IPAddress,
                 im : Matter::Controller::ImClient, session : Matter::Session::SecureContext,
                 window : FailSafeWindow, defer_completion : Bool) : Tuple(FailSafeWindow, Matter::Controller::PendingCommissioningHandoff?)
    record_pending_commissioning(fabric, node_id, "Test node", peer, im, session, window, defer_completion)
  end
end

private class RegulatoryNodeDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64, friendly_name : String) : Nil
  end
end

private def regulatory_fabric : Matter::Controller::FabricInfo
  Matter::Controller::FabricInfo.new(
    fabric_id: 0x123_u64, controller_node_id: 0x100_u64,
    ipk_value: Bytes.new(16), root_cert: Bytes[1], root_public_key: Bytes[2],
    controller_noc: Bytes[3], controller_private_key: Bytes[4])
end

private def regulatory_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
end

describe Matter::Controller::Commissioning::Commissioner do
  it "configures regulatory information when any endpoint has Wi-Fi or Thread" do
    im = RegulatoryImClient.new
    im.maps = [{0_u16, NC::Feature::EthernetNetworkInterface.value},
               {1_u16, NC::Feature::WiFiNetworkInterface.value}]
    commissioner = RegulatoryCommissioner.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new),
      regulatory_location: GC::RegulatoryLocationType::Indoor,
      regulatory_country_code: "AU")
    commissioner.configure(im, regulatory_session, Socket::IPAddress.new("127.0.0.1", 5540))
    im.calls.map(&.[1]).should eq([GC::CMD_SET_REGULATORY_CONFIG])
    request = GC::Tlv::SetRegularConfigurationRequest.from_slice(im.calls.first[2])
    request.new_regulatory_configuration.should eq(GC::RegulatoryLocationType::Indoor)
    request.country_code.should eq("AU")
  ensure
    im.try(&.close)
    commissioner.try(&.close)
  end

  it "skips regulatory configuration for Ethernet-only nodes" do
    im = RegulatoryImClient.new
    im.maps = [{0_u16, NC::Feature::EthernetNetworkInterface.value}]
    commissioner = RegulatoryCommissioner.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new))
    commissioner.configure(im, regulatory_session, Socket::IPAddress.new("127.0.0.1", 5540))
    im.calls.should be_empty
  ensure
    im.try(&.close)
    commissioner.try(&.close)
  end

  it "requires explicit regulatory information for a wireless node" do
    im = RegulatoryImClient.new
    im.maps = [{0_u16, NC::Feature::ThreadNetworkInterface.value}]
    commissioner = RegulatoryCommissioner.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new))
    expect_raises(Matter::ConfigurationError, /regulatory/) do
      commissioner.configure(im, regulatory_session, Socket::IPAddress.new("127.0.0.1", 5540))
    end
    im.calls.should be_empty
  ensure
    im.try(&.close)
    commissioner.try(&.close)
  end

  it "re-arms a near-expiry fail-safe and leaves a healthy one alone" do
    im = RegulatoryImClient.new
    commissioner = RegulatoryCommissioner.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new),
      fail_safe_expiry_seconds: 60_u16)
    session = regulatory_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    now = Time.utc.to_unix
    healthy = RegulatoryCommissioner::FailSafeWindow.new(Time.instant + 45.seconds, now + 45, now + 600)
    commissioner.refresh(im, session, peer, healthy).should eq(healthy)
    im.calls.should be_empty
    expiring = RegulatoryCommissioner::FailSafeWindow.new(Time.instant + 10.seconds, now + 10, now + 600)
    refreshed = commissioner.refresh(im, session, peer, expiring)
    refreshed.primary_expires_at.should be > Time.instant + 50.seconds
    refreshed.expires_at_unix.should be > expiring.expires_at_unix
    capped = RegulatoryCommissioner::FailSafeWindow.new(Time.instant + 5.seconds, now + 5, now + 20)
    commissioner.refresh(im, session, peer, capped).expires_at_unix.should eq(now + 20)
    im.calls.map(&.[1]).should eq([GC::CMD_ARM_FAIL_SAFE, GC::CMD_ARM_FAIL_SAFE])
    GC::ArmFailSafeRequest.from_slice(im.calls.first[2]).expiry_length_seconds.should eq(60_u16)
    GC::ArmFailSafeRequest.from_slice(im.calls.first[2]).breadcrumb.should eq(11_u64)
  ensure
    im.try(&.close)
    commissioner.try(&.close)
  end

  it "persists the refreshed deadline for Datastore registration and deferred handoff" do
    im = RegulatoryImClient.new
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = regulatory_fabric
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, RegulatoryNodeDelivery.new)
    commissioner = RegulatoryCommissioner.new(store, datastore_registrar: registrar)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    now = Time.utc.to_unix
    stale = RegulatoryCommissioner::FailSafeWindow.new(Time.instant + 5.seconds, now + 5, now + 600)
    refreshed, saved_handoff = commissioner.checkpoint(fabric, 0x200_u64, peer,
      im, regulatory_session, stale, true)
    handoff = saved_handoff.as(Matter::Controller::PendingCommissioningHandoff)
    refreshed.expires_at_unix.should be > stale.expires_at_unix
    handoff.expires_at_unix.should eq(refreshed.expires_at_unix)
    store.load.pending_datastore_nodes.first.expires_at_unix.should eq(refreshed.expires_at_unix)
    store.load.pending_handoffs.first.expires_at_unix.should eq(refreshed.expires_at_unix)
  ensure
    im.try(&.close)
    commissioner.try(&.close)
  end

  it "bounds the refreshed fail-safe deadline by the ArmFailSafe send time" do
    im = RegulatoryImClient.new
    im.arm_response_delay = 1.1.seconds
    commissioner = RegulatoryCommissioner.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new),
      fail_safe_expiry_seconds: 60_u16)
    now = Time.utc.to_unix
    expiring = RegulatoryCommissioner::FailSafeWindow.new(Time.instant + 5.seconds, now + 5, now + 600)
    refreshed = commissioner.refresh(im, regulatory_session, Socket::IPAddress.new("127.0.0.1", 5540), expiring)
    invoked_at = im.arm_invoked_at_unix.as(Int64)
    refreshed.expires_at_unix.should be <= invoked_at + 60
  ensure
    im.try(&.close)
    commissioner.try(&.close)
  end

  it "rejects a regulatory command-level error" do
    im = RegulatoryImClient.new
    im.maps = [{0_u16, NC::Feature::WiFiNetworkInterface.value}]
    im.regulatory_error = Matter::Commissioning::ErrorCode::ValueOutsideRange
    commissioner = RegulatoryCommissioner.new(Matter::Controller::StateStore.new(Matter::Storage::Memory.new),
      regulatory_location: GC::RegulatoryLocationType::Indoor,
      regulatory_country_code: "AU")
    expect_raises(Matter::CommissioningError, /SetRegulatoryConfig/) do
      commissioner.configure(im, regulatory_session, Socket::IPAddress.new("127.0.0.1", 5540))
    end
  ensure
    im.try(&.close)
    commissioner.try(&.close)
  end
end
