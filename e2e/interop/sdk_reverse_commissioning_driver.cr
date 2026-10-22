require "../../src/matter/controller"
require "../../src/matter/controller/joint_commissioning"

# Source-fabric controller for the SDK fabric-sync reverse commissioning test.
# The Aggregator uses this same persisted controller identity after the SDK
# returns from CommissionNode; this command only commissions and verifies it.
module SdkReverseCommissioningDriver
  extend self

  SOURCE_FABRIC_ID        = 0xA100_u64
  SOURCE_CONTROLLER_ID    = 0xA101_u64
  SOURCE_AGGREGATOR_ID    = 0xA102_u64
  SOURCE_BRIDGE_ID        = 0xA103_u64
  TEST_VENDOR_ID          = 0xFFF1_u16
  TEST_AGGREGATOR_PRODUCT = 0x1234_u16
  AGGREGATOR_PORT         =       5540
  BRIDGE_PORT             =       5533
  WINDOW_TIMEOUT          =    180_u16
  WINDOW_ITERATIONS       =   1000_u32
  OPERATION_TIMEOUT       = 90.seconds
  EXPECTED_FABRIC_COUNT   = 2_u8

  private def store(path : String) : Matter::Controller::StateStore
    Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
  end

  def open_aggregator_window(path : String) : Nil
    fabric = store(path).load.fabric || raise Matter::ConfigurationError.new("Source fabric missing")
    peer = Socket::IPAddress.new("::1", AGGREGATOR_PORT)
    client = Matter::Controller::Client.new
    begin
      session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
        peer_node_id: SOURCE_AGGREGATOR_ID, timeout: OPERATION_TIMEOUT)
      window = Matter::Controller::Commissioning::CommissioningWindowOpener.new.open_enhanced(
        Matter::Controller::ImClient.new(client, OPERATION_TIMEOUT), session, peer,
        WINDOW_TIMEOUT, WINDOW_ITERATIONS,
        Matter::SetupPayload.generate_random_discriminator)
      puts "Enhanced window PIN=#{window.pin}"
    ensure
      client.close
    end
  end

  def setup(path : String) : Nil
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      SOURCE_FABRIC_ID, SOURCE_CONTROLLER_ID, TEST_VENDOR_ID)
    store(path).save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: SOURCE_CONTROLLER_ID))
    puts "Source fabric ready"
  end

  def commission_aggregator(path : String, manual_code : String) : Nil
    client = Matter::Controller::Client.new(unsecured_source_node_id: SOURCE_CONTROLLER_ID)
    begin
      Matter::Controller::Commissioning::Commissioner.new(store(path), client,
        timeout: OPERATION_TIMEOUT,
        attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
          Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
        SOURCE_AGGREGATOR_ID, manual_code,
        Socket::IPAddress.new("::1", AGGREGATOR_PORT),
        expected_identity: {TEST_VENDOR_ID, TEST_AGGREGATOR_PRODUCT})
      puts "Source Aggregator commissioned"
    ensure
      client.close
    end
  end

  private def commissioned_fabrics(im : Matter::Controller::ImClient,
                                   session : Matter::Session::SecureContext,
                                   peer : Socket::IPAddress) : UInt8
    report = im.read_attribute(session: session, peer: peer, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_COMMISSIONED_FABRICS)
    data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    data.as_u8
  end

  def verify(path : String) : Nil
    state = store(path).load
    fabric = state.fabric || raise Matter::ConfigurationError.new("Source fabric missing")
    unless state.nodes.has_key?(SOURCE_AGGREGATOR_ID) && state.nodes.has_key?(SOURCE_BRIDGE_ID)
      raise Matter::CommissioningError.new("Reverse-commissioned SDK bridge missing from source controller state")
    end

    client = Matter::Controller::Client.new
    begin
      im = Matter::Controller::ImClient.new(client, OPERATION_TIMEOUT)
      {
        {"Crystal Aggregator", SOURCE_AGGREGATOR_ID, AGGREGATOR_PORT},
        {"SDK Fabric Bridge", SOURCE_BRIDGE_ID, BRIDGE_PORT},
      }.each do |name, node_id, port|
        peer = Socket::IPAddress.new("::1", port)
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
          peer_node_id: node_id, timeout: OPERATION_TIMEOUT)
        count = commissioned_fabrics(im, session, peer)
        unless count == EXPECTED_FABRIC_COUNT
          raise Matter::CommissioningError.new("#{name} exposes #{count} fabrics, expected #{EXPECTED_FABRIC_COUNT}")
        end
        puts "CASE verified #{name}: commissioned_fabrics=#{count}"
      end
    ensure
      client.close
    end
  end
end

case ARGV.shift?
when "setup"
  SdkReverseCommissioningDriver.setup(ARGV[0])
when "commission-aggregator"
  SdkReverseCommissioningDriver.commission_aggregator(ARGV[0], ARGV[1])
when "open-aggregator-window"
  SdkReverseCommissioningDriver.open_aggregator_window(ARGV[0])
when "verify"
  SdkReverseCommissioningDriver.verify(ARGV[0])
else
  STDERR.puts "Usage: sdk_reverse_commissioning_driver {setup|commission-aggregator|open-aggregator-window|verify} ..."
  exit 2
end
